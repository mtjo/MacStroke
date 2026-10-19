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
//  已画的注解也能回头改（用户 2026-10-19：「添加的注释方向方框等要支持编辑」）：没选工具
//  时，选区内那一按先问注解再问选区 —— 露着的把手 = 缩放那一条，注解本体 = 挪那一条，
//  都没按到才是整块平移。选中那条同时浮出属性面板，改的只有被选中的这一条（口径全是
//  用户 2026-10-19 点的：入口「没选工具时直接点它」、范围「平移 + 缩放 + 改样式 + 删这一条」、
//  落点「只改被选中的那一条」）。删 = Delete/Backspace，撤销从此按整表快照走。
//
//  选区阶段屏顶还浮着一条**模式条**（截图 / 滚动截图 / 录屏 / 文字识别，见
//  `ScreenshotModeBarView`）：它决定「选区落定之后干什么」。`routeAfterSelection()`
//  就是那个分流口 —— 「截图」进 editing 走注解条，「文字识别」直接跑 OCR，
//  「滚动截图」「录屏」把选区交回上层去开实况采集（那时候遮罩要整个收掉，因为
//  这两条要的是**活画面**，冻结帧机制在这里反过来）。模式条只在选区阶段露面，
//  一进编辑态就让位给注解条。
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

    /// 只有四个角的那一档：给文字和序号当把手集（它们只能等比缩放，边把手改不出「只宽一点」
    /// 的字，见 `ScreenshotAnnotation.editableGrabs`）。顺序仍沿用上面那一条，命中口径一致。
    static let cornerOrder: [RegionHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

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
    /// 选区落定后要开**实况采集**（滚动截图 / 录屏）。这两个要的正是遮罩机制反过来：
    /// 定格帧得收掉、屏幕还给用户，接下来一帧一帧现抓。
    /// 三个参数：模式、视图坐标的选区、这块选区在**屏幕上的 AppKit 矩形**。
    var onLiveCapture: ((ScreenshotMode, CGRect, NSRect) -> Void)?

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
    /// 正在拖选中那条注解的哪一部分：本体 = 整条平移，`grab` = 抓着了某个把手/端点。
    enum AnnotationDrag { case body, grab(AnnotationGrab) }
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
    /// 撤销/重做栈：存**整表快照**，不再是「弹掉尾部那条」。
    ///
    /// 已画注解能编辑之后，一步动作可以是「中间某条挪了位/换了样式」，只记对象增删就回不
    /// 去改前那一态了。`history` 栈顶 = 当前这一态之前那张表，`future` 栈顶 = 最近撤掉的那态。
    /// internal 而非 private：取证要能看见「这一步真的记了一态」，只查屏上那条改没改不够。
    var history: [[ScreenshotAnnotation]] = []
    var future: [[ScreenshotAnnotation]] = []
    /// 选中的那条已画注解（`annotations` 里的下标）。nil = 没选中。
    ///
    /// internal 而非 private：状态机取证要核对「点这一条选中的确实是它」，
    /// 只断言「有选中」等于没核对下标 —— 串到别那条上照样全绿。
    var selectedIndex: Int?
    /// 正在拖选中那条的哪一部分：本体 = 整条平移，把手/端点 = 缩放。nil = 没在拖。
    private var annotationDrag: AnnotationDrag?
    /// 装了工具那一按**还没定下来是点还是拖**时，记下这一按压着的是哪条已画注解：
    /// 松手时位移不到一条注解的最小尺寸（`commitDraft` 里那 3pt），就按「点它=选中它」
    /// 结算，落回这条上；真的拖出一块，这一笔记作废、照常画出新的一条。
    ///
    /// 为什么不在按下那一刻就选中：装了工具之后「拖=画新笔」是这条路上最主要动作，而
    /// 起点压着旧注解是常事（框完一个再框里面那个）。按下就选中会把画新笔改成挪旧的那条，
    /// 所以要等手停下来才知道用户要的是哪一件。文字、序号那两格按下就出结果，等不到松手，
    /// 所以在按下那一刻直接问 `annotationIndex(at:)`（见 `pointerDown`）。
    var tapSelectCandidate: Int?
    /// 按下那一刻那条注解的原样。拖动每帧都从它算，不拿上一帧的结果累加 —— 逐帧累加
    /// 会把取整过的字号、圆角越拖越偏（选区平移也是同一口径，见 `moveStart`）。
    private var annotationOriginal: ScreenshotAnnotation?
    private var annotationDragFrom: CGPoint?
    /// 一次连续手势（拖注解、滑滑杆）合成一步撤销用的账：手势开始前的整表 + 手势标记。
    private var editBase: [ScreenshotAnnotation]?
    private var editTag: String?
    /// 每按下一次自增，给手势标记凑出「这一次」的编号（同一条注解拖两下 = 两步撤销）。
    private var editToken = 0
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
    /// 屏顶模式条选了哪一档。internal 而非 private：取证要核对「点某一格真的把会话
    /// 切到了那一档」，而不是只把格子点亮。
    var mode: ScreenshotMode = .still
    /// 屏顶的模式条。同上，internal 给取证看它在不在、摆对没对、点下去切没切。
    private(set) var modeBar: ScreenshotModeBarView?
    /// 偏好里的「截图默认工具」：选区落定时预先装进 `tool` 的那一格，关掉就是 nil。
    var defaultTool: ScreenshotTool?
    /// 每格工具自己的一套粗细/颜色（issue #73）。**只活在这次截图会话里**：切走再切回
    /// 那一格还是它自己那套，关掉这次截图就全部回到「红 + 默认粗细」，不写偏好（用户
    /// 2026-10-18 定的口径）。没记过的工具走 `ScreenshotToolStyle.default(for:)`。
    var styles: [ScreenshotTool: ScreenshotToolStyle] = [:]
    /// 选中工具后浮在它上方的属性面板。internal 而非 private：取证要看它在不在、
    /// 钉对没钉对那一格。
    private(set) var toolPanel: ScreenshotToolPanelView?
    /// internal 而非 private：状态机取证要看条子在不在、摆对没对。
    var toolbar: ScreenshotToolbarView?
    /// 选区阶段跟着光标的放大镜。偏好里关掉就压根不建这层视图。
    /// internal 而非 private：和 toolbar 同一个理由，取证要看它在不在、跟没跟对。
    private(set) var magnifierView: ScreenshotMagnifierView?
    /// 悬停在条子某一格上时的功能提示。同上，internal 给取证看。
    private(set) var tipView: ScreenshotTipView?
    var magnifierEnabled = true
    var magnification: ScreenshotMagnification = .medium
    private(set) var textEditor: NSTextField?
    /// 输入框现在在给**哪一条已画的文字**改内容（双击那条文字 = 改它的字）。nil = 正在
    /// 写一条新的。internal 给取证看「这一按起的是新字还是改旧字」—— 两条路的收场完全不同。
    var editingAnnotationIndex: Int?

    private let dimColor = NSColor(calibratedWhite: 0, alpha: 0.55)
    private let minDragDistance: CGFloat = 4

    /// 把手方块的边长和命中半径。方块只有 7pt，但判定要给到 8pt —— 用户是照着
    /// 那条线去抓的，差一两像素就该算抓到。
    static let handleSize: CGFloat = 7
    static let handleSlop: CGFloat = 8

    /// 按到注解**本体**上算命中的余量：比把手松一点。用户是照着那条线去抓的，
    /// 差两三像素就该算抓到；再给宽就会把细线之间的空隙也吞掉，选区平移反而做不了。
    static let annotationHitSlop: CGFloat = 6

    /// 选中那条注解的把手方块边长。刻意比选区那八个（`handleSize` = 7）小一号：
    /// 同屏两套把手时得一眼分出哪个是改框、哪个是改这一条注解。
    static let annotationHandleSize: CGFloat = 5

    /// 打码拖动时那一圈辅助线的颜色与粗细。
    static let mosaicGuideColor = NSColor(srgbRed: 0.13, green: 0.55, blue: 1.0, alpha: 1)
    static let mosaicGuideWidth: CGFloat = 1.5
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
        // 选中那条注解的把手先加：后加的矩形盖住先加的，所以和选区边框重合的那一点上
        // 显示的是「改框」的箭头 —— 按下判定也是同一个顺序（见 `pointerDown`）。
        if let index = selectedIndex, annotations.indices.contains(index) {
            for grab in annotations[index].editableGrabs.reversed() {
                addCursorRect(annotations[index].grabZone(grab), cursor: grab.cursor)
            }
        }
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

    /// 这一格工具现在该用什么值。没记过 = 默认（红 + 一档适中的粗细）。
    func style(for tool: ScreenshotTool) -> ScreenshotToolStyle {
        styles[tool] ?? ScreenshotToolStyle.default(for: tool)
    }

    /// 当前选中那一格的值。`tool` 为 nil（没选工具）时按矩形那一格算 —— 这个值只在真要
    /// 落笔时被读到，而落笔的前提就是选着某一格。
    var currentStyle: ScreenshotToolStyle { style(for: tool ?? .rect) }
    var currentColor: NSColor { currentStyle.color }
    var currentLineWidth: CGFloat { currentStyle.lineWidth }
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

        if phase == .editing {
            drawHandles(of: focus)
            drawAnnotationSelection()
        }
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
        for (index, annotation) in annotations.enumerated()
        where annotation.dirtyRect.intersects(focus) && index != editingAnnotationIndex {
            annotation.draw(shot: shot)
        }
        if let draft {
            draft.draw(shot: shot)
            drawMosaicGuide(for: draft)
        }
        context.restoreGState()
    }

    /// 正在拖的打码块描一圈蓝边：它只是把那片变糊，同色底上根本看不出这块到哪为止。
    ///
    /// **只在拖动过程中画** —— 松手后这一笔进了注解列表，边框就跟着没了，成品 PNG 上
    /// 也就不会留一圈谁都没要过的蓝框。颜色刻意写死 sRGB：这条线不进图，但离屏取证要
    /// 读到确定的像素值，而系统那组动态蓝在浅/深外观下解析出两种蓝。
    private func drawMosaicGuide(for draft: ScreenshotAnnotation) {
        guard draft.tool == .mosaic, !draft.rect.isEmpty else { return }
        Self.mosaicGuideColor.setStroke()
        let inset = Self.mosaicGuideWidth / 2
        let edge = NSBezierPath(rect: draft.rect.insetBy(dx: inset, dy: inset))
        edge.lineWidth = Self.mosaicGuideWidth
        edge.stroke()
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

    // MARK: - 选中那条注解的外框（编辑态辅助线）

    /// 选中那条注解画一圈虚线框 + 摆出它能用的把手。
    ///
    /// 只画在遮罩上、且只画在亮区里，**不进导出**（导出走 `ScreenshotExportView`，那里只
    /// 画注解本身）—— 和打码辅助线同一条规矩：帮你看清「这条抓到哪儿」的线不该被带进
    /// 成品图，也不该糊到选区外的暗区上。
    private func drawAnnotationSelection() {
        guard let index = selectedIndex, annotations.indices.contains(index),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let annotation = annotations[index]
        guard !annotation.editBox.isEmpty else { return }
        context.saveGState()
        context.clip(to: selection.intersection(bounds))
        NSColor.controlAccentColor.setStroke()
        let outline = Self.dashedPath(annotation.editBox, dash: 4, gap: 3)
        outline.lineWidth = 1
        outline.stroke()
        drawAnnotationGrabs(annotation)
        context.restoreGState()
    }

    /// 把手：白底 + 主色描边，和选区那八个同一套画法，但小一号（同屏两套把手要分得出
    /// 谁是谁的）。箭头的两个端点画成**圆点** —— 圆点是「一条线的尽头」，方块是「一块框的
    /// 边界」，抓错一类改的是完全不同的东西。
    private func drawAnnotationGrabs(_ annotation: ScreenshotAnnotation) {
        let side = Self.annotationHandleSize
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        for grab in annotation.editableGrabs {
            let center = annotation.grabCenter(grab)
            let box = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            box.fill(using: .sourceOver)
            let edge = grab.isEndpoint ? NSBezierPath(ovalIn: box)
                : NSBezierPath(rect: box.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 1
            edge.stroke()
        }
    }

    /// 沿矩形四边排一段段短横（虚线）。
    ///
    /// 自己排而不用 `NSBezierPath` 的 setDash：那条 API 的相位跟着路径起点走，四条边接在
    /// 角上会留半截，看着像断线。手排每条边都是整段、角上干净，而且段数是确定的 ——
    /// 离屏取证能数着它判「虚线确实画上了」。
    static func dashedPath(_ rect: CGRect, dash: CGFloat, gap: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        for index in 0 ..< 4 {
            let from = corners[index]
            let to = corners[(index + 1) % 4]
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { continue }
            var walked: CGFloat = 0
            while walked < length {
                let end = min(walked + dash, length)
                // 沿边参数化：`from + (to-from) × 比例`，四边共用一条式子才不会哪一条反着排。
                let at: (CGFloat) -> CGPoint = { fraction in
                    CGPoint(x: from.x + (to.x - from.x) * fraction,
                            y: from.y + (to.y - from.y) * fraction)
                }
                path.move(to: at(walked / length))
                path.line(to: at(end / length))
                walked = end + gap
            }
        }
        return path
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
    ///
    /// `minSize` 单独给参数而不写死：选区那条底板要 20pt 才还能在里面画东西，而一条已画
    /// 注解（比如一枚序号）本来就只有二十几点，按底板那档它压根缩不动。默认值保持原样，
    /// 现有调用点一个字都不用改。
    static func resize(_ rect: CGRect, edges: RegionEdges, to point: CGPoint, limit: CGRect,
                       minSize: CGFloat = minRegionSize) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if edges.contains(.left) { minX = min(point.x, maxX - minSize) }
        if edges.contains(.right) { maxX = max(point.x, minX + minSize) }
        if edges.contains(.top) { minY = min(point.y, maxY - minSize) }
        if edges.contains(.bottom) { maxY = max(point.y, minY + minSize) }
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
    /// 文案跟着模式条选中的那一档换：「滚动截图」那档回车不是编辑，提示还写「回车编辑」
    /// 就是把用户往错的方向引。
    private func drawHint() {
        let text = NSAttributedString(string: L(mode.hintKey),
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

        // 属性面板同理：落在面板里的这一按归面板（真事件里它的 hitTest 整块吃掉），
        // 判定树这儿再挡一次，免得被断点驱动的那棵树在面板底下画出一条注解。
        if let panel = toolPanel, !panel.isHidden, panel.frame.contains(point) { return }

        // 屏顶模式条同上：按在格子上那一下归格子（真事件里它自己的 mouseDown 吃掉），
        // 这里再挡一次让判定树和真实链路答得一样。空白处放行给遮罩 —— 从屏顶往下拖
        // 一个选区是合法操作，条子不能把整条横向范围都吃掉。
        if let bar = modeBar, !bar.isHidden, bar.frame.contains(point),
           bar.hasActionable(atOverlayPoint: point) {
            return
        }

        // 双击落在选区内 = 复制并收起（QQ/微信的手感）。手指已经在这块里了，
        // 比挪去注解条点复制快。其余三档双击是「再来一次这一档的事」：文字识别失败后
        // 双击该重认，而不是把这张图复制走。
        if clickCount >= 2, hasSelection, selection.contains(point) {
            // 双击按在一条**已经写好的字**上 = 改它的内容（用户 2026-10-19 定的口径）。
            // 「点它=选中它」之后，旧文字再没有第二条路能把字换掉，双击是专门为它留的
            // 那一条；其余落点维持老手感「复制并收起」，其余三档双击还是「再来一次这一档
            // 的事」：文字识别失败后双击该重认，而不是把这张图复制走。
            if mode == .still, let index = textAnnotationIndex(at: point) {
                beginTextEdit(for: index)
                return
            }
            if mode == .still { finish(.copy) } else { routeAfterSelection() }
            return
        }

        if phase == .editing, hasSelection {
            // 把手优先于画注解：照着边框那一条按下去，想要的是「改这块」而不是在边上画一线。
            //
            // 这一层**不能**套进 `selection.contains(point)`：右/下那两个把手的中心正好压在
            // max 边上，而 `CGRect.contains` 对 max 是开区间 —— 一套就点不着那两条边（改版时
            // 就这么踩过一次，红的是 ScreenshotFlowTests 的 testEdgeHandleResizesSelection、
            // testResizeNeverFlipsOrCollapses、testToolbarDragNeedsSlop 三条，注解套件全绿，
            // 因为它俩量的是把手不是选区）。
            if let handle = Self.handle(at: point, of: selection) {
                resizeHandle = handle
                return
            }
            if selection.contains(point) {
                // 选中态 > 工具态（用户 2026-10-19 定的口径：「要取消掉工具选择才能点选对应的
                // 框」这一层得去掉）。按在自己选中的那一条上 = 改它：把手/端点 = 缩放，线上
                // = 整条平移，装了工具也让路。只有「刚选中/刚画完的那一条」有这待遇，其余条
                // 一律走下面那一路（拖 = 画新的，点一下不拖 = 选中它），否则框完一个想接着
                // 在它里面框第二个，第二笔会被改成挪第一个。
                if let index = selectedIndex, annotations.indices.contains(index) {
                    if let grab = selectedGrab(at: point) {
                        beginAnnotationDrag(.grab(grab), index: index, at: point)
                        return
                    }
                    if annotations[index].contains(point, slop: Self.annotationHitSlop) {
                        beginAnnotationDrag(.body, index: index, at: point)
                        return
                    }
                }
                // 没选工具时，选区内按住 = 先给已画注解让路，都没有了才是整块平移。
                // 三层顺序按「用户照着哪儿按」排：露着的把手 > 注解本体 > 底下的选区。
                // 点着一条线想挪它却把整块选区拖走，是这一层最容易做反的手感（用户
                // 2026-10-19：「添加的注释方向方框等要支持编辑」）。
                if tool == nil {
                    if let index = annotationIndex(at: point) {
                        // 一下按下去既选中、又开始挪：照着一条线拖，想要的就是挪它。
                        // 只选中不动手的话，用户得点两下才能改，比 QQ 慢半拍。
                        beginAnnotationDrag(.body, index: index, at: point)
                        return
                    }
                    // 点着空处 = 先把选中交还掉，这一次拖动仍是平移整块选区。
                    selectAnnotation(nil)
                    moveFrom = point
                    moveStart = selection
                    return
                }
            }
        }

        if phase == .editing, hasSelection, selection.contains(point), let tool {
            // 文字、序号是「按下就出结果」的两格：等不到松手看位移，所以「点它=选中它、
            // 点空处=写字/盖章」必须在按下那一刻分家（用户定的口径）。
            if tool == .text || tool == .number {
                if let index = annotationIndex(at: point) {
                    beginAnnotationDrag(.body, index: index, at: point)
                    return
                }
                if tool == .text { beginTextEditing(at: point) } else { appendNumber(at: point) }
                return
            }
            // 其余格子：先按「要画新的」起笔，压着的那条记下来当候选，松手时才知道
            // 这一按是拖还是点（见 `tapSelectCandidate`）。
            tapSelectCandidate = annotationIndex(at: point)
            draft = ScreenshotAnnotation(tool: tool, color: currentColor,
                                         lineWidth: currentLineWidth,
                                         start: point,
                                         points: tool == .pen ? [point] : [])
            needsDisplay = true
            return
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
        if let drag = annotationDrag, let original = annotationOriginal,
           let from = annotationDragFrom, let index = selectedIndex,
           annotations.indices.contains(index) {
            // 每一帧都拿 `original` 当基准（不是拿上一帧的结果）：逐帧累加会把取整过的
            // 字号、圆角越拖越偏。`limit` 给整块屏而不是选区 —— 注解本来就能画在选区外
            // （只是不出图），按选区钳死会让一条压出框的注解一按就跳回框里。
            switch drag {
            case .body:
                let box = original.editBox
                let moved = Self.move(box, from: from, to: point, limit: bounds)
                annotations[index] = original.movedBy(CGSize(width: moved.minX - box.minX,
                                                             height: moved.minY - box.minY))
            case .grab(let grab):
                annotations[index] = original.applyingResize(grab, to: point, limit: bounds)
            }
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
            // 面板钉在条子某一格上方，条子动了它必须跟着走，不然尖就指错了格子。
            syncPanel()
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
            hideBarChrome()
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
        if annotationDrag != nil {
            annotationDrag = nil
            annotationOriginal = nil
            annotationDragFrom = nil
            // 一次拖动 = 一步撤销：起点是按下那一刻那张表（`beginEdit` 记的），
            // 真改动过才记账，手抖一下不算一步。
            endEdit()
            syncPanel()
            refreshCursorZones()
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
            // 走分流口而不是直接进编辑态：实况那两档点一下窗就是要开始采集那块，
            // 把它送进注解条等于告诉用户「这一档没生效」。
            if phase == .picking, let hover {
                selection = hover
                self.hover = nil
                routeAfterSelection()
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
            routeAfterSelection()
        }
    }

    /// 选区落定之后干什么 —— 模式条那一档就是这里的开关。
    private func routeAfterSelection() {
        switch mode {
        case .still:
            enterEditing()
        case .text:
            // 认完就收场，中间不停在注解条上：这一档的用户要的是文字，不是框。
            hideModeBar()
            extractText()
        case .scroll, .record:
            hideModeBar()
            onLiveCapture?(mode, selection, screenRect(for: selection))
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

    // MARK: - 编辑已画的注解（用户 2026-10-19：「添加的注释方向方框等要支持编辑」）
    //
    // 入口是「没选工具时直接点它」（用户定的口径）：选区内那一按先问已画注解，再问选区
    // 本身。几何与样式怎么变全在 `ScreenshotAnnotation` 那一段纯函数里，这里只管
    // 「选中了哪一条、按住的是哪儿、拖到了哪儿」—— 所以那半边能直接单测，这半边是状态机。

    /// 这一点按到了哪条注解的本体。从数组尾部往前找：后画的压在先画的上面，视觉上最靠前
    /// 的那条该先被抓到（`annotations` 的顺序就是绘制顺序，见 `drawAnnotations(inside:)`）。
    func annotationIndex(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed()
        where annotations[index].contains(point, slop: Self.annotationHitSlop) { return index }
        return nil
    }

    /// 同上，但只认**文字**那一种：双击改内容只对该写字的地方开，双击压在矩形框线上
    /// 仍然是「复制并收起」（老手感，别把它一起改了）。
    func textAnnotationIndex(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed()
        where annotations[index].tool == .text
            && annotations[index].contains(point, slop: Self.annotationHitSlop) { return index }
        return nil
    }

    /// 按住的是选中那条注解的某个把手吗。
    ///
    /// **只有选中了才露把手**：没选中的条子那一按该是「选中 + 挪它」，不是改尺寸 ——
    /// 照着一条线的角按下去就把框拉大，误改比改不动糟得多。
    func selectedGrab(at point: CGPoint) -> AnnotationGrab? {
        guard let index = selectedIndex, annotations.indices.contains(index) else { return nil }
        return annotations[index].grab(at: point)
    }

    /// 选中/取消选中某条已画注解（下标越界一律当「取消」）。
    ///
    /// 越界不当「保留」：撤销、删除之后列表可能变短，让下标继续指着别的那条，面板就会
    /// 把 A 的样式显示成 B 的、用户一改改到 B 上 —— 指错比没指更糟。
    ///
    /// Esc 收过面板那笔账（`panelDismissed`）不在这儿清：生产里「带上标的选中」只有按下
    /// 那条路（`beginAnnotationDrag`）走得到，那儿已经清了；在这儿再写一遍是永远不会被
    /// 执行到的第二套账（反向变异 M20 实测：摘掉它 41 条全绿）。
    func selectAnnotation(_ index: Int?) {
        let next = index.flatMap { annotations.indices.contains($0) ? $0 : nil }
        guard next != selectedIndex else { return }
        // 不再改这一条了，把它的样式改动结算成一步撤销。
        endEdit()
        selectedIndex = next
        syncPanel()
        needsDisplay = true
        refreshCursorZones()
    }

    /// Esc 的一层：取消选中那条注解（面板已经在这一层之前收过了）。
    /// 返回有没有真的取消 —— 没有才该往下走「丢掉整个会话」。internal 给取证走键盘链路。
    @discardableResult
    func clearAnnotationSelection() -> Bool {
        guard selectedIndex != nil else { return false }
        selectAnnotation(nil)
        return true
    }

    /// 开始拖选中那条注解。`index` 必须有效（调用方刚从 `annotations` 里查到它）。
    private func beginAnnotationDrag(_ drag: AnnotationDrag, index: Int, at point: CGPoint) {
        guard annotations.indices.contains(index) else { return }
        selectForEditing(index)
        annotationDrag = drag
        annotationOriginal = annotations[index]
        annotationDragFrom = point
        // 一次拖动 = 一步撤销。token 让每次按下都是新的一次：常量 tag 会把整场会话里
        // 对同一条的多次挪动合成一步，撤一次就回到今天最早的位置，那不是用户要的。
        editToken += 1
        beginEdit(tag: "drag\(editToken)")
    }

    /// 用户明确「按这条就是要改它」：选中它、结掉手里那一半手势、把属性面板要回来。
    ///
    /// 和 `selectAnnotation(_:)` 的分工要分清，别把它们当同一个函数：那条是给「换选中」
    /// 用的，下标没变就整段跳过（不做多余的活）；这条是给**按下**用的 —— 重新按同一条
    /// 也得清账、重弹面板，否则刚用 Esc 收过它的面板，再点它永远弹不出来。
    /// 反向变异 M20 咬的就是这一口。
    private func selectForEditing(_ index: Int) {
        guard annotations.indices.contains(index) else { return }
        // 不再改这一条了，把它的样式改动结算成一步撤销。
        endEdit()
        selectedIndex = index
        panelDismissed = nil
        syncPanel()
        needsDisplay = true
        refreshCursorZones()
    }

    /// Delete / Backspace：选中了就只删那一条。
    ///
    /// 没选中才退回「撤掉最后画的一条」（老行为）。画了十条想撤中间那条，不该逼用户
    /// 从头撤销九次 —— 这一条是「支持编辑」里最硬的需求。
    /// internal 给取证走键盘链路；返回有没有真的删掉。
    @discardableResult
    func deleteSelectedAnnotation() -> Bool {
        guard let index = selectedIndex, annotations.indices.contains(index) else { return false }
        willChange()
        annotations.remove(at: index)
        selectedIndex = nil
        syncToolbar()
        needsDisplay = true
        refreshCursorZones()
        return true
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

    /// 把功能提示跟到被指到的那一格：先问注解条，再问属性面板。移出格子就收 ——
    /// 提示是「这一格是什么」，没有格子可指的时候留着只会挡内容。
    private func followTip(at point: NSPoint) {
        func tip(on view: NSView?) -> (text: String, cell: NSRect)? {
            guard let view, !view.isHidden else { return nil }
            if let bar = view as? ScreenshotToolbarView { return bar.tip(atOverlayPoint: point) }
            if let panel = view as? ScreenshotToolPanelView { return panel.tip(atOverlayPoint: point) }
            return nil
        }
        guard let hit = tip(on: toolbar) ?? tip(on: toolPanel) else {
            hideTip()
            return
        }
        let view = tipView ?? ScreenshotTipView()
        tipView = view
        // 提示永远端到兄弟视图最前面（用户 2026-10-19：「鼠标悬浮提示汽泡应该放在最上层，
        // 现在被粗细颜色的汽泡挡住了」）。`addSubview` 是后来者压上来：先悬停到条子
        // （提示先建）、再点工具格（面板后建），面板就盖在提示上 —— 悬停「矩形」那一格
        // 气泡确实弹了，弹在自己刚点开的面板底下，等于没弹。这里不赌谁先建，直接把
        // 提示挪回栈顶；它 `hitTest` 恒 nil，端上来也不吃点击。
        if view.superview == nil {
            addSubview(view)
        } else if subviews.last !== view {
            addSubview(view, positioned: .above, relativeTo: nil)
        }
        view.show(hit.text, cell: hit.cell, in: bounds)
    }

    private func hideTip() {
        tipView?.isHidden = true
    }

    /// 条子收起来的时候面板必须一起收：它是钉在条子某一格上方的，条子不见了它就没了锚。
    private func hideBarChrome() {
        toolbar?.isHidden = true
        toolPanel?.isHidden = true
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
        case 53:  // Esc 一层一层退：正在裁剪先退这一刀，属性面板开着先收面板，
                  // 还选中着某条注解先取消选中，都没有才把整个会话丢掉。
            if cropBounds != nil { cancelCrop() }
            else if hideToolPanel() { }
            else if clearAnnotationSelection() { }
            else { onCancel?() }
        case 36, 76:  // Return / 小键盘 Enter
            // 「截图」那一档维持老手感：有选区就复制收场，没有就认下吸附的那块。
            // 其余三档回车 = 走模式条那一档自己的路（识别 / 开滚动采集 / 开录制）。
            if mode == .still {
                if hasSelection { finish(.copy) } else if let hover {
                    selection = hover
                    enterEditing()
                }
            } else if hasSelection || hover != nil {
                if !hasSelection, let hover { selection = hover }
                routeAfterSelection()
            }
        case 51, 117:  // Delete / Backspace：选中了某条就只删那一条，没选中才退一条注解
                      // （和注解条上的撤销同一路）。
            if !deleteSelectedAnnotation() { undo() }
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

    // MARK: - 模式条

    /// 屏顶浮出模式条，并把当前那一档点亮。会话期间只摆一次：拖选区时它得原地留着，
    /// 跟着鼠标走反而会把选区上沿盖住。
    ///
    /// internal 而非 private：取证要能在没走「上层建窗」这条链路时把它摆出来；
    /// 真机上由 `ScreenshotController` 在建好遮罩后调一次。
    func showModeBar() {
        let bar = modeBar ?? ScreenshotModeBarView()
        modeBar = bar
        if bar.superview == nil {
            addSubview(bar)
            bar.onPick = { [weak self] picked in self?.pickMode(picked) }
        }
        bar.isHidden = false
        bar.frame = Self.modeBarFrame(width: bar.preferredWidth, container: bounds,
                                      topInset: Self.menuBarInset(of: window?.screen))
        bar.sync(mode: mode)
    }

    private func hideModeBar() {
        modeBar?.isHidden = true
    }

    /// 用户在模式条上点了一格。再点已经亮着的那一档等于没改（不给「取消当前档」这种
    /// 谁也不会想要的中间态）。
    private func pickMode(_ picked: ScreenshotMode) {
        guard mode != picked else { return }
        mode = picked
        modeBar?.sync(mode: picked)
        // 屏上那句按键说明跟着换档重画：文案是 `drawHint()` 现读的。
        needsDisplay = true
    }

    /// 菜单栏在这一块屏里占多高（遮罩铺的是整块屏，含菜单栏那一条）。
    /// 拿不到屏（还没挂窗）就答 0：这时候条子贴屏顶摆，不影响判定。
    static func menuBarInset(of screen: NSScreen?) -> CGFloat {
        guard let screen else { return 0 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// 条子摆哪儿：横向对屏居中，纵向让开菜单栏再留一格缝。纯函数，单测直接喂 inset。
    static func modeBarFrame(width: CGFloat, container: NSRect, topInset: CGFloat) -> CGRect {
        ScreenshotModeBarView.barFrame(width: width, container: container, topInset: topInset)
    }

    // MARK: - 编辑态

    /// 选区落定：亮出注解条和八个把手，把焦点还回遮罩（注解条上的输入框可能刚被用过）。
    func enterEditing() {
        guard hasSelection else { return }
        phase = .editing
        hover = nil
        // 选区已经落定，模式条就该让位：这一档要的是就地注解，屏顶那条不再提供信息，
        // 留着只会让用户以为还能在这儿换档。
        hideModeBar()
        // 选区已经落定，放大镜就该收：编辑态要的是看清内容，不是再卡一个像素。
        magnifierView?.isHidden = true
        // 默认装上偏好里选的那一格（「截图默认工具」，关掉就是 nil）：装了之后框完第一笔
        // 不必先点格子，代价是「在选区内拖动=平移整块」这一步要先摘掉工具才走得到。
        tool = defaultTool
        // 换了一块选区（含重框）= 上一块的选中作废：下标指的是数组位置，留着会让面板
        // 站在「第 3 条」上，而第 3 条现在可能是用户刚在新框里画的东西。
        selectAnnotation(nil)
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
            // 点格子就是「要调属性」的意思，把上一次 Esc 收面板的账清掉。
            self.panelDismissed = nil
            // 拿起工具 = 不再编辑那一条：把手收回去，否则「选着工具还在改旧的一条」两套
            // 意图叠在一块，下一笔落哪儿都说不清。
            self.selectAnnotation(nil)
            if self.textEditor != nil { self.finishTextEditing(commit: true) }
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
        // 撤销/重做的可点性看的是**快照栈**，不是「列表里还有没有东西」：新选区里一条
        // 都没画但撤过一条，撤销键仍该能按（还能重做回来）。
        toolbar?.sync(activeTool: tool, canUndo: !history.isEmpty,
                      canRedo: !future.isEmpty, canOCR: !ocrRunning)
        syncPanel()
    }

    /// 属性面板现在在给**谁**调值：选中了某条已画注解 → 那一条；否则 → 选中的那一格工具。
    ///
    /// 给注解时改的是那一条（用户 2026-10-19 定的口径：只改被选中的那条，不回头刷同工具
    /// 的其他条），给工具时改的是下一笔的默认值。这两件事共用一块面板、一套控件，所以
    /// 「现在在给谁」必须是查出来的一个确定答案，不能靠调用点各自记。
    enum PanelOwner: Equatable {
        case tool(ScreenshotTool)
        case annotation(Int)
    }

    /// 面板现在该给谁（没得给 = nil：摘了工具、打码那一格、或选中的是打码块）。
    /// internal 而非 private：取证要核对「选中一条矩形注解之后，面板报的确实是这条注解」，
    /// 得先能问出它现在站在谁那边。
    func panelOwner() -> PanelOwner? {
        if let index = selectedIndex, annotations.indices.contains(index) {
            // 打码既不吃色也不吃粗细，弹一块只有灰控件的面板等于骗用户点。
            return annotations[index].tool.hasStylePanel ? .annotation(index) : nil
        }
        if let tool, tool.hasStylePanel { return .tool(tool) }
        return nil
    }

    /// 用户刚用 Esc 把面板收掉过：记的是**哪一格工具的面板**被收过，不记的话下一次
    /// `syncToolbar()`（撤销、重做、提取文字都会走）就又给它弹出来，那一下 Esc 像是按在
    /// 棉花上。重新点格子、重新点一条注解会清掉它 —— 那是「要调属性」的意思。
    ///
    /// 记的是工具而不是 `PanelOwner`：画完即选中之后，同一格的面板会在「给这一格工具的下
    /// 一笔」和「给刚画完的那条」之间来回切（`.tool(.rect)` ⇄ `.annotation(3)`），账记在
    /// owner 上就压不住 —— 用户收完面板撤一笔，owner 从注解变回工具，面板又呼地弹出来
    /// （`testCollapsedPanelStaysCollapsedUntilTheCellIsClickedAgain` 钉的就是这一口）。
    private var panelDismissed: ScreenshotTool?

    /// 这一份「在给谁」属于哪一格工具。`index` 的有效性由 `panelOwner()` 保证 —— 它自己
    /// 查过 `annotations.indices` 才敢把 `.annotation(index)` 交出来，这儿再加一遍判断就是
    /// 永远走不到的分支（反向变异那一轮刚清掉一条这种账）。
    private func panelTool(_ owner: PanelOwner) -> ScreenshotTool {
        switch owner {
        case .tool(let picked): return picked
        case .annotation(let index): return annotations[index].tool
        }
    }

    private func syncPanel() {
        guard let owner = panelOwner(), panelTool(owner) != panelDismissed,
              let cell = panelCell(for: owner) else {
            // 面板没地方钉了（摘掉工具、换成打码、Esc 收过）—— 取色器也得跟着收，
            // 它是给这块面板的某一档挑色的，面板都不在了它还开着就是块无主窗。
            toolPanel?.closeColorPicker()
            toolPanel?.isHidden = true
            return
        }
        let panel = toolPanel ?? ScreenshotToolPanelView(frame: .zero)
        toolPanel = panel
        if panel.superview == nil {
            panel.onChange = { [weak self] style in self?.applyPanelStyle(style) }
            addSubview(panel)
        }
        panel.isHidden = false
        let editing: ScreenshotTool
        let value: ScreenshotToolStyle
        switch owner {
        case .tool(let picked):
            editing = picked
            value = style(for: picked)
        case .annotation(let index):
            editing = annotations[index].tool
            value = annotations[index].styleValue
        }
        // `within: bar.frame`：面板横向不许超出注解条的左右沿（用户 2026-10-19 提的）。
        // 锚点那一格用遮罩坐标，条子的 frame 也是遮罩坐标，同一把尺子。
        panel.show(tool: editing, style: value, cell: cell, in: bounds, within: toolbar?.frame)
    }

    /// 面板钉在哪一格上方。选中一条注解时钉在**它自己那一格工具**上：面板还是那条
    /// 「矩形 / 文字」的属性条，用户不用重新学一套东西；换一条不同工具的注解，它就跳过去。
    private func panelCell(for owner: PanelOwner) -> NSRect? {
        let tool: ScreenshotTool
        switch owner {
        case .tool(let picked): tool = picked
        case .annotation(let index):
            guard annotations.indices.contains(index) else { return nil }
            tool = annotations[index].tool
        }
        return toolbar?.cellRect(for: tool)
    }

    /// 面板回吐一次值。给谁改看 `panelOwner()`：选中了某条注解就只改那一条，其余情况
    /// 记的是那一格工具下一次落笔用的值。
    private func applyPanelStyle(_ style: ScreenshotToolStyle) {
        switch panelOwner() {
        case .annotation(let index):
            guard annotations.indices.contains(index) else { return }
            // tag 里带下标 = 「对这一条的样式改动」合成一步撤销：滑杆拖一下会回吐上百次，
            // 按次记账的话撤销一次只挪回一格。
            beginEdit(tag: "panel\(index)")
            annotations[index] = annotations[index].styled(with: style)
            needsDisplay = true
        case .tool(let picked):
            styles[picked] = style
        case nil:
            break
        }
    }

    /// Esc 的第一层：面板（含它展开的调色板）开着就只收面板，条子和选区原地留着。
    /// 返回有没有真的收掉 —— 没有才该往下走「取消选中 / 丢掉整个会话」。
    /// internal 是给取证的：这一层只能从键盘事件进，测试不走一遍就没人知道它在不在。
    @discardableResult
    func hideToolPanel() -> Bool {
        guard let panel = toolPanel, !panel.isHidden else { return false }
        panel.hidePalette()
        panel.isHidden = true
        // 账记在「哪一格工具」上，不记 owner：见 `panelDismissed` 那段。
        if let owner = panelOwner() { panelDismissed = panelTool(owner) }
        return true
    }

    /// 整次截图结束时收掉系统取色面板（控制器那条路走这里）。它挂在比遮罩还高的层上，
    /// 遮罩都没了它还飘在桌面上，就是用户嘴里的「关不掉的窗口」。
    func closeToolColorPicker() { toolPanel?.closeColorPicker() }

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

    // MARK: - 撤销 / 重做（整表快照）

    /// 开始一次连续手势：把改前那张表记下，同一个 `tag` 期间反复调用只算一次。
    ///
    /// 为什么要有 tag：滑杆一拖每帧回吐一次值、拖注解每移动一像素算一次 —— 按帧记账的话
    /// 「滑一下粗细」要撤一百次。一次手势 = 一步撤销，这才是用户按 ⌘Z 时想要的粒度。
    /// internal 给取证直接走手势边界。
    func beginEdit(tag: String) {
        guard editTag != tag else { return }
        endEdit()
        editBase = annotations
        editTag = tag
    }

    /// 结束当前手势：真改动过才记账，手抖一下不算一步。
    func endEdit() {
        let base = editBase
        editBase = nil
        editTag = nil
        guard let base, base != annotations else { return }
        history.append(base)
        future.removeAll()
    }

    /// 一次离散改动（画完一条、删一条、点一次预设色）之前喊一声：把改前那一态压进栈。
    ///
    /// 先把可能还开着的手势结算掉：面板改完样式没重新选别的东西、紧接着画了一条新的，
    /// 那时候栈里还压着「改样式之前」那张表 —— 让它排在离散改动**前面**，撤销才是先撤
    /// 新画的那条，而不是把两笔一起回退到今天最早那一态。
    private func willChange() {
        endEdit()
        history.append(annotations)
        future.removeAll()
    }

    func undo() {
        // 撤销本身不算一次编辑，但它可能打断在一半的手势上（拖动中途按 ⌘Z）：先结算。
        endEdit()
        guard let base = history.popLast() else { return }
        future.append(annotations)
        annotations = base
        // 下标跟着作废：撤销掉的可能正是选中那条（或让它变成了别的一条）。留着下标
        // 会让面板把 A 的样式显示在 B 上，比没选中更误导。
        selectedIndex = nil
        syncToolbar()
        needsDisplay = true
        refreshCursorZones()
    }

    /// 重做：把最近撤掉的那一态整个换回去。样式、位置、删掉的那条都在快照里，不用重算。
    func redo() {
        endEdit()
        guard let next = future.popLast() else { return }
        history.append(annotations)
        annotations = next
        selectedIndex = nil
        syncToolbar()
        needsDisplay = true
        refreshCursorZones()
    }

    // MARK: - 裁剪

    /// 「裁剪」= 拿当前选区当底板再框一块（QQ 那条路上的剪刀）。进这块时把注解条先收起来，
    /// 松手后再浮出来；没拖或者拖得太小就回到原来那块。
    func beginCrop() {
        guard phase == .editing, hasSelection else { return }
        cropBounds = selection
        phase = .picking
        hover = nil
        magnifierView?.isHidden = true
        hideBarChrome()
        hideTip()
        needsDisplay = true
    }

    private func cancelCrop() {
        guard let base = cropBounds else { return }
        cropBounds = nil
        selection = base
        enterEditing()
    }

    /// 这块视图矩形在屏幕上的 AppKit 矩形（左下原点）。
    /// 遮罩窗和视图一样大、原点 (0,0)，所以换成屏幕坐标只剩翻 y 加窗口原点。
    func screenRect(for rect: CGRect) -> NSRect {
        guard let window else { return .zero }
        let cut = rect.intersection(bounds)
        return NSRect(x: window.frame.minX + cut.minX,
                      y: window.frame.maxY - cut.maxY,
                      width: cut.width, height: cut.height)
    }

    /// 选区在屏幕上的 AppKit 矩形（左下原点）。贴图要钉回选区原来的位置就靠它。
    var selectionScreenRect: NSRect { screenRect(for: selection) }

    private func commitDraft() {
        defer { draft = nil; tapSelectCandidate = nil }
        guard let draft else { return }
        // 手抖出来的两三个像素不算一条注解，只当用户放弃了这次绘制。
        guard draft.rect.width < 3 && draft.rect.height < 3 else {
            push(draft)
            syncToolbar()
            needsDisplay = true
            return
        }
        // 这一按没拖出东西 —— 但它压着一条已画的注解，那一按就不是手抖，是「点它」：
        // 选中它、面板要回来（用户 2026-10-19 定的口径：点选即编辑，不必先摘工具）。
        if let candidate = tapSelectCandidate { selectForEditing(candidate) }
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
    ///
    /// **画完即选中**（用户 2026-10-19 定的口径）：落笔的那一条马上就是「现在要改的那条」
    /// —— 把手露出来、面板改的是它，不用摘工具、也不用再点一次。工具仍装着，下一笔照画，
    /// 所以画完这一条想挪它 / 改它的颜色粗细，都在这一条上直接办。
    /// 不另走 `selectForEditing`：那会清掉 Esc 那笔账，而刚画完的这条不是「用户点它要改它」，
    /// 只是绘制落定；面板该不该浮由 `panelOwner()` 自己判（收过这一档就继续收着）。
    private func push(_ annotation: ScreenshotAnnotation) {
        willChange()
        annotations.append(annotation)
        selectedIndex = annotations.count - 1
    }

    // MARK: - 文字输入

    /// 就地起一个无边框输入框：让用户在「要写字的那个位置」上打字，比先弹个小面板
    /// 输入完再点回屏幕顺手得多。
    private func beginTextEditing(at point: CGPoint) {
        editingAnnotationIndex = nil
        // 老行为：输入框的原点比按下点偏 2（flipped 视图里是往上），提交时存的就是**偏过
        // 之后**那个原点。所以改旧字时按注解自己的原点摆回去，位置和第一次落笔完全一致。
        installTextEditor(at: CGPoint(x: point.x, y: point.y - 2), style: currentStyle, text: "")
    }

    /// 双击一条已写的字 = 改它的内容（用户 2026-10-19 定的口径：「点它=选中它」之后，
    /// 旧文字再没有第二条路能把字换掉，所以给这一条留双击）。
    ///
    /// 框**盖在原字上**、样式读那一条自己的（不是面板上当前那套），提交只换文字：位置、
    /// 字号、颜色一个都不动 —— 用户要改的是「写错了个字」，不是重做一遍样式。
    private func beginTextEdit(for index: Int) {
        // `tool == .text` 这一半由调用点保证（`textAnnotationIndex` 只查文字条），反向变异
        // M32 实测摘掉它 85 条全绿 —— 留着不是行为分支，是合同检查：这条链路末尾那句
        // 「字删空＝删条」要是收到一个矩形下标，删掉的就是用户刚画好的框。
        guard annotations.indices.contains(index), annotations[index].tool == .text else { return }
        editingAnnotationIndex = index
        // 原点照那条自己的 `start` 摆：那正是第一次落笔时输入框的原点（见 `beginTextEditing`
        // 那条注释），所以这里不再另加偏移，框盖上去字不会跳。
        installTextEditor(at: annotations[index].start,
                          style: annotations[index].styleValue,
                          text: annotations[index].text)
    }

    private func installTextEditor(at origin: CGPoint, style: ScreenshotToolStyle, text: String) {
        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y,
                                              width: min(220, max(80, bounds.maxX - origin.x)),
                                              height: style.fontSize + 8))
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.22)
        field.textColor = style.color
        field.font = style.textFont
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.target = self
        field.action = #selector(textEditorCommitted(_:))
        field.placeholderString = L("Screenshot Type Text")
        field.stringValue = text
        addSubview(field)
        textEditor = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// 回车（走 action）或点到别处（走 mouseDown）都算提交；Esc 走 delegate 丢弃。
    @objc private func textEditorCommitted(_ sender: NSTextField) {
        finishTextEditing(commit: true)
    }

    private func finishTextEditing(commit: Bool) {
        guard let field = textEditor else { return }
        textEditor = nil
        let editing = editingAnnotationIndex
        editingAnnotationIndex = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = field.frame.origin
        let style = currentStyle
        field.removeFromSuperview()
        if let editing, annotations.indices.contains(editing) {
            // 双击进来的这一趟改的是**那一条**，不是新增一条。Esc（commit=false）交还原样。
            if commit { applyEditedText(text, to: editing) }
        } else if commit, !text.isEmpty {
            // 输入框的字就是按面板上那套（字号 + 粗斜体）画的，落笔后大小不会跳。
            push(ScreenshotAnnotation(tool: .text, color: style.color, lineWidth: style.lineWidth,
                                      start: origin, text: text,
                                      fontSize: style.fontSize, bold: style.bold, italic: style.italic,
                                      borderColor: style.borderColor, backgroundColor: style.backgroundColor))
        }
        syncToolbar()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    /// 双击之后交回来的新内容：只换文字，位置、字号、颜色一个都不动 —— 用户改的是
    /// 「这一个字写错了」，不是重做一遍样式。
    ///
    /// 把字全删空再提交 = 这一条不要了：留一块空底衬在屏上，谁都不认那是自己想要的。
    private func applyEditedText(_ text: String, to index: Int) {
        if text.isEmpty {
            willChange()
            annotations.remove(at: index)
            // 下标一律作废：删掉的可能正是选中那条，也可能让它后面那条往前挪一位 ——
            // 留着就成了「面板把 A 的样式显示在 B 上」（和 `undo()` 同一口径）。
            selectedIndex = nil
            return
        }
        guard annotations[index].text != text else { return }
        willChange()
        annotations[index] = annotations[index].replacingText(text)
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
    ///
    /// 「文字识别」那一档选完直接走这里（不经过注解条），所以判定只看有没有选区，
    /// 不再要求已经在编辑态。
    func extractText() {
        guard !ocrRunning, hasSelection else { return }
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
            // 认输了：模式条那一档没有注解条可退回，把屏顶那条还回去，用户才看得见
            // 「换个框再来一次，或者换回截图那一档」。
            var recognized = false
            if case .lines = outcome { recognized = true }
            if self.mode != .still, !recognized { self.showModeBar() }
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
