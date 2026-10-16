//
//  ScreenshotMode.swift
//  MacStroke
//
//  触发截图后浮在屏幕**顶部中央**的模式条：截图 / 滚动截图 / 录屏 / 文字识别
//  （参照物是 QQ 那条，用户 2026-10-16 指的红框）。它决定「选区落定之后干什么」，
//  所以只在选区阶段露面：一进编辑态就让位给注解条。
//
//  样式跟注解条同一套规矩（见 ScreenshotToolbar.swift 头部）：借的只是 QQ 的**图标
//  语言与格子顺序**，底衬和墨色按系统明暗解析，选中那一格铺系统蓝、字转白。
//  语义色照旧要在 `draw` 之前解析成具体值，离屏 `cacheDisplay` 才和屏幕上一样。
//
//  和注解条同一个 hitTest 规矩：**只有格子吃事件**，空白处放行给遮罩。这条浮在屏顶，
//  正好压在「从屏幕最上沿往下拖一个选区」要经过的地方，整条吃掉点击就没法框住菜单栏那
//  一带了。
//

import AppKit
import Storage

/// 截图会话要出什么。选区落定后按这个值分流。
enum ScreenshotMode: Int, CaseIterable {
    case still, scroll, record, text

    /// 条子从左到右的顺序，照 QQ 顶部那条：截图 / 滚动截图 / 录屏 / 文字识别。
    static let barOrder: [ScreenshotMode] = [.still, .scroll, .record, .text]

    var title: String {
        switch self {
        case .still: return L("Screenshot")
        case .scroll: return L("Screenshot Scroll")
        case .record: return L("Screenshot Record")
        case .text: return L("Screenshot OCR")
        }
    }

    /// 系统符号名。真机上缺符号会退化成问号（见 `ScreenshotModeCell`），取证那条
    /// 判据核对的是这里写的名字在系统的符号表里查得到。
    var symbolName: String {
        switch self {
        case .still: return "camera.viewfinder"
        case .scroll: return "arrow.down.doc"
        case .record: return "record.circle"
        case .text: return "text.viewfinder"
        }
    }

    /// 只有静态图这一档需要就地注解；其余三档选完直接走各自的路。
    var showsAnnotationBar: Bool { self == .still }

    /// 选区阶段打在屏上的那句按键说明（本地化 key，由遮罩过 `L()`）。三档实况/识别的
    /// 路子和「截图」手感不同，提示得跟着换，否则用户以为回车还是编辑。
    var hintKey: String {
        switch self {
        case .still: return "Drag to select, Enter edits, Esc cancels"
        case .scroll: return "Screenshot Scroll hint"
        case .record: return "Screenshot Record hint"
        case .text: return "Screenshot Text hint"
        }
    }
}

/// 模式条上的一格：图标 + 文字。
private final class ScreenshotModeCell: NSView {
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let iconPointSize: CGFloat = 13
    static let iconWidth: CGFloat = 17
    static let iconGap: CGFloat = 5
    static let horizontalPadding: CGFloat = 9

    let mode: ScreenshotMode
    let action: () -> Void
    var isActive = false { didSet { needsDisplay = true } }

    /// 图文两段的宽度在装配时量一次：每次 draw 都量一遍字重排版，拖动选区时白烧 CPU。
    private let textWidth: CGFloat

    init(mode: ScreenshotMode, action: @escaping () -> Void) {
        self.mode = mode
        self.action = action
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        self.textWidth = ceil((mode.title as NSString).size(withAttributes: attributes).width)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width(for: mode),
                                 height: ScreenshotModeBarView.cellHeight))
        setAccessibilityLabel(mode.title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 这一格该占多宽。
    static func width(for mode: ScreenshotMode) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        let text = ceil((mode.title as NSString).size(withAttributes: attributes).width)
        return horizontalPadding + iconWidth + iconGap + text + horizontalPadding
    }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = ToolbarStyle.resolved(for: effectiveAppearance)
        if isActive {
            ToolbarStyle.accent.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let ink = isActive ? ToolbarStyle.onAccent : style.glyph
        let centerY = bounds.midY
        if let image = icon(for: ink) {
            let side = min(image.size.width, bounds.height - 10)
            let ratio = side / image.size.width
            let box = CGRect(x: bounds.minX + Self.horizontalPadding,
                             y: centerY - image.size.height * ratio / 2,
                             width: side, height: image.size.height * ratio)
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ink]
        let size = (mode.title as NSString).size(withAttributes: attributes)
        (mode.title as NSString).draw(at: CGPoint(x: bounds.minX + Self.horizontalPadding
                                                      + Self.iconWidth + Self.iconGap,
                                                  y: centerY - size.height / 2),
                                      withAttributes: attributes)
    }

    /// 符号按墨色烫好缓存（缺符号时系统给 nil，退化成问号总比格里空一块好）。
    private func icon(for color: NSColor) -> NSImage? {
        let base = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)
        guard let configured = base?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .regular))
        else { return nil }
        let size = configured.size
        guard size.width > 1, size.height > 1 else { return nil }
        let baked = NSImage(size: size)
        baked.lockFocus()
        configured.isTemplate = true
        configured.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        baked.unlockFocus()
        return baked
    }

    override func mouseDown(with event: NSEvent) {
        // 自己吃掉按下：不实现就顺 responder chain 冒到遮罩，那点会被当成「在屏顶起
        // 一个选区」，用户点一下模式格顺带把框拖出来了。
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
}

/// 遮罩顶部的模式条。
final class ScreenshotModeBarView: NSView {
    static let barHeight: CGFloat = 34
    static let cellHeight: CGFloat = 24
    static let edgePadding: CGFloat = 5
    static let cellGap: CGFloat = 2
    /// 距屏顶留的缝：遮罩盖住菜单栏，贴着 y=0 摆会正好压在系统菜单栏那一条上。
    static let topMargin: CGFloat = 8

    var onPick: ((ScreenshotMode) -> Void)?

    private var cells: [ScreenshotMode: ScreenshotModeCell] = [:]
    private let order = ScreenshotMode.barOrder

    /// 条子宽度固定：定位要在还没挂上视图时算，所以 init 里就把总宽算好。
    private(set) var preferredWidth: CGFloat = 0

    /// 格子的 id，按从左到右的顺序。取证用它核对布局：漏一档、多一档、摆错顺序，
    /// 在代码里都看不出来，只有对着装配好的条子数才看得出来。
    var elementsOnBar: [String] { order.map { $0.id } }

    /// 此刻条子上亮着哪一档。internal 而非 private：取证要核对「选中态」真的落到了
    /// 格子上，而不是只活在遮罩的状态位里。
    var activeModeOnBar: ScreenshotMode? { cells.first { $0.value.isActive }?.key }

    /// 菜单栏那一条的高度（遮罩是全屏的，含菜单栏）。
    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private func build() {
        for mode in order {
            let cell = ScreenshotModeCell(mode: mode) { [weak self] in self?.onPick?(mode) }
            cells[mode] = cell
            addSubview(cell)
        }
        preferredWidth = order.reduce(Self.edgePadding * 2) {
            $0 + ScreenshotModeCell.width(for: $1) + Self.cellGap
        } - Self.cellGap
        placeCells()
    }

    /// 格子在**本视图坐标**里的矩形。遮罩拿它判「这一下按的是模式格还是空白」。
    var actionableRects: [NSRect] { order.compactMap { cells[$0]?.frame } }

    /// 遮罩坐标里这一点是否按在某一档上。条子和遮罩同为 flipped 视图、无缩放，
    /// 所以换坐标只剩平移，不必绕 `convert`（单测直接喂遮罩坐标，没有 superview）。
    func hasActionable(atOverlayPoint point: NSPoint) -> Bool {
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return actionableRects.contains { $0.contains(local) }
    }

    /// 某一档在遮罩坐标里的矩形（没装配就答 nil）。
    func rect(for mode: ScreenshotMode, atBarOrigin origin: NSPoint = .zero) -> NSRect? {
        cells[mode]?.frame.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 空白处放行给遮罩：见文件头那条 hitTest 规矩。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, hasActionable(atOverlayPoint: point) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = ToolbarStyle.resolved(for: effectiveAppearance)
        style.barFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        style.barBorder.setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        edge.lineWidth = 1
        edge.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        subviews.forEach { $0.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        placeCells()
    }

    private func placeCells() {
        var x = Self.edgePadding
        for mode in order {
            guard let cell = cells[mode] else { continue }
            cell.frame = CGRect(x: x, y: (Self.barHeight - cell.frame.height) / 2,
                                width: cell.frame.width, height: cell.frame.height)
            x += cell.frame.width + Self.cellGap
        }
    }

    /// 只反映「现在选了哪一档」，状态真相在遮罩那边。
    func sync(mode: ScreenshotMode) {
        for (key, cell) in cells { cell.isActive = key == mode }
    }

    /// 条子该摆在哪：横向对屏居中，纵向从屏顶往下让开菜单栏再留一格缝。
    ///
    /// `topInset` 由调用方给（菜单栏高度要从那块屏的 frame/visibleFrame 算，单测里
    /// 造不出一块指定分辨率的屏，所以这条做成纯函数）。
    static func barFrame(width: CGFloat, container: NSRect, topInset: CGFloat) -> CGRect {
        let x = container.midX - width / 2
        let y = topInset + topMargin
        return CGRect(x: x, y: y, width: width, height: barHeight)
    }
}

extension ScreenshotMode {
    /// 条子上那一格的 id：取证用它核对布局，不跟文案走（`title` 会随语言变）。
    var id: String {
        switch self {
        case .still: return "still"
        case .scroll: return "scroll"
        case .record: return "record"
        case .text: return "text"
        }
    }
}
