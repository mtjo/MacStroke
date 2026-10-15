//
//  ScreenshotPin.swift
//  MacStroke
//
//  「图钉贴图」：注解条上那枚图钉把烘好的成品钉成一扇置顶小窗，钉在它原来那块屏幕
//  位置上。参照 QQ：边看这张图边操作别处，能拖、滚轮缩放、双击或 Esc 收掉，一次能
//  钉好几张。
//
//  窗是 borderless + `.floating`：贴图要压在别的 App 之上，但不能再高到把菜单栏和
//  系统提示挡住（截图工具最常见的抱怨就是「贴图画到菜单上面去了」）。
//
//  内容自己画而不是 NSImageView：这层窗没有 titlebar、也不走 Auto Layout，视图自己
//  `draw(_:)` 才和工程里其余截图渲染是同一条路径（离屏取证只重放 draw，imageView 的
//  imageScaling 不在里面）。
//

import AppKit
import CoreGraphics
import Storage

/// 一枚贴图窗。
final class ScreenshotPinWindow: NSWindow {
    /// 缩放上下限，按「原尺寸的几倍」算。放到 1/5 已经糊得认不出内容，放大到 5 倍
    /// 不如回遮罩里重截一次。
    static let minZoom: CGFloat = 0.2
    static let maxZoom: CGFloat = 5
    /// 滚轮一格给多少：QQ 也是一格一档，不是连续变焦。
    static let zoomStep: CGFloat = 0.1

    /// 出图时那块选区的尺寸，也就是 1× 时该有多大。缩放要按它算倍率，不能按当前
    /// 窗宽算 —— 连滚两格之后窗宽已经不是原尺寸了。
    private let baseSize: NSSize

    init(image: CGImage, screenRect: NSRect) {
        let size = NSSize(width: max(1, screenRect.width), height: max(1, screenRect.height))
        baseSize = size
        super.init(contentRect: NSRect(origin: screenRect.origin, size: size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 整扇窗的背景都能拖：贴图没有标题栏，不给这条路就只能靠键盘把它关掉了。
        isMovableByWindowBackground = true
        contentView = ScreenshotPinView(image: image, naturalSize: size)
    }

    /// borderless 默认成不了 key 窗，成不了就收不到 Esc。
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc(53) / ⌘W(13) 收掉这一枚；其余按键不拦，交给系统。
        let commandW = event.keyCode == 13 && event.modifierFlags.contains(.command)
        if event.keyCode == 53 || commandW {
            ScreenshotPinBoard.close(self)
        } else {
            super.keyDown(with: event)
        }
    }

    /// 缩放后该摆在哪：以窗中心为锚（缩放时不许跑偏），倍率钳在上下限之间，
    /// 宽和高一起乘同一个数，长宽比不会变。
    static func zoomed(_ frame: NSRect, up: Bool, base: NSSize) -> NSRect {
        let current = base.width > 0 ? frame.width / base.width : 1
        let next = up ? current * (1 + zoomStep) : current / (1 + zoomStep)
        let zoom = min(max(next, minZoom), maxZoom)
        let size = NSSize(width: base.width * zoom, height: base.height * zoom)
        return NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func zoom(up: Bool) {
        setFrame(Self.zoomed(frame, up: up, base: baseSize), display: true)
    }
}

/// 贴图的内容：整张成品铺满，外面留一圈描边 —— 底图常常就是浅灰的窗口内容，
/// 没这一圈就看不出贴图的边界在哪。
final class ScreenshotPinView: NSView {
    private let picture: NSImage

    init(image: CGImage, naturalSize: NSSize) {
        self.picture = NSImage(cgImage: image, size: naturalSize)
        super.init(frame: NSRect(origin: .zero, size: naturalSize))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        picture.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55).setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pin = window as? ScreenshotPinWindow else { return }
        pin.zoom(up: event.scrollingDeltaY > 0)
    }

    override func mouseDown(with event: NSEvent) {
        // 双击收起（QQ 的手感）。单下不吃掉：那一下要留给「拖着整扇窗走」。
        guard event.clickCount >= 2, let pin = window as? ScreenshotPinWindow else { return }
        ScreenshotPinBoard.close(pin)
    }
}

/// 贴图的总账：窗必须有人强持有，否则 orderOut 之后随时被回收；「一次钉多张」和
/// 「全部关掉」也都要在这里点名。
enum ScreenshotPinBoard {
    private(set) static var pins: [ScreenshotPinWindow] = []

    /// 钉在 `screenRect` 这块屏幕位置上（AppKit 左下原点）。
    @discardableResult
    static func show(image: CGImage, screenRect: NSRect) -> ScreenshotPinWindow {
        let pin = ScreenshotPinWindow(image: image, screenRect: screenRect)
        pins.append(pin)
        // 应用是 .accessory，不 activate 也得让贴图立刻现身。
        pin.orderFrontRegardless()
        return pin
    }

    static func close(_ pin: ScreenshotPinWindow) {
        pins.removeAll { $0 === pin }
        pin.orderOut(nil)
    }

    static func closeAll() {
        for pin in pins { pin.orderOut(nil) }
        pins.removeAll()
    }

    static var count: Int { pins.count }
}
