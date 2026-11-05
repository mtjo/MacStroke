//
//  Toast.swift
//  MacStroke
//
//  Toast notification display for gesture recognition feedback.
//  Position mapping matches the original's notePostion values:
//  0 = follow mouse, 1 = screen center, 2 = right top, 3 = right bottom,
//  4 = left top, 5 = left bottom.
//

import Foundation
import AppKit
import Preferences

/// A toast notification shown briefly on screen.
public struct Toast {
    public let message: String
    public let duration: TimeInterval
    public let position: ToastPosition

    public init(message: String, duration: TimeInterval = 2.0, position: ToastPosition = .center) {
        self.message = message
        self.duration = duration
        self.position = position
    }
}

/// Position for toast notifications.
/// Raw values match the original `notePostion` preference.
public enum ToastPosition: Int {
    case mouse = 0
    case center = 1
    case rightTop = 2
    case rightBottom = 3
    case leftTop = 4
    case leftBottom = 5
}

/// Manages toast notifications displayed on screen.
///
/// Mirrors the original CoolToast `ToastWindowController` (used by
/// `showNoteTost:`): a screen-covering transparent borderless window with a
/// dynamically sized dark container (min 320×80, corner radius 6), centered
/// message text, optional app icon, fade animation, per-toast auto dismiss,
/// and multiple toasts allowed on screen at the same time.
public final class ToastManager {
    public static let shared = ToastManager()

    private var activeToasts: [NSWindow] = []

    // CoolToast defaults (ToastWindowController initWithWindowNibName:)
    private static let edgeOffset: CGFloat = 50      // left/top/right/bottom offset
    private static let maxWidth: CGFloat = 826
    private static let minWidth: CGFloat = 320
    private static let minHeight: CGFloat = 80
    private static let cornerRadius: CGFloat = 6
    private static let imageMarginLeft: CGFloat = 15
    private static let labelMargin: CGFloat = 30
    private static let iconWidth: CGFloat = 58       // xib icon width constraint
    /// 图标与文字之间的缝，同时是文字到框子上下沿的留白。
    private static let labelGap: CGFloat = 12
    /// `NSTextField` 的 label cell 左右内边距。
    ///
    /// 单行分支按字符串宽定框时必须把它算进去：差这几个点，cell 就会在刚好等于字宽的
    /// 格子里自己折行，而第二行又被 `行数 × 行高` 的格子高度裁掉 —— 默认字号下
    /// 「已保存 截图 …png」这条提示的文件名尾部就是这么没的。
    /// 实测四串（272/313/204/45pt）的折行阈值减字号宽 = 8.35～8.68，取 9 兜住取整。
    static let labelCellPadding: CGFloat = 9
    private let fadeDuration = 0.3            // showNoteTost: animaterTimeSecond

    private init() {}

    /// Parse "#RRGGBB" / "#RRGGBBAA" into an NSColor.
    static func color(fromHex hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255
            g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255
            a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
            a = 1
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Container origin measured from the top-left corner of the screen's
    /// visible area (CoolToast `getContainerPointWithWidth:height:`). The toast
    /// window covers exactly that area, so every position stays on screen.
    /// (The original sizes the window to the full screen height while placing
    /// it at the visible-frame origin, which pushes the box up by the menu bar
    /// plus Dock height and clips the top positions.)
    static func containerOrigin(for position: ToastPosition,
                                visibleFrame: NSRect,
                                mouseLocation: CGPoint,
                                containerSize: NSSize,
                                edgeOffset: CGFloat) -> NSPoint {
        let screenW = visibleFrame.width
        let screenH = visibleFrame.height
        switch position {
        case .center:
            return NSPoint(x: (screenW - containerSize.width) / 2,
                           y: (screenH - containerSize.height) / 2)
        case .leftTop:
            return NSPoint(x: edgeOffset, y: edgeOffset)
        case .rightTop:
            return NSPoint(x: screenW - edgeOffset - containerSize.width, y: edgeOffset)
        case .leftBottom:
            return NSPoint(x: edgeOffset, y: screenH - edgeOffset - containerSize.height)
        case .rightBottom:
            return NSPoint(x: screenW - edgeOffset - containerSize.width,
                           y: screenH - edgeOffset - containerSize.height)
        case .mouse:
            // The box sits just above the pointer, flipping to its left when it
            // would leave the right edge, and clamped inside the visible area
            // (the pointer can be over the Dock or the menu bar).
            var x = mouseLocation.x - visibleFrame.minX
            if x + containerSize.width > screenW { x -= containerSize.width }
            let y = visibleFrame.maxY - mouseLocation.y - containerSize.height
            return NSPoint(x: max(0, min(x, screenW - containerSize.width)),
                           y: max(0, min(y, screenH - containerSize.height)))
        }
    }

    /// 一次气泡的排版结果：框子多大、图标和文字各占哪一块。
    public struct ToastMetrics {
        public let containerSize: NSSize
        public let iconFrame: NSRect
        public let labelFrame: NSRect
        public let lineCount: Int
    }

    /// 量文字、定框子。**只有一把尺**：折行用的宽度就是 label 真正拿到的宽度，
    /// 框高就是 `行数 × 行高 + 上下留白`。
    ///
    /// 为什么不照抄原版：`ToastWindowController.m` 在这里用了两套口径 —— 数行数按
    /// `maxWidth-60-73` 折，定框宽却按**不折行**的单行宽加，长消息把框撑过 826 而文字
    /// 只排一行；框高又只按「超出两行的部分」长（`80 + (lineCount-2) × 行高`），永远比
    /// 文字少两行高。字号小、消息短时看不出来；截图那条提示带完整文件名（「已保存 截图
    /// 2026-11-02 at 15.08.47.png」），配上 Monaco 40 就是一行 865pt 的字顶出黑框。
    public static func metrics(message: String, font: NSFont, iconVisible: Bool) -> ToastMetrics {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let labelLeft = iconVisible ? imageMarginLeft + iconWidth + labelGap : labelMargin
        let chrome = labelLeft + labelMargin
        // 折行预算就是 label 真正拿到的宽度 —— 「一把尺」说的就是这一行。
        // label cell 左右各吃 2pt，所以要先把这 4pt 让出来。
        let available = maxWidth - chrome
        let labelBudget = available - labelCellPadding
        let singleLine = ceil((message as NSString).size(withAttributes: [.font: font]).width)

        let containerWidth: CGFloat
        let lineCount: Int
        if singleLine <= labelBudget {
            lineCount = 1
            // Original quirk: icon width is counted even when the icon is hidden
            let slack: CGFloat = iconVisible ? 0 : imageMarginLeft + iconWidth
            containerWidth = max(minWidth, singleLine + labelCellPadding + chrome + slack)
        } else {
            containerWidth = maxWidth
            let bounding = (message as NSString).boundingRect(
                with: CGSize(width: labelBudget, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: font])
            lineCount = max(1, Int(ceil(bounding.height / lineHeight)))
        }

        let labelHeight = CGFloat(lineCount) * lineHeight
        let containerHeight = max(minHeight, labelHeight + labelGap * 2)
        return ToastMetrics(
            containerSize: NSSize(width: containerWidth, height: containerHeight),
            iconFrame: NSRect(x: imageMarginLeft, y: (containerHeight - iconWidth) / 2,
                              width: iconWidth, height: iconWidth),
            labelFrame: NSRect(x: labelLeft, y: (containerHeight - labelHeight) / 2,
                               width: containerWidth - chrome, height: labelHeight),
            lineCount: lineCount)
    }

    /// 按 metrics 把深色框、图标、文字装好。`show()` 与离屏取证都走这一手，
    /// 于是量到的就是真机上那只框（而不是测试里另抄一份布局）。
    static func makeContainer(message: String, metrics: ToastMetrics, font: NSFont,
                              textColor: NSColor, backgroundAlpha: CGFloat,
                              hiddenIcon: Bool) -> NSView {
        // Container (CTView): dark rounded box, corner radius conerRadius
        let container = NSView(frame: NSRect(origin: .zero, size: metrics.containerSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.backgroundColor = NSColor(red: 0, green: 0, blue: 0,
                                                   alpha: backgroundAlpha).cgColor

        // Icon: app icon，图标列定宽 58，垂直居中（长消息把框撑高时不跟着放大）。
        let iconView = NSImageView(frame: metrics.iconFrame)
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = hiddenIcon
        container.addSubview(iconView)

        // Message label: centered text。左沿让开图标那一列，框高按行数给足，
        // 于是字既不会被压到图标底下，也不会顶出黑框。
        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.font = font
        label.textColor = textColor
        label.frame = metrics.labelFrame
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        container.addSubview(label)
        return container
    }

    /// Show a toast notification.
    /// - Parameter toast: The toast to display
    public func show(_ toast: Toast) {
        // Original note preferences (showNoteTost:): read live on every show,
        // like the original's per-call NSUserDefaults reads, so preference
        // edits take effect without restarting the app.
        let preferences = UserPreferences()
        let fontSize = CGFloat(preferences.noteFontSize)
        let bgAlpha = CGFloat(preferences.noteBackgroundAlpha)
        let fontName = preferences.noteFontName
        let retention = preferences.noteRetentionTime
        let positionIndex = preferences.notePosition
        let hiddenIcon = !preferences.showNoteIcon
        let textColor = Self.color(fromHex: preferences.defaultNoteColor) ?? .white

        let font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: 15)

        // CTScreen getCurrentScreen: the screen containing the mouse
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame

        // 量文字、定框子（口径只有一把尺，见 metrics 那段注释）
        let metrics = Self.metrics(message: toast.message, font: font, iconVisible: !hiddenIcon)
        let containerWidth = metrics.containerSize.width
        let containerHeight = metrics.containerSize.height

        // getContainerPointWithWidth:height: (top-left origin within the window)
        let position = ToastPosition(rawValue: positionIndex) ?? toast.position
        let origin = Self.containerOrigin(for: position,
                                          visibleFrame: visibleFrame,
                                          mouseLocation: mouseLocation,
                                          containerSize: NSSize(width: containerWidth,
                                                                height: containerHeight),
                                          edgeOffset: Self.edgeOffset)

        // Window covers the screen (CoolToastWindow): clear bg, no shadow,
        // NSPopUpMenuWindowLevel
        let windowSize = visibleFrame.size
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .popUpMenu
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isOpaque = false
        // close() must NOT add an extra release on top of ARC's ownership,
        // otherwise the window is over-released and the next pool pop crashes
        // with -[NSWindow release] on a deallocated instance.
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(visibleFrame.origin)

        let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        window.contentView = contentView

        // Container (CTView): dark rounded box, corner radius conerRadius
        let container = Self.makeContainer(message: toast.message, metrics: metrics, font: font,
                                           textColor: textColor, backgroundAlpha: bgAlpha,
                                           hiddenIcon: hiddenIcon)
        container.setFrameOrigin(NSPoint(x: origin.x, y: windowSize.height - origin.y - containerHeight))

        // Double-click on the container dismisses the toast
        let click = NSClickGestureRecognizer(target: self, action: #selector(toastClicked(_:)))
        click.numberOfClicksRequired = 2
        container.addGestureRecognizer(click)

        contentView.addSubview(container)
        window.makeKeyAndOrderFront(nil)

        // Fade in (CTAnimaterFade)
        container.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            container.animator().alphaValue = 1
        }

        activeToasts.append(window)

        // autoDismiss: dismiss after noteRetetionTime seconds (independent,
        // toasts may overlap like the original)
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(retention)) { [weak self, weak window] in
            guard let self, let window else { return }
            self.dismiss(window)
        }
    }

    @objc private func toastClicked(_ gesture: NSClickGestureRecognizer) {
        guard let window = gesture.view?.window else { return }
        dismiss(window)
    }

    /// Fade out and close a toast window (dismissWithAnimator, CTAnimaterFade).
    private func dismiss(_ window: NSWindow) {
        guard activeToasts.contains(where: { $0 === window }) else { return }
        activeToasts.removeAll { $0 === window }
        guard let container = window.contentView?.subviews.first else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeDuration
            container.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            window.close()
        })
    }

    /// Fade out and hide all current toasts.
    public func hide() {
        for window in activeToasts {
            dismiss(window)
        }
    }
}
