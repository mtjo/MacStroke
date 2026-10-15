//
//  ScreenshotMagnifier.swift
//  MacStroke
//
//  选区阶段跟着光标的放大镜：一小块放大的像素 + 十字线 + 那一点的坐标和色值。
//
//  为什么需要：遮罩是 1:1 铺的，Retina 上「光标尖对着哪个像素」根本看不出来，而截图
//  要卡的就是那条边（图标边界、文字行）。QQ/微信/钉钉都在这里挂一块放大取景，用户靠
//  像素格和十字线把边界卡准 —— 这也是「色值」的入口，取色没有别的路。
//
//  取的是**已经定格的那一帧**，绝不重新抓屏：放大镜必须和底图同源，否则看到的和选出来
//  的会错开；而且抓屏是权限操作，不该跟着鼠标每动一下就来一次。
//
//  面板尺寸不随倍率变（变的是一格里塞进多少个像素），改设置时不会突然变大挡路。
//

import AppKit
import Storage

/// 放大倍率：底图的一个像素在取景窗里占多少点。库里直接存这个整数。
public enum ScreenshotMagnification: Int, CaseIterable {
    case normal = 4
    case medium = 8
    case large = 16

    /// 库里存了个没见过的值（手改 plist、以后加档位）时回到默认档，别画出个 0 倍的窗。
    public init(stored: Int) {
        self = ScreenshotMagnification(rawValue: stored) ?? .medium
    }

    /// 一个底图像素的边长（点）。
    public var cell: CGFloat { CGFloat(rawValue) }

    /// 偏好页下拉框上的写法。
    public var title: String { "\(rawValue)×" }
}

/// 面板的两套配色，按系统外观就地挑一套。和注解条同一个理由：语义色要按当前图形
/// 上下文解析，离屏取证和真机可能各解析出一套，写死浅/深两档两边才都能验。
private struct MagnifierStyle {
    let fill: NSColor
    let border: NSColor
    let label: NSColor
    let value: NSColor
    let grid: NSColor
    let crosshair: NSColor

    static func forView(_ view: NSView) -> MagnifierStyle {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

    static let light = MagnifierStyle(
        fill: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.97),
        border: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18),
        label: NSColor(srgbRed: 0.42, green: 0.44, blue: 0.47, alpha: 1),
        value: NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1),
        grid: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12),
        crosshair: NSColor(srgbRed: 0.10, green: 0.78, blue: 0.22, alpha: 1)
    )

    static let dark = MagnifierStyle(
        fill: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 0.97),
        border: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
        label: NSColor(srgbRed: 0.62, green: 0.64, blue: 0.67, alpha: 1),
        value: NSColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: 1),
        grid: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14),
        crosshair: NSColor(srgbRed: 0.20, green: 0.90, blue: 0.34, alpha: 1)
    )
}

/// 遮罩上的放大镜面板。纯装饰：`hitTest` 直接放行，不参与选区那棵判定树。
final class ScreenshotMagnifierView: NSView {
    /// 取景窗在屏上的边长（点），不随倍率变。
    static let imageSide: CGFloat = 120
    static let inset: CGFloat = 6
    /// 取景窗下面那块读数区的高度（两行读数 + 一行提示）。
    static let infoHeight: CGFloat = 50
    /// 面板离光标留这么远，否则十字准星被自己的面板挡住。
    static let cursorGap: CGFloat = 18
    /// 「已复制」停留多久。
    static let copiedFlash: TimeInterval = 1.2

    private let shot: ScreenshotFrame
    /// 目标点：遮罩视图（整屏 flipped）坐标。
    private var target: CGPoint = .zero
    private var magnification: ScreenshotMagnification = .medium
    /// 刚按 ⌘C 复制过：提示那一行临时换成「已复制」。遮罩层压着 App 层的 Toast，
    /// 确认只能就地给，否则就是静默复制。
    private(set) var isShowingCopied = false
    private var copyToken = 0

    init(shot: ScreenshotFrame) {
        self.shot = shot
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 此刻那一点的色值，给 ⌘C 用（和面板上显示的是同一个来源，不会说一套复制一套）。
    var colorText: String? { shot.hexColor(for: target) }

    /// 光标走到哪、放大多少倍，一次算完并把面板摆好。
    func follow(point: NSPoint, magnification: ScreenshotMagnification, in bounds: CGRect) {
        // 指到别的像素上，「已复制」就该跟着撤掉——留着是在说另一个点的色值。
        if shot.pixelIndex(for: point) != shot.pixelIndex(for: target) { isShowingCopied = false }
        target = point
        self.magnification = magnification
        let size = Self.panelSize
        setFrameSize(size)
        setFrameOrigin(Self.panelOrigin(cursor: point, size: size, in: bounds))
        needsDisplay = true
    }

    func markCopied() {
        copyToken += 1
        let token = copyToken
        isShowingCopied = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFlash) { [weak self] in
            // 期间又复制过一次（token 变了）就别把新的那次抹掉。
            guard let self, self.copyToken == token else { return }
            self.isShowingCopied = false
            self.needsDisplay = true
        }
    }

    // MARK: - 几何（internal：单测要能单独验摆位和取样，不靠看图）

    static var panelSize: NSSize {
        NSSize(width: imageSide + inset * 2, height: imageSide + inset * 2 + infoHeight)
    }

    /// 取景窗里横排多少个像素：凑满 imageSide 的偶数再收成奇数，中心那一格才是
    /// 被指的那个像素（偶数会把它推到半格上）。
    static func pixelsAcross(for cell: CGFloat) -> Int {
        let raw = Int((imageSide / cell).rounded())
        return max(3, raw % 2 == 0 ? raw - 1 : raw)
    }

    /// 取景范围（底图像素坐标）。目标点贴边时整块往里推，保证不越界 —— 十字线按
    /// 中心像素的**真实偏移**画，所以推过之后指的仍然是那一个像素。
    static func sourceRect(around pixel: CGPoint, across: Int, imageSize: CGSize) -> CGRect {
        let side = min(CGFloat(across), min(imageSize.width, imageSize.height))
        let half = CGFloat(across / 2)
        let x = min(max(0, pixel.x - half), max(0, imageSize.width - side))
        let y = min(max(0, pixel.y - half), max(0, imageSize.height - side))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// 面板左上角：默认在光标右下，快出屏就翻到另一侧，最后钳在屏内。
    static func panelOrigin(cursor: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        var x = cursor.x + cursorGap
        if x + size.width > bounds.maxX { x = cursor.x - cursorGap - size.width }
        var y = cursor.y + cursorGap
        if y + size.height > bounds.maxY { y = cursor.y - cursorGap - size.height }
        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, bounds.maxY - size.height)
        return CGPoint(x: min(max(x, bounds.minX), maxX), y: min(max(y, bounds.minY), maxY))
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let style = MagnifierStyle.forView(self)
        let cell = magnification.cell
        let across = Self.pixelsAcross(for: cell)
        let pixel = shot.pixelIndex(for: target)
        let imageSize = CGSize(width: shot.image.width, height: shot.image.height)
        let source = Self.sourceRect(around: pixel, across: across, imageSize: imageSize)
        // 底图比取景窗还小（测试里的合成图、超小屏）时按图缩放，格子跟着缩。
        let drawnCell = min(cell, Self.imageSide / max(1, source.width))
        let side = source.width * drawnCell
        let imageRect = CGRect(x: (bounds.width - side) / 2, y: Self.inset, width: side, height: side)

        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        style.fill.setFill()
        panel.fill()

        if let cut = shot.image.cropping(to: source) {
            let context = NSGraphicsContext.current
            context?.imageInterpolation = .none
            NSImage(cgImage: cut, size: NSSize(width: source.width, height: source.height))
                .draw(in: imageRect)
            context?.imageInterpolation = .default
        }

        let center = CGPoint(x: imageRect.minX + (pixel.x - source.minX + 0.5) * drawnCell,
                             y: imageRect.minY + (pixel.y - source.minY + 0.5) * drawnCell)
        if drawnCell >= 8 { drawGrid(of: imageRect, step: drawnCell, style: style) }
        drawCrosshair(center: center, in: imageRect, cell: drawnCell, style: style)

        style.border.setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        edge.lineWidth = 1
        edge.stroke()

        drawReadout(style: style)
    }

    /// 逐像素的格子线：只在格子够大时画，4 倍那一档画出来就是一层糊在内容上的噪点。
    private func drawGrid(of rect: CGRect, step: CGFloat, style: MagnifierStyle) {
        style.grid.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var x = rect.minX + step
        while x < rect.maxX - 1 {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.line(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        var y = rect.minY + step
        while y < rect.maxY - 1 {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.line(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        path.stroke()
    }

    /// 两条绿线穿过被指的那个像素，并把那一格本身圈出来 —— 用户信的是这一格，
    /// 不是光标尖。
    private func drawCrosshair(center: CGPoint, in rect: CGRect, cell: CGFloat, style: MagnifierStyle) {
        style.crosshair.setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        let x = center.x.rounded() + 0.5
        let y = center.y.rounded() + 0.5
        lines.move(to: CGPoint(x: x, y: rect.minY))
        lines.line(to: CGPoint(x: x, y: rect.maxY))
        lines.move(to: CGPoint(x: rect.minX, y: y))
        lines.line(to: CGPoint(x: rect.maxX, y: y))
        lines.stroke()

        let box = NSBezierPath(rect: CGRect(x: center.x - cell / 2, y: center.y - cell / 2,
                                            width: cell, height: cell))
        box.lineWidth = 1
        box.stroke()
    }

    private func drawReadout(style: MagnifierStyle) {
        let top = Self.inset + Self.imageSide + 5
        drawRow(label: L("Magnifier Position"),
                value: "\(Int(shot.pixelIndex(for: target).x)), \(Int(shot.pixelIndex(for: target).y))",
                baseline: top, style: style)
        drawRow(label: L("Magnifier Color"),
                value: shot.hexColor(for: target) ?? "—",
                baseline: top + 17, style: style)
        let hint = NSAttributedString(string: isShowingCopied ? L("Magnifier Copied") : L("Magnifier Copy Hint"),
                                      attributes: [
                                          .font: NSFont.systemFont(ofSize: 10),
                                          .foregroundColor: isShowingCopied ? style.crosshair : style.label,
                                      ])
        hint.draw(at: CGPoint(x: Self.inset + 1, y: top + 34))
    }

    /// 一行「左标签 + 右数值」。数值用等宽数字，鼠标一动数字位数变了也不会左右抖。
    private func drawRow(label: String, value: String, baseline: CGFloat, style: MagnifierStyle) {
        let label = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: style.label,
        ])
        let value = NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: style.value,
        ])
        label.draw(at: CGPoint(x: Self.inset + 1, y: baseline))
        value.draw(at: CGPoint(x: bounds.maxX - Self.inset - 1 - value.size().width, y: baseline))
    }
}
