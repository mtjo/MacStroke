//
//  ScreenshotLivePanel.swift
//
//  实况采集（滚动截图 / 录屏）期间挂在屏幕上的两扇窗：
//  1. **区域描边**：把正在被采集的那一块圈出来。透明、不吃鼠标，纯粹是给眼睛看的边界。
//  2. **控制胶囊**：一行读数 + 停止 + 取消。
//
//  两扇都必须 `sharingType = .none`。理由和手势轨迹画布一样（见 CanvasWindow）：
//  `orderOut` 要等 CoreAnimation 事务提交才从窗口服务的合成里消失，靠时序躲不开；
//  而这两扇窗正好压在采集区域上（描边就贴着边），不整个从采集里剔掉就会：
//  - 录屏：把控制面板和描边录进成片；
//  - 长截图：描边每帧都出现在同一位置，被当成「不动的吸顶栏」把拼接判据带偏。
//  人眼照常看得见，采集看不见 —— 这是这类浮层唯一正确的做法。
//
//  控制胶囊不抢键盘焦点（`canBecomeKey` 不覆盖）：抢了就把用户正在操作的那个 App 挤开，
//  滚动截图那一路尤其糟 —— 注入的滚轮事件要落到底下那个窗口。停止有两条不需要焦点的
//  路：点胶囊上的停止，或者再按一次截图快捷键/菜单项（`ScreenshotController.toggle()`）。
//

import AppKit
import Storage

/// 控制胶囊上的按钮。
enum ScreenshotLiveAction: Equatable {
    /// 停止并出图（录屏=收 MP4，滚动截图=把已经拼好的部分出图）。
    case finish
    /// 丢掉这一场，什么都不出。
    case cancel
}

/// 控制胶囊本体：一条浮层，自己画底衬、读数和两枚按钮。
final class ScreenshotLivePanelView: NSView {
    static let height: CGFloat = 34
    static let cellWidth: CGFloat = 30
    static let padding: CGFloat = 9
    static let gap: CGFloat = 5
    static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    /// 这枚停止按钮该怎么表意：录屏时是「停止并保存」，滚动截图时是「就到这里，出图」。
    enum Kind { case scroll, record }

    var kind: Kind = .scroll { didSet { needsDisplay = true } }
    /// 读数（录屏=已录时长，滚动截图=已拼尺寸）。空串就不画文字。
    var readout = "" { didSet { needsDisplay = true } }
    var onAction: ((ScreenshotLiveAction) -> Void)?

    /// 两枚按钮在本视图坐标里的矩形，从左到右。取证核对布局用。
    var actionableRects: [NSRect] { [stopRect, cancelRect] }
    var elementIDs: [String] { ["finish", "cancel"] }

    override var isFlipped: Bool { true }

    /// 实况采集时前台还是被滚/被录的那个 App（遮罩已经收掉，胶囊又不抢键盘焦点）。
    /// 不放开这一下的话，用户点第一下只是把 MacStroke activate 起来，按钮得点两次才生效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 按视图宽度算出来的两枚按钮位置（右对齐，中间留缝）。
    private var stopRect: CGRect {
        CGRect(x: bounds.maxX - Self.padding - Self.cellWidth,
               y: (bounds.height - Self.cellWidth) / 2, width: Self.cellWidth, height: Self.cellWidth)
    }

    private var cancelRect: CGRect {
        CGRect(x: stopRect.minX - Self.gap - Self.cellWidth,
               y: stopRect.minY, width: Self.cellWidth, height: Self.cellWidth)
    }

    /// 当前读数该给胶囊多宽。
    static func width(for readout: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: readoutFont]
        let text = ceil((readout as NSString).size(withAttributes: attributes).width)
        let dot: CGFloat = text > 0 ? 14 : 0
        return padding + dot + text + padding + gap + cellWidth + gap + cellWidth + padding
    }

    override func resetCursorRects() {
        for rect in actionableRects { addCursorRect(rect, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = ToolbarStyle.resolved(for: effectiveAppearance)
        style.barFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        style.barBorder.setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        edge.lineWidth = 1
        edge.stroke()

        if !readout.isEmpty {
            var x = bounds.minX + Self.padding
            if kind == .record {
                // 录的时候给一颗红点当「还在录」的活体信号；只写时长看不出它到底停没停。
                style.cancel.setFill()
                let dot = CGRect(x: x, y: bounds.midY - 4, width: 8, height: 8)
                NSBezierPath(ovalIn: dot).fill()
                x += 14
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.readoutFont,
                                                             .foregroundColor: style.glyph]
            let size = (readout as NSString).size(withAttributes: attributes)
            (readout as NSString).draw(at: CGPoint(x: x, y: bounds.midY - size.height / 2),
                                       withAttributes: attributes)
        }
        drawStop(in: stopRect, color: style.cancel)
        drawCancel(in: cancelRect, color: style.glyph)
    }

    /// 停止 = 一枚实心方块（录像机上那个读法），不必借系统符号。
    private func drawStop(in rect: CGRect, color: NSColor) {
        let side: CGFloat = 12
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        color.setFill()
        NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
    }

    private func drawCancel(in rect: CGRect, color: NSColor) {
        color.setStroke()
        let arm: CGFloat = 6
        let cross = NSBezierPath()
        cross.lineWidth = 1.8
        cross.lineCapStyle = .round
        cross.move(to: CGPoint(x: rect.midX - arm, y: rect.midY - arm))
        cross.line(to: CGPoint(x: rect.midX + arm, y: rect.midY + arm))
        cross.move(to: CGPoint(x: rect.midX + arm, y: rect.midY - arm))
        cross.line(to: CGPoint(x: rect.midX - arm, y: rect.midY + arm))
        cross.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// 按下时落在哪枚按钮上。`mouseDown` 必须自己吃掉：不接的话事件顺 responder chain
    /// 冒上去，而这扇窗**故意**不抢键盘焦点（见文件头那条），冒到 NSWindow 就没人管了 ——
    /// 用户点停止会毫无反应（注解条那一层踩过同一个坑）。
    private var downAction: ScreenshotLiveAction?

    override func mouseDown(with event: NSEvent) {
        downAction = action(at: event)
    }

    override func mouseUp(with event: NSEvent) {
        let released = action(at: event)
        let pressed = downAction
        downAction = nil
        // 按下去和松开必须在同一枚上：从停止拖到取消再松手，两件事都不该发生。
        guard let released, released == pressed else { return }
        NSLog("%@", "[ScreenshotLive] 胶囊上点了「\(released == .finish ? "停止" : "取消")」")
        onAction?(released)
    }

    private func action(at event: NSEvent) -> ScreenshotLiveAction? {
        let point = convert(event.locationInWindow, from: nil)
        if stopRect.contains(point) { return .finish }
        if cancelRect.contains(point) { return .cancel }
        return nil
    }
}

/// 区域描边窗的视图：只画一圈边，不吃鼠标。
final class ScreenshotLiveOutlineView: NSView {
    static let lineWidth: CGFloat = 2
    var color = ToolbarStyle.accent { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !bounds.isEmpty else { return }
        let inset = Self.lineWidth / 2
        color.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
        edge.lineWidth = Self.lineWidth
        edge.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 两扇窗的生命周期：摆出来、改读数、收掉。
final class ScreenshotLivePanel {
    /// 胶囊和区域下沿之间的缝，以及离屏边的最小距离。
    static let gap: CGFloat = 8
    static let margin: CGFloat = 6

    private let region: NSRect
    private let visible: NSRect
    private let outlineWindow: ScreenshotOutlineWindow
    private let controlWindow: ScreenshotControlWindow
    private var lastWidth: CGFloat = 0

    var onAction: ((ScreenshotLiveAction) -> Void)? {
        get { controlWindow.panelView.onAction }
        set { controlWindow.panelView.onAction = newValue }
    }

    var panelView: ScreenshotLivePanelView { controlWindow.panelView }

    /// `region` 是采集区域在屏幕上的 AppKit 矩形（左下原点）。
    init(region: NSRect, visible: NSRect, kind: ScreenshotLivePanelView.Kind) {
        self.region = region
        self.visible = visible
        self.outlineWindow = ScreenshotOutlineWindow(region: region)
        outlineWindow.outlineView.color = kind == .record
            ? ToolbarStyle.resolved(for: NSApp.effectiveAppearance).cancel
            : ToolbarStyle.accent
        self.controlWindow = ScreenshotControlWindow(
            frame: ScreenshotLivePanel.controlFrame(region: region,
                                                    size: NSSize(width: ScreenshotLivePanelView.width(for: ""),
                                                                 height: ScreenshotLivePanelView.height),
                                                    visible: visible))
        controlWindow.panelView.kind = kind
    }

    func present() {
        outlineWindow.orderFront(nil)
        controlWindow.orderFront(nil)
    }

    /// 换读数（每帧/每秒一次）。宽度变了就重摆，但只按**当前**宽度算，不做动画。
    func update(readout: String) {
        let view = controlWindow.panelView
        if view.readout != readout {
            view.readout = readout
            resize(readout: readout)
        }
    }

    private func resize(readout: String) {
        let size = NSSize(width: ScreenshotLivePanelView.width(for: readout),
                          height: ScreenshotLivePanelView.height)
        guard abs(size.width - lastWidth) > 0.5 else { return }
        lastWidth = size.width
        // 整条按同一条规则重摆：胶囊右端贴区域右下，读数变长只往左长。
        controlWindow.setFrame(Self.controlFrame(region: region, size: size, visible: visible),
                               display: true)
        controlWindow.panelView.frame = NSRect(origin: .zero, size: size)
    }

    func dismiss() {
        outlineWindow.orderOut(nil)
        outlineWindow.close()
        controlWindow.orderOut(nil)
        controlWindow.close()
    }

    /// 胶囊摆哪儿：优先贴在区域**下沿外侧**、右端对齐；顶到 Dock 就翻到区域上沿外侧；
    /// 两边都放不下（区域几乎占满整屏）才压进区域内部的底边。
    ///
    /// 纯函数：`region`/`visible` 都由调用方给，单测不用真找一块屏。
    static func controlFrame(region: NSRect, size: NSSize, visible: NSRect) -> NSRect {
        let x = clamped(region.maxX - size.width,
                        low: visible.minX + margin, high: visible.maxX - size.width - margin)
        var y = region.minY - gap - size.height
        let above = region.maxY + gap
        if y < visible.minY + margin {
            y = above + size.height <= visible.maxY - margin ? above : region.minY + gap
        }
        y = clamped(y, low: visible.minY + margin, high: visible.maxY - size.height - margin)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func clamped(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), max(high, low))
    }
}

/// 区域描边窗：透明、穿透、不进采集。
final class ScreenshotOutlineWindow: NSWindow {
    let outlineView = ScreenshotLiveOutlineView(frame: .zero)

    init(region: NSRect) {
        // 边框画在窗内，所以窗外扩半个线宽，让那条线正好压在区域边界上而不是差半个像素。
        let inset = ScreenshotLiveOutlineView.lineWidth / 2
        super.init(contentRect: region.insetBy(dx: -inset, dy: -inset),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(Int(CGShieldingWindowLevel()) - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关键：这扇窗不能出现在采集里（描边压在区域边界上，录进成片就是一圈洗不掉的线）。
        sharingType = .none
        outlineView.frame = NSRect(origin: .zero, size: region.insetBy(dx: -inset, dy: -inset).size)
        contentView = outlineView
    }

    override var canBecomeKey: Bool { false }
}

/// 控制胶囊窗。
final class ScreenshotControlWindow: NSWindow {
    let panelView: ScreenshotLivePanelView

    init(frame: NSRect) {
        self.panelView = ScreenshotLivePanelView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(Int(CGShieldingWindowLevel()) - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none
        contentView = panelView
    }

    /// 不抢键盘焦点：见文件头那条（抢了会把用户正在滚的那个 App 挤到后台）。
    override var canBecomeKey: Bool { false }
}
