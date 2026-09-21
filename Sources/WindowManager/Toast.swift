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
    private let edgeOffset: CGFloat = 50      // left/top/right/bottom offset
    private let maxWidth: CGFloat = 826
    private let minWidth: CGFloat = 320
    private let minHeight: CGFloat = 80
    private let cornerRadius: CGFloat = 6
    private let imageMarginLeft: CGFloat = 15
    private let labelMargin: CGFloat = 30
    private let iconWidth: CGFloat = 58       // xib icon width constraint
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

        // showCoolToast: measure the text to size the container
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let labelMaxWidth = maxWidth - labelMargin * 2 - (hiddenIcon ? 0 : iconWidth + imageMarginLeft)
        let message = toast.message as NSString
        var labelWidth = message.size(withAttributes: attributes).width
        let bounding = message.boundingRect(
            with: CGSize(width: labelMaxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attributes)
        let lineCount = Int(ceil(bounding.height / NSLayoutManager().defaultLineHeight(for: font)))
        var containerHeight = minHeight
        if lineCount > 2 {
            containerHeight = minHeight + CGFloat(lineCount - 2) * font.boundingRectForFont.height
            labelWidth = labelMaxWidth
        }
        // Original quirk: icon width is counted even when the icon is hidden
        var containerWidth = labelWidth + iconWidth + labelMargin * 2 + imageMarginLeft
        if containerWidth < minWidth { containerWidth = minWidth }

        // getContainerPointWithWidth:height: (top-left origin within the window)
        let position = ToastPosition(rawValue: positionIndex) ?? toast.position
        let origin = Self.containerOrigin(for: position,
                                          visibleFrame: visibleFrame,
                                          mouseLocation: mouseLocation,
                                          containerSize: NSSize(width: containerWidth,
                                                                height: containerHeight),
                                          edgeOffset: edgeOffset)

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
        let container = NSView(
            frame: NSRect(x: origin.x, y: windowSize.height - origin.y - containerHeight,
                          width: containerWidth, height: containerHeight))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.backgroundColor = NSColor(red: 0, green: 0, blue: 0, alpha: bgAlpha).cgColor

        // Icon: app icon, leading imageMarginLeft, 58 wide, vertical margins 10
        let iconView = NSImageView(
            frame: NSRect(x: imageMarginLeft, y: 10,
                          width: iconWidth, height: containerHeight - 20))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = hiddenIcon
        container.addSubview(iconView)

        // Message label: centered text, leading labelMargin, trailing 5.
        // The xib gives the label no height constraint (only centerY), so it
        // keeps its intrinsic font line height — a fixed 40pt frame would clip
        // large note fonts (e.g. Monaco 40 needs ~48pt).
        let label = NSTextField(labelWithString: toast.message)
        label.alignment = .center
        label.font = font
        label.textColor = textColor
        let labelHeight = CGFloat(max(1, lineCount)) * NSLayoutManager().defaultLineHeight(for: font)
        label.frame = NSRect(x: labelMargin, y: (containerHeight - labelHeight) / 2,
                             width: containerWidth - labelMargin - 5, height: labelHeight)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        container.addSubview(label)

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
