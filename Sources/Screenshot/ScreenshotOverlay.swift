//
//  ScreenshotOverlay.swift
//  MacStroke
//
//  截图选区的遮罩窗口：把定格的那一帧 1:1 铺满整屏，在其上拖选区、下注解。
//
//  形态抄 CanvasWindow（EventCapture 用的那层全屏透明窗），差别有两处，都是
//  功能性质决定的：
//  1. `ignoresMouseEvents` 必须关掉 —— 手势轨迹靠 CGEventTap 喂点，所以那层是
//     穿透的；这里要自己吃鼠标拖拽。
//  2. 必须覆盖 `canBecomeKey` —— borderless 窗口默认不能成为 key 窗，不覆盖就
//     收不到 Esc 和回车，只能靠鼠标。
//
//  视图是 flipped 的（原点在屏左上角），这样视图坐标和 CGImage 的位图坐标同向，
//  换算只剩缩放，见 ScreenshotFrame.pixelRect。
//
//  两态（选和改都在同一层遮罩里做完，不再另开编辑窗）：
//  - picking：鼠标划过 = 亮出它底下的那个窗（吸附预览，落到桌面上就亮整块屏），
//    按下拖动 = 手拖选区，按下没拖动 = 认下吸附的那块。松手够大就进 editing。
//  - editing：注解条浮在选区**下沿外侧**，选区边框上有八个把手。此时四种拖动各走一
//    路：按住把手 = 缩放，选区内按住（且没选工具）= 整块平移，选区外拖 = 重新框选，
//    按住注解条的空白处 = 把整条拖到屏上任意位置（全屏截图时不挪开就没法编辑被压住
//    的那块）。选了工具之后选区内让位给画注解 —— 注解本身画在整屏坐标里，所以改框
//    不会把已经画好的注解弄丢或挪位。
//
//  「亮区一点都不压暗」是这条链路的手感关键：QQ/微信截图时鼠标停在哪个窗上，那个
//  窗就是原样亮度、其余整屏压暗，用户靠这个亮度差判断「截的就是这一块」。反过来
//  如果整屏一起暗，看着就像隔了层毛玻璃，谁也不知道选中的是哪里 —— 所以暗区是拿
//  四条带子**围**出来的，不是半透明黑盖住再挖洞，见 shade(around:)。
//

import AppKit
import CoreGraphics
import Storage

/// 覆盖整屏的截图遮罩。
final class ScreenshotOverlayWindow: NSWindow {
    init(screenFrame: NSRect) {
        super.init(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        // 盖住菜单栏和其他所有窗，选区才是「屏幕上看到的那块」。
        level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
}

/// 编辑态选区上的八个把手：四条边 + 四个角。
///
/// 用 OptionSet 表示「动哪几条边」，缩放就只剩四行赋值；顺序也要单独定 —— 角上那点
/// 同时落在两条边的判定区里，必须让角先赢，否则拖角会退化成只动一条边。
enum RegionHandle: Int, CaseIterable {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

    /// 命中判定要按这个顺序查（角优先）。
    static let grabOrder: [RegionHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight,
                                            .top, .bottom, .left, .right]

    var edges: RegionEdges {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        case .topLeft: return [.top, .left]
        case .topRight: return [.top, .right]
        case .bottomLeft: return [.bottom, .left]
        case .bottomRight: return [.bottom, .right]
        }
    }

    var cursor: NSCursor {
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

/// 一次缩放要拖动哪几条边。
struct RegionEdges: OptionSet {
    let rawValue: Int
    static let left = RegionEdges(rawValue: 1 << 0)
    static let right = RegionEdges(rawValue: 1 << 1)
    static let top = RegionEdges(rawValue: 1 << 2)
    static let bottom = RegionEdges(rawValue: 1 << 3)
}

/// 遮罩上的一层交互视图：拖选、吸附预览、注解、注解条、出口。
public final class ScreenshotSelectionView: NSView {
    /// 合成好的最终图交给上层（写剪贴板 / 存盘 / 收窗），视图不碰 pasteboard。
    /// 第三个参数是这块选区在**屏幕上的 AppKit 矩形**：贴图要钉回它原来的位置，
    /// 而视图是 flipped 的、副屏原点还可能不是 (0,0)，上层自己换算不了。
    public var onFinish: ((CGImage, ScreenshotOutput, NSRect) -> Void)?
    public var onCancel: (() -> Void)?
    /// 提取文字的结果交回上层（写剪贴板、弹提示）。视图自己不碰 pasteboard。
    public var onText: ((ScreenshotTextOutcome) -> Void)?

    /// 定格的那一帧。名字避开 `frame` —— NSView 已经占了这个名字。
    private let shot: ScreenshotFrame
    /// 底图按**点**尺寸包装，draw(in:) 才会 1:1 铺满；原图像素比这大，Retina 下
    /// 就是原生清晰度。
    private let backdrop: NSImage

    /// 吸附候选：本屏上各窗口在本视图坐标里的矩形，由上层在**定格那一刻**取好后
    /// 塞进来（顺序从最前台往后）。视图自己不查 CGWindowList：底图是静止的，
    /// 边划边查会圈住早就关掉的窗。
    var windows: [CGRect] = []

    // MARK: 会话状态（internal：单测要能把视图摆到指定状态再离屏渲染取证）

    enum Phase { case picking, editing }
    var phase = Phase.picking
    var selection: CGRect = .zero
    /// 鼠标此刻吸附到的那个窗。
    var hover: CGRect?
    private var anchor: NSPoint?
    /// 这次按下有没有真的拖动。双击的第一下 click 也必须留着上一次的选区，
    /// 否则第二下来到时选区已经被清空，「双击复制」永远命中不了。
    private var dragged = false

    var annotations: [ScreenshotAnnotation] = []
    /// 正在拖、还没定下来的一条。
    var draft: ScreenshotAnnotation?
    /// 撤销掉、还能再放回来的那些（栈顶 = 最后撤掉的一条）。
    var undone: [ScreenshotAnnotation] = []
    /// 「裁剪」进行中：这块是当前的整块选区，也就是新的框只能在它里面画；
    /// nil = 正常选区态（可以框全屏）。internal：状态机取证要看它进没进、退没退。
    var cropBounds: CGRect?
    /// 提取文字正在后台跑：这期间那枚格子按下去无效（`private(set)` 给取证看状态机，
    /// 结果回来之前它必须是 true，否则等于允许用户叠两次识别）。
    private(set) var ocrRunning = false
    /// 编辑态里按住的把手（缩放选区），nil = 没在改框。
    private var resizeHandle: RegionHandle?
    /// 整块平移选区：按下时的位置 + 按下点，拖动量按这两者算，累加会漂。
    private var moveFrom: CGPoint?
    private var moveStart: CGRect = .zero
    /// 注解条的位置：nil = 跟着选区摆；非 nil = 用户把它拖到了这儿，之后改框/平移都不
    /// 再挪回来。全屏截图时条子正压在画面上，不给这条路用户就没法编辑被盖住的那块。
    private var toolbarPinned: CGPoint?
    /// 正在拖注解条：按下点 + 按下时条子原点。
    private var toolbarDragFrom: CGPoint?
    private var toolbarDragStart: CGPoint = .zero
    /// 选中的工具；nil = 注解条上一个工具都没选，此时选区内的拖动用来平移选区。
    var tool: ScreenshotTool?
    var colorIndex = 0
    var widthIndex = 0
    /// internal 而非 private：状态机取证要看条子在不在、摆对没对。
    var toolbar: ScreenshotToolbarView?
    /// 选区阶段跟着光标的放大镜。偏好里关掉就压根不建这层视图。
    /// internal 而非 private：和 toolbar 同一个理由，取证要看它在不在、跟没跟对。
    private(set) var magnifierView: ScreenshotMagnifierView?
    /// 悬停在条子某一格上时的功能提示。同上，internal 给取证看。
    private(set) var tipView: ScreenshotTipView?
    var magnifierEnabled = true
    var magnification: ScreenshotMagnification = .medium
    private var textEditor: NSTextField?

    private let dimColor = NSColor(calibratedWhite: 0, alpha: 0.55)
    private let minDragDistance: CGFloat = 4

    /// 把手方块的边长和命中半径。方块只有 7pt，但判定要给到 8pt —— 用户是照着
    /// 那条线去抓的，差一两像素就该算抓到。
    static let handleSize: CGFloat = 7
    static let handleSlop: CGFloat = 8
    /// 缩到比这更小就没法在里头画东西了，也不值得再截。
    static let minRegionSize: CGFloat = 20

    public init(shot: ScreenshotFrame) {
        self.shot = shot
        self.backdrop = NSImage(cgImage: shot.image, size: shot.pointSize)
        super.init(frame: NSRect(origin: .zero, size: shot.pointSize))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard phase == .editing, hasSelection else { return }
        // 后加的矩形盖住先加的，所以底衬在最前、四个角最后（角上要给角）。
        for handle in RegionHandle.grabOrder.reversed() {
            addCursorRect(Self.zone(handle, of: selection), cursor: handle.cursor)
        }
    }

    private func refreshCursorZones() {
        window?.invalidateCursorRects(for: self)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // 吸附预览靠 mouseMoved，而遮罩窗是程序化弹出的、用户还没「进过」这个视图，
        // 所以必须 activeAlways，否则第一条 mouseMoved 要等鼠标穿过一次才来。
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .inVisibleRect, .mouseMoved],
                                       owner: self, userInfo: nil))
    }

    var currentColor: NSColor { ScreenshotToolbarView.palette[colorIndex] }
    var currentLineWidth: CGFloat { ScreenshotToolbarView.lineWidths[widthIndex] }
    private var hasSelection: Bool { selection.width > 0 && selection.height > 0 }

    /// 该保持原样亮度的那块：已定下的选区优先，其次是吸附预览。
    var focusRect: CGRect? {
        if hasSelection { return selection }
        return phase == .picking ? hover : nil
    }

    // MARK: - 绘制

    public override func draw(_ dirtyRect: NSRect) {
        backdrop.draw(in: bounds)

        guard let focus = focusRect?.intersection(bounds), !focus.isEmpty else {
            dimColor.setFill()
            bounds.fill(using: .sourceOver)
            drawHint()
            return
        }
        shade(around: focus)

        // 裁剪进行中也把注解画出来：那幅框是在注解图之上重画的，注解一收用户就以为丢了。
        if phase == .editing || cropBounds != nil { drawAnnotations(inside: focus) }

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: focus)
        border.lineWidth = 1
        border.stroke()

        if phase == .editing { drawHandles(of: focus) }
        if phase == .picking {
            drawSizeReadout(of: focus)
            // 整块屏亮着 = 还没选中任何具体的窗，这时候说明文字得继续留在屏上
            // （否则按下第一条 mouseMoved 之后提示就没了，没人知道还能按什么）。
            if focus == bounds { drawHint() }
        }
    }

    /// 暗区用**四条带子围**出来，而不是「整屏半透明黑 + 偶数填充挖洞」：挖洞那种
    /// 写法依赖 NSBezierPath 的 winding rule，规则一变选区就跟着被蒙上一层灰 ——
    /// 而用户报的正是「选中和没选中都隔着遮罩」。带子不依赖任何填充规则。
    private func shade(around focus: CGRect) {
        dimColor.setFill()
        let bands = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                   height: max(0, focus.minY - bounds.minY)),
            CGRect(x: bounds.minX, y: focus.maxY, width: bounds.width,
                   height: max(0, bounds.maxY - focus.maxY)),
            CGRect(x: bounds.minX, y: focus.minY, width: max(0, focus.minX - bounds.minX),
                   height: focus.height),
            CGRect(x: focus.maxX, y: focus.minY, width: max(0, bounds.maxX - focus.maxX),
                   height: focus.height),
        ]
        for band in bands where !band.isEmpty { band.fill(using: .sourceOver) }
    }

    /// 注解只画在亮区里：出了选区的部分既看不到也不该被裁进结果，钳住才不会
    /// 在选区外留半条线。
    private func drawAnnotations(inside focus: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: focus)
        for annotation in annotations where annotation.dirtyRect.intersects(focus) {
            annotation.draw(shot: shot)
        }
        draft?.draw(shot: shot)
        context.restoreGState()
    }

    /// 八个把手：白底 + 主色描边的小方块。看不见把手就没人知道这块还能改，
    /// 所以它必须画在边框之上、注解条之外。
    private func drawHandles(of rect: CGRect) {
        let side = Self.handleSize
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        for handle in RegionHandle.allCases {
            let center = Self.center(of: handle, in: rect)
            let box = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            box.fill(using: .sourceOver)
            let edge = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    // MARK: - 把手几何（internal：状态机和单测共用同一份判定，不各算各的）

    /// 把手的中心。边把手落在边的中点，角把手落在角上。
    static func center(of handle: RegionHandle, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX + (rect.width / 2) * horizontal(handle),
                y: rect.midY + (rect.height / 2) * vertical(handle))
    }

    /// 命中区：角是 2×slop 的方块，边是沿边铺开的一条（两端让给角）。
    static func zone(_ handle: RegionHandle, of rect: CGRect) -> CGRect {
        let slop = handleSlop
        let side = slop * 2
        switch handle {
        case .topLeft: return CGRect(x: rect.minX - slop, y: rect.minY - slop, width: side, height: side)
        case .topRight: return CGRect(x: rect.maxX - slop, y: rect.minY - slop, width: side, height: side)
        case .bottomLeft: return CGRect(x: rect.minX - slop, y: rect.maxY - slop, width: side, height: side)
        case .bottomRight: return CGRect(x: rect.maxX - slop, y: rect.maxY - slop, width: side, height: side)
        case .top: return CGRect(x: rect.minX + slop, y: rect.minY - slop,
                                 width: max(0, rect.width - side), height: side)
        case .bottom: return CGRect(x: rect.minX + slop, y: rect.maxY - slop,
                                    width: max(0, rect.width - side), height: side)
        case .left: return CGRect(x: rect.minX - slop, y: rect.minY + slop,
                                  width: side, height: max(0, rect.height - side))
        case .right: return CGRect(x: rect.maxX - slop, y: rect.minY + slop,
                                   width: side, height: max(0, rect.height - side))
        }
    }

    /// 这一点按住了哪个把手（角优先）。
    static func handle(at point: CGPoint, of rect: CGRect) -> RegionHandle? {
        RegionHandle.grabOrder.first { zone($0, of: rect).contains(point) }
    }

    /// 按住把手拖动：只有被点中的那几条边跟着走，另外几条钉在原处；不翻面、不缩没、
    /// 不出屏。
    static func resize(_ rect: CGRect, edges: RegionEdges, to point: CGPoint, limit: CGRect) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if edges.contains(.left) { minX = min(point.x, maxX - minRegionSize) }
        if edges.contains(.right) { maxX = max(point.x, minX + minRegionSize) }
        if edges.contains(.top) { minY = min(point.y, maxY - minRegionSize) }
        if edges.contains(.bottom) { maxY = max(point.y, minY + minRegionSize) }
        return CGRect(x: max(minX, limit.minX), y: max(minY, limit.minY),
                      width: min(maxX, limit.maxX) - max(minX, limit.minX),
                      height: min(maxY, limit.maxY) - max(minY, limit.minY))
    }

    /// 整块平移：尺寸不变，越界就停在屏边（不是弹回去）。
    static func move(_ rect: CGRect, from start: CGPoint, to point: CGPoint, limit: CGRect) -> CGRect {
        let x = min(max(rect.minX + point.x - start.x, limit.minX), max(limit.maxX - rect.width, limit.minX))
        let y = min(max(rect.minY + point.y - start.y, limit.minY), max(limit.maxY - rect.height, limit.minY))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private static func horizontal(_ handle: RegionHandle) -> CGFloat {
        switch handle {
        case .left, .topLeft, .bottomLeft: return -1
        case .right, .topRight, .bottomRight: return 1
        default: return 0
        }
    }

    private static func vertical(_ handle: RegionHandle) -> CGFloat {
        switch handle {
        case .top, .topLeft, .topRight: return -1
        case .bottom, .bottomLeft, .bottomRight: return 1
        default: return 0
        }
    }

    /// 亮区的像素尺寸。写像素而不是点，因为用户关心的是「截出来多大」；吸附预览阶段
    /// 也报同一块，用户点下去之前就知道会得到多大一张图。
    private func drawSizeReadout(of rect: CGRect) {

        let label = "\(Int((rect.width * shot.scale).rounded())) × \(Int((rect.height * shot.scale).rounded()))"
        let text = NSAttributedString(string: label, attributes: Self.readoutAttributes)
        let size = text.size()
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - 6)
        if origin.y < bounds.minY { origin = CGPoint(x: rect.minX, y: rect.minY + 6) }
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 4)
        NSColor(calibratedWhite: 0, alpha: 0.7).setFill()
        box.fill(using: .sourceOver)
        text.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2))
    }

    /// 还没拖选区时，把按键说明打在屏幕中间，否则没人知道能按什么。
    private func drawHint() {
        let text = NSAttributedString(string: L("Drag to select, Enter edits, Esc cancels"),
                                      attributes: Self.readoutAttributes)
        let size = text.size()
        let box = CGRect(x: (bounds.midX - size.width / 2) - 8,
                         y: bounds.midY - size.height / 2 - 4,
                         width: size.width + 16, height: size.height + 8)
        NSColor(calibratedWhite: 0, alpha: 0.7).setFill()
        box.fill(using: .sourceOver)
        text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4))
    }

    private static let readoutAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    // MARK: - 鼠标

    // 事件回调只负责把窗口坐标换成视图坐标，判定全在 pointer* 那几个方法里：
    // NSEvent 造不出来，状态机只能这样才验得动。

    public override func mouseDown(with event: NSEvent) {
        pointerDown(convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    public override func mouseDragged(with event: NSEvent) {
        pointerDragged(to: convert(event.locationInWindow, from: nil))
    }

    public override func mouseUp(with event: NSEvent) {
        pointerReleased()
    }

    public override func mouseMoved(with event: NSEvent) {
        pointerMoved(convert(event.locationInWindow, from: nil))
    }

    func pointerDown(_ point: NSPoint, clickCount: Int) {
        // 点别处先把正在输入的字定下来（字段编辑器的焦点不会自动离开本视图）。
        if textEditor != nil { finishTextEditing(commit: true) }
        // 一按下去提示就该收：接下来要么拖条子要么画注解，气泡压在内容上碍事。
        hideTip()

        if phase == .editing, let bar = toolbar, !bar.isHidden, bar.frame.contains(point) {
            // 条子压着谁就归谁：按在按钮上那一下由条子自己处理（真事件里 hitTest 就把
            // 它拦下了，这里再挡一次是让被打断点驱动的判定树和真实链路答得一样），
            // 按在空白处那一下是「拖着整条走」。
            guard !bar.hasActionable(atOverlayPoint: point) else { return }
            toolbarDragFrom = point
            toolbarDragStart = bar.frame.origin
            return
        }

        // 双击落在选区内 = 复制并收起（QQ/微信的手感）。手指已经在这块里了，
        // 比挪去注解条点复制快。
        if clickCount >= 2, hasSelection, selection.contains(point) {
            finish(.copy)
            return
        }

        if phase == .editing, hasSelection {
            // 把手优先于画注解：照着边框那一条按下去，想要的是「改这块」而不是在边上画一线。
            if let handle = Self.handle(at: point, of: selection) {
                resizeHandle = handle
                return
            }
            // 没选工具时，选区内按住 = 整块平移；选了工具就还让位给画注解。
            if tool == nil, selection.contains(point) {
                moveFrom = point
                moveStart = selection
                return
            }
        }

        if phase == .editing, hasSelection, selection.contains(point), let tool {
            switch tool {
            case .text:
                beginTextEditing(at: point)
                return
            case .number:
                appendNumber(at: point)
                return
            default:
                draft = ScreenshotAnnotation(tool: tool, color: currentColor,
                                             lineWidth: currentLineWidth,
                                             start: point,
                                             points: tool == .pen ? [point] : [])
                needsDisplay = true
                return
            }
        }

        anchor = point
        dragged = false
    }

    func pointerDragged(to point: NSPoint) {
        if let draft {
            // 画笔走点列：每一帧往轨迹上追加一个抽过稀的点，其余工具只有一个跟着
            // 光标跑的终点。
            self.draft = draft.tool == .pen ? draft.extendingPen(to: point)
                : ScreenshotAnnotation(tool: draft.tool, color: draft.color,
                                       lineWidth: draft.lineWidth,
                                       start: draft.start, end: point)
            needsDisplay = true
            return
        }
        if let from = toolbarDragFrom, let bar = toolbar {
            // 手抖一下（不到 slop）不该把条子从「跟着选区走」改成钉死在原地。
            let next = CGPoint(x: toolbarDragStart.x + point.x - from.x,
                               y: toolbarDragStart.y + point.y - from.y)
            guard abs(next.x - toolbarDragStart.x) + abs(next.y - toolbarDragStart.y)
                    > Self.toolbarDragSlop else { return }
            let pinned = Self.clampedToolbarOrigin(next, size: bar.frame.size, container: bounds)
            toolbarPinned = pinned
            bar.frame.origin = pinned
            return
        }
        // 改框（缩放/平移）不走 anchor：这两种拖动期间一直是 editing，
        // 注解和注解条都跟着新框走，不会被退回选区态。
        if let handle = resizeHandle {
            selection = Self.resize(selection, edges: handle.edges, to: point, limit: bounds)
            showToolbar()
            needsDisplay = true
            return
        }
        if let from = moveFrom {
            selection = Self.move(moveStart, from: from, to: point, limit: bounds)
            showToolbar()
            needsDisplay = true
            return
        }
        guard let anchor else { return }
        if phase == .editing {
            // 在选区外重新框选：注解条先收起来，新选区松手后再浮出来。
            phase = .picking
            toolbar?.isHidden = true
            hideTip()
        }
        selection = Self.rect(from: anchor, to: point, in: cropBounds ?? bounds)
        dragged = true
        hover = nil
        needsDisplay = true
        // 拖选期间也跟着走：边界正是在这一步上卡准的。
        followMagnifier(at: point)
    }

    func pointerReleased() {
        if draft != nil {
            commitDraft()
            return
        }
        if toolbarDragFrom != nil {
            toolbarDragFrom = nil
            refreshCursorZones()
            return
        }
        if resizeHandle != nil {
            resizeHandle = nil
            refreshCursorZones()
            return
        }
        if moveFrom != nil {
            moveFrom = nil
            refreshCursorZones()
            return
        }
        guard anchor != nil else { return }
        anchor = nil
        if !dragged {
            // 裁剪中按下没拖动 = 这一刀不切了，回到原来那块。
            if cropBounds != nil { cancelCrop(); return }
            // 按下没拖动 = 认下吸附的那个窗；吸附不到就当用户点了一下空处。
            if phase == .picking, let hover {
                selection = hover
                self.hover = nil
                enterEditing()
            }
            return
        }
        if selection.width < minDragDistance || selection.height < minDragDistance {
            // 裁剪中拖出的框太小：这刀不值得切，原框留着。
            if cropBounds != nil { cancelCrop(); return }
            selection = .zero
            needsDisplay = true
            return
        }
        if phase == .picking {
            cropBounds = nil
            enterEditing()
        }
    }

    func pointerMoved(_ point: NSPoint) {
        // 悬停提示只在编辑态、条子露出来的时候有；选区阶段压根没有条子。
        if phase == .editing { followTip(at: point) }
        // 裁剪中不吸附：那是在一幅已经框好的图上再切一块，吸到窗口边界会把框顶出底板。
        guard phase == .picking, cropBounds == nil, anchor == nil, draft == nil else { return }
        // 落到桌面上（包括菜单栏、程序坞那两条不属于任何普通窗的边）就吸**整块屏**：
        // 候选表只收 layer == 0 的普通窗，不给这条兜底，用户永远点不出一张全屏截图，
        // 只能手拖到四个角 —— 而 QQ/微信在这里都是整屏高亮。
        let next = ScreenshotWindowProbe.rect(containing: point, in: windows) ?? bounds
        if next != hover {
            hover = next
            needsDisplay = true
        }
        followMagnifier(at: point)
    }

    // MARK: - 放大镜

    /// 把放大镜跟到这一点上。它只在自己这十几平方点里重绘，不牵动整屏遮罩 —— 遮罩
    /// 那张底图是按 hover 变化才重画的，跟着鼠标每动一次重铺一遍全屏会白烧 CPU。
    private func followMagnifier(at point: NSPoint) {
        guard phase == .picking, magnifierEnabled else {
            magnifierView?.isHidden = true
            return
        }
        let view = magnifierView ?? ScreenshotMagnifierView(shot: shot)
        magnifierView = view
        if view.superview == nil { addSubview(view) }
        view.isHidden = false
        view.follow(point: point, magnification: magnification, in: bounds)
    }

    // MARK: - 悬停提示

    /// 把功能提示跟到条子上被指到的那一格。移出格子就收 —— 提示是「这一格是什么」，
    /// 没有格子可指的时候留着只会挡内容。
    private func followTip(at point: NSPoint) {
        guard let bar = toolbar, !bar.isHidden, let tip = bar.tip(atOverlayPoint: point) else {
            hideTip()
            return
        }
        let view = tipView ?? ScreenshotTipView()
        tipView = view
        if view.superview == nil { addSubview(view) }
        view.show(tip.text, cell: tip.cell, in: bounds)
    }

    private func hideTip() {
        tipView?.isHidden = true
    }

    /// 复制当前那一点的色值（⌘C）。返回有没有东西可复制 —— 放大镜还没现身时没有。
    /// 确认提示就地画在面板上：遮罩在 shielding 层，App 层那只 Toast（popUpMenu 层）
    /// 会被整屏遮罩压住，喊了也看不见。
    @discardableResult
    func copyMagnifierColor() -> Bool {
        guard let view = magnifierView, !view.isHidden, let text = view.colorText else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        view.markCopied()
        return true
    }

    public override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    // MARK: - 键盘

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc：正在裁剪时先退掉这一刀，别把整个截图会话一起丢了
            if cropBounds != nil { cancelCrop() } else { onCancel?() }
        case 36, 76:  // Return / 小键盘 Enter
            if hasSelection { finish(.copy) } else if let hover {
                selection = hover
                enterEditing()
            }
        case 51, 117:  // Delete / Backspace：退一条注解，和注解条上的撤销同一路
            undo()
        case 8:  // c：⌘C 复制放大镜上那一点的色值。选区阶段没有别的复制可做，
                // 进编辑态后放大镜收了，这条也就落回 super（不抢注解文字框的复制）。
            if event.modifierFlags.contains(.command), !copyMagnifierColor() {
                super.keyDown(with: event)
            }
        case 6:  // z：Cmd/Ctrl+Z 撤销，再按住 Shift 就是重做
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 编辑态

    /// 选区落定：亮出注解条和八个把手，把焦点还回遮罩（注解条上的输入框可能刚被用过）。
    func enterEditing() {
        guard hasSelection else { return }
        phase = .editing
        hover = nil
        // 选区已经落定，放大镜就该收：编辑态要的是看清内容，不是再卡一个像素。
        magnifierView?.isHidden = true
        // 新选区（含重框）= 条子回到「跟着这块走」；用户手动拖过的位置只在这一块选区
        // 里有效，换了一块还钉在原处就成了凭空冒出来的浮条。
        toolbarPinned = nil
        showToolbar()
        needsDisplay = true
        refreshCursorZones()
        window?.makeFirstResponder(self)
    }

    private func showToolbar() {
        let bar = toolbar ?? ScreenshotToolbarView(frame: .zero)
        toolbar = bar
        if bar.superview == nil {
            addSubview(bar)
            wire(bar)
        }
        bar.isHidden = false
        bar.frame = currentToolbarFrame(for: bar)
        syncToolbar()
    }

    /// 条子现在该摆在哪：用户拖过就钉在他放的那个点（只保证还在屏内），否则跟着选区。
    private func currentToolbarFrame(for bar: ScreenshotToolbarView) -> CGRect {
        guard let pinned = toolbarPinned else {
            return Self.toolbarFrame(selection: selection, toolbarWidth: bar.preferredWidth,
                                     container: bounds)
        }
        let size = NSSize(width: bar.preferredWidth, height: ScreenshotToolbarView.barHeight)
        return CGRect(origin: Self.clampedToolbarOrigin(pinned, size: size, container: bounds),
                      size: size)
    }

    private func wire(_ bar: ScreenshotToolbarView) {
        bar.onTool = { [weak self] picked in
            guard let self else { return }
            // 再点一次同一个工具 = 取消选择，回到「拖选区就是重框」。
            self.tool = self.tool == picked ? nil : picked
            if self.textEditor != nil { self.finishTextEditing(commit: true) }
            self.syncToolbar()
        }
        bar.onColor = { [weak self] index in
            guard let self else { return }
            self.colorIndex = index
            self.syncToolbar()
        }
        bar.onWidth = { [weak self] index in
            guard let self else { return }
            self.widthIndex = index
            self.syncToolbar()
        }
        bar.onUndo = { [weak self] in self?.undo() }
        bar.onRedo = { [weak self] in self?.redo() }
        bar.onCrop = { [weak self] in self?.beginCrop() }
        bar.onOCR = { [weak self] in self?.extractText() }
        bar.onPin = { [weak self] in self?.finish(.pin) }
        bar.onSave = { [weak self] in self?.finish(.save) }
        bar.onCopy = { [weak self] in self?.finish(.copy) }
        bar.onCancel = { [weak self] in self?.onCancel?() }
    }

    private func syncToolbar() {
        toolbar?.sync(activeTool: tool, colorIndex: colorIndex, widthIndex: widthIndex,
                      canUndo: !annotations.isEmpty, canRedo: !undone.isEmpty,
                      canOCR: !ocrRunning)
    }

    /// 注解条离屏边留多少：整条贴着屏边就点不到最外侧那个出口了。
    static let toolbarMargin: CGFloat = 6
    /// 按住条子空白处拖动多少像素才算「要挪它」，少于这个当手抖。
    static let toolbarDragSlop: CGFloat = 4

    /// 注解条摆在选区**下沿外侧**（和 QQ 同一条位置）。下面顶到屏底就翻进选区内侧，
    /// 再挤就贴住屏底 —— 宁可盖住选区最后一行，也不能让用户点不到出口。
    static func toolbarFrame(selection: CGRect, toolbarWidth: CGFloat, container: NSRect) -> CGRect {
        let height = ScreenshotToolbarView.barHeight
        let margin = toolbarMargin
        let gap: CGFloat = 8
        let x = min(max(selection.midX - toolbarWidth / 2, container.minX + margin),
                    max(container.maxX - toolbarWidth - margin, container.minX + margin))
        var y = selection.maxY + gap
        if y + height > container.maxY - margin {
            y = selection.maxY - height - gap
        }
        if y < container.minY + margin { y = container.maxY - height - margin }
        return CGRect(x: x, y: y, width: toolbarWidth, height: height)
    }

    /// 手动拖出来的位置也要留在屏内：条子上带着复制/存盘/取消三个出口，整条拖出去
    /// 就等于把这些按钮弄丢了，而用户接下来还要靠它们出图。
    static func clampedToolbarOrigin(_ origin: CGPoint, size: NSSize,
                                    container: NSRect) -> CGPoint {
        let margin = toolbarMargin
        return CGPoint(x: min(max(origin.x, container.minX + margin),
                              max(container.maxX - size.width - margin, container.minX + margin)),
                       y: min(max(origin.y, container.minY + margin),
                              max(container.maxY - size.height - margin, container.minY + margin)))
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        undone.append(last)
        syncToolbar()
        needsDisplay = true
    }

    /// 把最后撤掉的那条放回列表尾部：位置、颜色、轨迹都在对象里，不需要再算一遍。
    func redo() {
        guard let last = undone.popLast() else { return }
        annotations.append(last)
        syncToolbar()
        needsDisplay = true
    }

    // MARK: - 裁剪

    /// 「裁剪」= 拿当前选区当底板再框一块（QQ 那条路上的剪刀）。进这块时把注解条先收起来，
    /// 松手后再浮出来；没拖或者拖得太小就回到原来那块。
    func beginCrop() {
        guard phase == .editing, hasSelection else { return }
        cropBounds = selection
        phase = .picking
        hover = nil
        toolbar?.isHidden = true
        hideTip()
        magnifierView?.isHidden = true
        needsDisplay = true
    }

    private func cancelCrop() {
        guard let base = cropBounds else { return }
        cropBounds = nil
        selection = base
        enterEditing()
    }

    /// 选区在屏幕上的 AppKit 矩形（左下原点）。贴图要钉回选区原来的位置就靠它。
    /// 遮罩窗和视图一样大、原点 (0,0)，所以换成屏幕坐标只剩翻 y 加窗口原点。
    var selectionScreenRect: NSRect {
        guard let window else { return .zero }
        let rect = selection.intersection(bounds)
        return NSRect(x: window.frame.minX + rect.minX,
                      y: window.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    private func commitDraft() {
        defer { draft = nil }
        guard let draft else { return }
        // 手抖出来的两三个像素不算一条注解，只当用户放弃了这次绘制。
        if draft.rect.width < 3 && draft.rect.height < 3 { return }
        push(draft)
        syncToolbar()
        needsDisplay = true
    }

    private func appendNumber(at point: CGPoint) {
        let number = annotations.filter { $0.tool == .number }.map { $0.number }.max().map { $0 + 1 } ?? 1
        push(ScreenshotAnnotation(tool: .number, color: currentColor,
                                  lineWidth: currentLineWidth,
                                  start: point, number: number))
        syncToolbar()
        needsDisplay = true
    }

    /// 新画的一条总是终结掉重做栈：撤掉 A 之后画了 B，就不该还能把 A 塞回 B 后面。
    private func push(_ annotation: ScreenshotAnnotation) {
        undone.removeAll()
        annotations.append(annotation)
    }

    // MARK: - 文字输入

    /// 就地起一个无边框输入框：让用户在「要写字的那个位置」上打字，比先弹个小面板
    /// 输入完再点回屏幕顺手得多。
    private func beginTextEditing(at point: CGPoint) {
        let fontSize = max(13, currentLineWidth * 4)
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y - 2,
                                              width: min(220, max(80, bounds.maxX - point.x)),
                                              height: fontSize + 8))
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.22)
        field.textColor = currentColor
        field.font = NSFont.boldSystemFont(ofSize: fontSize)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.target = self
        field.action = #selector(textEditorCommitted(_:))
        field.placeholderString = L("Screenshot Type Text")
        addSubview(field)
        textEditor = field
        window?.makeFirstResponder(field)
    }

    /// 回车（走 action）或点到别处（走 mouseDown）都算提交；Esc 走 delegate 丢弃。
    @objc private func textEditorCommitted(_ sender: NSTextField) {
        finishTextEditing(commit: true)
    }

    private func finishTextEditing(commit: Bool) {
        guard let field = textEditor else { return }
        textEditor = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = field.frame.origin
        let color = currentColor
        let lineWidth = currentLineWidth
        field.removeFromSuperview()
        if commit, !text.isEmpty {
            // 输入框的字就是按 `max(13, lineWidth*4)` 画的，和注解自己算的 fontSize
            // 同一条式子，所以落笔后大小不会跳。
            push(ScreenshotAnnotation(tool: .text, color: color, lineWidth: lineWidth,
                                      start: origin, text: text))
            syncToolbar()
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    /// 拖选方向不限，先归一化成左上原点矩形。鼠标拖出屏幕外时 AppKit 照样给越界
    /// 坐标，钳进 bounds 才不会算出超出底图的选区。
    private static func rect(from start: NSPoint, to end: NSPoint, in bounds: NSRect) -> CGRect {
        let corner = CGPoint(x: min(max(end.x, bounds.minX), bounds.maxX),
                             y: min(max(end.y, bounds.minY), bounds.maxY))
        return CGRect(x: min(start.x, corner.x), y: min(start.y, corner.y),
                      width: abs(start.x - corner.x), height: abs(start.y - corner.y))
    }

    // MARK: - 出口

    /// 「提取文字」：认的是合成后的那张图 —— 和绿✓复制出去的是同一块内容，所以用户
    /// 手写的文字注解也一起能被认出来。结果交回上层，视图不碰 pasteboard。
    func extractText() {
        guard !ocrRunning, phase == .editing, hasSelection else { return }
        if textEditor != nil { finishTextEditing(commit: true) }
        guard let image = ScreenshotComposer.compose(shot: shot, selection: selection,
                                                     annotations: annotations) else { return }
        ocrRunning = true
        syncToolbar()
        ScreenshotOCR.recognize(image) { [weak self] outcome in
            guard let self else { return }
            // 识别在后台跑的这几百毫秒里用户可能已经 Esc 收窗了。那时候再把字塞进
            // 剪贴板，就是往一个已经结束的会话后面补一刀 —— 丢掉。
            guard self.window != nil else { return }
            self.ocrRunning = false
            self.syncToolbar()
            self.onText?(outcome)
        }
    }

    private func finish(_ output: ScreenshotOutput) {
        if textEditor != nil { finishTextEditing(commit: true) }
        guard let image = ScreenshotComposer.compose(shot: shot, selection: selection,
                                                     annotations: annotations) else {
            onCancel?()
            return
        }
        onFinish?(image, output, selectionScreenRect)
    }
}

extension ScreenshotSelectionView: NSTextFieldDelegate {
    /// 输入框里的 Esc 只该结束输入，不该把整个截图会话关掉。
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishTextEditing(commit: false)
        return true
    }

    /// 焦点自己跑掉了（点了别的 App、切了窗）：按提交处理，别把用户写了一半的字丢了。
    public func controlTextDidEndEditing(_ notification: Notification) {
        finishTextEditing(commit: true)
    }
}
