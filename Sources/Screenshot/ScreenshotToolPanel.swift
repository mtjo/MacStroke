//
//  ScreenshotToolPanel.swift
//  MacStroke
//
//  选中某一格工具后钉在它上方的属性面板（issue #73 的 2.3，加上用户要的「每个工具
//  单独一套粗细和颜色，默认色都是红色」）。
//
//  为什么把条子里那 8 格（原先的 5 色 + 3 线宽）收进这块浮层：
//  ① 一套全局值不够用 —— 箭头要粗、框要细、字要大，共用一组就得每画一笔改一次；
//  ② 文字要调的东西远不止粗细：字号、粗体、斜体、边框、背景，硬塞进条子就把一条压成两排。
//  面板跟着工具走，选中哪一格就只显示那一格调得动的东西（打码既不吃色也不吃粗细，
//  所以它压根不弹面板 —— 见 `ScreenshotTool.hasStylePanel`）。
//
//  值记在遮罩的 `styles[tool]` 里，**只在本次截图会话内**有效：切走再切回那格工具，
//  它还是自己那套；关掉这次截图就全部回到「红 + 默认粗细」。不写偏好，偏好页也就
//  不多出一堆格子（用户 2026-10-18 定的口径）。
//
//  还是自绘，和注解条同一条路：这层挂在 CGShieldingWindowLevel 的 borderless 窗里，
//  NSSlider/NSButton 的标准 bezel 在里面会渲染成系统设置那种灰块；更要紧的是离屏取证
//  只重放视图自己的 `draw`，用真控件烘出来是空的（条子那边踩过这个坑）。
//

import AppKit
import Storage

/// 一个工具的一套属性。面板改的就是它，落笔时原样抄进 `ScreenshotAnnotation`。
public struct ScreenshotToolStyle: Equatable {
    public var color: NSColor
    /// 形状类（矩形/椭圆/箭头/画笔/序号）的笔宽。
    public var lineWidth: CGFloat
    /// 文字字号。文字那一格的滑杆滑的是它，不再是粗细（issue #73 的抱怨点）。
    public var fontSize: CGFloat
    public var bold: Bool
    public var italic: Bool
    /// nil = 不描边 / 不铺底。
    public var borderColor: NSColor?
    public var backgroundColor: NSColor?

    /// 每格的默认都是「红 + 一档适中的粗细」：没调过就是原版那支红笔。
    /// 线宽取 4（旧条子三档 2/4/7 的中间档）：滑杆连续了，贴着 1 起步会让默认形状
    /// 细得在成品图上看不见。
    public static func `default`(for tool: ScreenshotTool) -> ScreenshotToolStyle {
        ScreenshotToolStyle(color: ScreenshotToolbarView.palette[0],
                            lineWidth: tool == .text ? 2 : 4,
                            fontSize: 24, bold: true, italic: false,
                            borderColor: nil, backgroundColor: nil)
    }

    /// 滑杆的两档量程：粗细给形状，字号给文字。上限给到 24/72 是照着「一块屏」算的 ——
    /// 再粗就该去画遮罩了，不是标注。
    public static let widthRange: ClosedRange<CGFloat> = 1...24
    public static let fontRange: ClosedRange<CGFloat> = 12...72

    /// 这套值对应的字体。就地输入框照着它排版，注解自己也算它 —— 两边必须同源，
    /// 否则回车那一瞬间字会跳一下（见 `ScreenshotAnnotation.font(size:bold:italic:)`）。
    ///
    /// 「同源」只管到**有斜体脸的那一段**：就地框里中文仍是正的，落笔才斜（issue #73 补的
    /// 那一手剪切只加在成品图上）。这是取舍不是漏改 —— 输入中途给框重排样式会打断中文
    /// 输入法的候选串，而那正是这条要服务的人。拉丁两侧都吃同一张真斜体脸，不跳。
    public var textFont: NSFont {
        ScreenshotAnnotation.font(size: fontSize, bold: bold, italic: italic)
    }
}

extension ScreenshotTool {
    /// 这一格有没有可调的属性。打码是「把这块像素化」，颜色与粗细都不进它的画法，
    /// 给它弹一块只有灰控件的面板等于骗用户点。
    public var hasStylePanel: Bool { self != .mosaic }
}

/// 工具属性面板。
final class ScreenshotToolPanelView: NSView {
    /// 调色板此刻在给哪一项挑色。面板上三处都能唤出调色板：主色块、边框块、背景块。
    enum ColorTarget { case main, border, background }

    /// 面板上被按住滑动的滑杆。
    private enum Drag { case none, slider }

    static let width: CGFloat = 236
    static let rowHeight: CGFloat = 22
    static let rowGap: CGFloat = 8
    static let padding: CGFloat = 10
    /// 指示尖（指向那一格的小三角）的高度。**算在面板 frame 里**，理由见 `bodyRect`。
    static let pointerHeight: CGFloat = 6
    /// 面板（含尖）和条子格子之间留的缝：贴着摆会像是格子上长出来的一块。
    static let gapToBar: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    /// 滑杆最少留这么宽：标签再长也只能挤短滑杆，不许把右边的色块和 ⌄ 顶出面板。
    static let minTrackWidth: CGFloat = 24

    private(set) var tool: ScreenshotTool?
    private(set) var style = ScreenshotToolStyle.default(for: .rect)
    /// nil = 调色板收着。非 nil = 多顶出一行色块，且这一行是给谁挑色。
    private(set) var paletteTarget: ColorTarget?
    /// 尖朝下（面板在格子上方）还是朝上（翻到下方）。摆位时定，draw 照着画。
    private(set) var pointerUp = false
    /// 尖对准的横坐标（本视图坐标）：面板被屏边钳过之后，尖不一定还在正中。
    private(set) var pointerX: CGFloat = ScreenshotToolPanelView.width / 2

    private var drag = Drag.none
    private var cells: [(id: String, rect: NSRect, tip: String)] = []
    /// 面板是照着哪一格摆的：记住它，调色板开合改变高度时才能原地长高，
    /// 而不是跳回面板自己算的那个位置。
    private var anchorCell: NSRect?
    /// 摆位时喂进来的那两块范围（容器 = 遮罩 bounds，limits = 注解条）：调色板开合要
    /// 重新摆一次，不记住就会丢掉「不超出条子左右」这条限制。
    private var anchorContainer: NSRect?
    private var anchorLimits: NSRect?
    /// 自定义取色器。真机上是系统 `NSColorPanel`；离屏取证换成记账的替身（见
    /// `ScreenshotColorPicking`）—— 那块面板不在本视图的 `draw` 里，拍不到，
    /// 但它回吐的颜色进没进对的那一档必须验得了。
    var colorPicker: ScreenshotColorPicking = SystemColorPicker()
    /// 取色器现在开在哪一档上（开过没关都算）。收起面板那一行、换工具、结束会话都要关它。
    private(set) var customPickerOpen = false

    var onChange: ((ScreenshotToolStyle) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: - 摆位

    /// 钉到 `cell`（遮罩坐标的一格）上方；上面顶到屏边就翻到下方，横向钳在屏内。
    /// 和 `ScreenshotTipView.show` 同一套规矩：先算高（调色板开着会多一行），再定 y。
    ///
    /// `limits` 是**注解条那一条**（遮罩坐标）：用户 2026-10-19 定的「粗细颜色的汽泡不要
    /// 超出主菜单的左右」—— 面板是条子长出来的一块，横向探出条子外就成了一张贴在屏幕上
    /// 的独立贴纸，尖指着一格、身子却飘到别处。条子窄到塞不下面板时退回屏内
    /// （见 `xSpan`），宁可探出条子也不能跑出屏。
    func place(over cell: NSRect, in container: NSRect, within limits: NSRect? = nil) {
        anchorCell = cell
        anchorContainer = container
        anchorLimits = limits
        let size = Self.size(tool: tool, paletteOpen: paletteTarget != nil)
        let margin = ScreenshotSelectionView.toolbarMargin
        let span = Self.xSpan(panelWidth: size.width, container: container, limits: limits)
        var x = cell.midX - size.width / 2
        x = min(max(x, span.lowerBound), max(span.upperBound - size.width, span.lowerBound))
        var y = cell.minY - Self.gapToBar - size.height
        pointerUp = false
        if y < container.minY + margin {
            y = cell.maxY + Self.gapToBar
            pointerUp = true
        }
        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        // 尖要跟着一格走：面板被钳过之后，尖落在格子中心相对面板的位置上。
        pointerX = min(max(cell.midX - x, Self.cornerRadius + 6),
                       max(size.width - Self.cornerRadius - 6, Self.cornerRadius + 6))
        placeCells()
        needsDisplay = true
    }

    /// 横向允许的区间：先是「屏减去留白」，给了 `limits`（条子）再往里收到条子的左右沿。
    ///
    /// 纯函数，单测直接喂 rect —— 这条判据不能拿面板自己的 `frame` 反推，不然等于让被测
    /// 对象给自己作证：钳错方向时它自己也说「我就该待在这儿」。
    /// 收完之后放不下（`limits` 比面板还窄，比如以后条子加了自动缩）就整条退回屏内：
    /// 探出条子是难看，跑出屏是点不到。
    static func xSpan(panelWidth: CGFloat, container: NSRect, limits: NSRect?) -> ClosedRange<CGFloat> {
        let margin = ScreenshotSelectionView.toolbarMargin
        let screen = (container.minX + margin)...(container.maxX - margin)
        guard let limits else { return screen }
        let lower = max(screen.lowerBound, limits.minX)
        let upper = min(screen.upperBound, limits.maxX)
        guard upper - lower >= panelWidth, upper > lower else { return screen }
        return lower...upper
    }

    /// 面板该有多大。**含**指示尖那 6pt（见 `bodyRect`）。文字那一格多一行样式，
    /// 调色板开着再多一行。
    static func size(tool: ScreenshotTool?, paletteOpen: Bool) -> NSSize {
        var rows = 1
        if tool == .text { rows += 1 }
        if paletteOpen { rows += 1 }
        let height = padding * 2 + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
        return NSSize(width: width, height: height + pointerHeight)
    }

    /// 那块圆角矩形本体，不含尖。
    ///
    /// 尖必须算进 `bounds`：`cacheDisplay(in:to:)` 只重放落在 bounds 里的绘制，视图自己
    /// 画到外面的那 6pt 在离屏渲染里直接不见（真机上这层挂在 borderless 窗里，一旦哪天
    /// 转成 layer-backed，屏幕上也会一样被裁掉）。所以 frame 含尖，本体按尖朝哪头缩一头。
    /// 那块圆角矩形本体，不含尖。internal 是给取证的：量留白得按本体量，按 `bounds` 量
    /// 会把尖那 6pt 里「什么都没画」的那两条也算进去。
    var bodyRect: NSRect {
        NSRect(x: 0, y: pointerUp ? Self.pointerHeight : 0,
               width: bounds.width, height: max(0, bounds.height - Self.pointerHeight))
    }

    // MARK: - 内容

    /// 把面板设成「这一格工具、这一套值」并重排。遮罩在选中工具、改值、拖完条子之后调它。
    /// `container` 是遮罩 bounds，`limits` 是注解条的 frame（横向不许超出它，见 `place`）。
    func show(tool: ScreenshotTool, style: ScreenshotToolStyle, cell: NSRect, in container: NSRect,
              within limits: NSRect? = nil) {
        // 换工具 = 换一套值，调色板留着只会让人以为挑的是上一格的颜色。先比再赋值，
        // 反过来写就成了「自己跟自己比」，永远关不掉。取色器同理：给它接着挑色，
        // 挑的却是上一格那支笔的颜色，落点就跑错了。
        if self.tool != tool {
            closeColorPicker()
            paletteTarget = nil
        }
        self.tool = tool
        self.style = style
        place(over: cell, in: container, within: limits)
    }

    func hidePalette() {
        closeColorPicker()
        guard paletteTarget != nil else { return }
        paletteTarget = nil
        // 收那一行得连着把 frame 缩回去：只 `placeCells()` 的话，多出来的那一行高度留在
        // 底沿（尖那头），空出一条谁也点不着的带子 —— 挑完一个预设色正好就是这一态。
        if let cell = anchorCell {
            place(over: cell, in: anchorContainer ?? superview?.bounds ?? bounds,
                  within: anchorLimits)
        } else {
            placeCells()
            needsDisplay = true
        }
    }

    /// 收掉系统取色面板。三个入口都得走这一条：Esc 收属性面板、挑完预设收起那一行、
    /// 整次截图结束 —— 漏一个就是一块飘在桌面上没人认领的取色窗。
    func closeColorPicker() {
        guard customPickerOpen else { return }
        customPickerOpen = false
        colorPicker.dismiss()
    }

    /// 调色板那一行从左到右该有哪些格：「无」（只有边框/背景给）+ 七档预设 + 彩色自定义。
    /// internal 是给取证的：平铺摆位会把格子位置算成小数，测试按 id 数格子才数得清。
    func paletteCellIDs() -> [String] {
        var ids: [String] = []
        if paletteAllowsNone { ids.append("none") }
        ids += ScreenshotToolbarView.palette.indices.map { "palette.\($0)" }
        ids.append("custom")
        return ids
    }

    /// 某一档现在是什么颜色。主色不给 nil（一条没颜色的注解等于没画），边框/背景不给。
    private func selectedColor(for target: ColorTarget) -> NSColor? {
        switch target {
        case .main: return style.color
        case .border: return style.borderColor
        case .background: return style.backgroundColor
        }
    }

    /// 当前落点上的颜色不在任何预设档里 = 它是自定义来的，那枚彩色格就该带选中圈。
    /// 不然用户挑完自定义色，调色板上七档一个都没亮，看着像没生效。
    var customColorSelected: Bool {
        guard let color = selectedColor(for: paletteTarget ?? .main) else { return false }
        return !ScreenshotToolbarView.palette.contains { $0.isEqual(color) }
    }

    /// 面板上每格是干什么的，从左到右、从上到下。取证用它核对「该出现的格一个没漏」
    /// ——文字那格少了 B/I/边框/背景，在代码里只是少画四块，肉眼对着枚举看不出来。
    var elementsOnPanel: [String] { cells.map(\.id) }

    /// 可点格子的矩形（遮罩坐标）。
    var actionableRects: [NSRect] { cells.map { $0.rect.offsetBy(dx: frame.minX, dy: frame.minY) } }

    /// 按 id 找某一格的矩形（遮罩坐标）。面板上的格子会随工具和调色板开合换位置，
    /// 取证要的是「颜色那一格在哪儿」，不是「第 4 格在哪儿」。
    func actionableRect(forCell id: String) -> NSRect? {
        cells.first { $0.id == id }.map { $0.rect.offsetBy(dx: frame.minX, dy: frame.minY) }
    }

    /// 悬停提示：和条子那套一样，由遮罩画气泡，这里只回答「停在哪格、提示什么」。
    func tip(atOverlayPoint point: NSPoint) -> (text: String, cell: NSRect)? {
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard let hit = cells.first(where: { $0.rect.contains(local) }), !hit.tip.isEmpty else { return nil }
        return (hit.tip, hit.rect.offsetBy(dx: frame.minX, dy: frame.minY))
    }

    /// 滑杆当前值（粗细或字号，看这一格是什么工具）。
    private var sliderValue: CGFloat {
        tool == .text ? style.fontSize : style.lineWidth
    }

    private var sliderRange: ClosedRange<CGFloat> {
        tool == .text ? ScreenshotToolStyle.fontRange : ScreenshotToolStyle.widthRange
    }

    /// 调色板在给谁挑色时，行首那枚「无」能不能点：主色不能没有，边框和背景可以。
    private var paletteAllowsNone: Bool { paletteTarget != .main }

    // MARK: - 装配

    private func placeCells() {
        var laid: [(id: String, rect: NSRect, tip: String)] = []
        let pad = Self.padding
        let body = bounds.width - pad * 2
        // 行从本体上沿起排，不从视图上沿：尖翻到上面时那 6pt 也是视图的一部分（见 `bodyRect`）。
        var rowY = bodyRect.minY + pad
        // 调色板开着时那一行排在最上面（面板往上长，下沿和尖不动）。
        if paletteTarget != nil {
            // **平铺**：首尾贴内边距，中间等分。左对齐一格 4pt 排过去，右边会留一大截空，
            // 看着像这行少画了几格（用户 2026-10-19 点名的就是那个留白）。格子多到挤不下
            // 时先缩格子，不许把间距算成负数 —— 主色一行 8 格、边框/背景一行 9 格，
            // 9 格在 216pt 里每格还剩 22.2，所以正常宽度下 `side` 就是 `rowHeight`。
            let ids = paletteCellIDs()
            let smallestGap: CGFloat = 2
            let fitted = ((body - smallestGap * CGFloat(ids.count - 1)) / CGFloat(ids.count))
                .rounded(.down)
            let side = min(Self.rowHeight, max(8, fitted))
            let gap = (body - CGFloat(ids.count) * side) / CGFloat(max(1, ids.count - 1))
            var x = pad
            for id in ids {
                let tip = id == "none" ? L("Screenshot No Color")
                    : (id == "custom" ? L("Screenshot Custom Color") : L("Screenshot Color"))
                laid.append((id, NSRect(x: x, y: rowY, width: side, height: side), tip))
                x += side + gap
            }
            rowY += Self.rowHeight + Self.rowGap
        }
        // 第一行：标签 + 滑杆 + 数值 + 色块 + ⌄。
        //
        // 数值/色块/⌄ 这一组**钉在右沿**，滑杆吃剩下的宽度。反过来先排滑杆再往右推，
        // 标签一长（英文串，或者本地化没命中直接显示 key）就会把色块和 ⌄ 顶出面板 ——
        // 顶出去的那两格看不见也点不着，等于面板丢了改颜色的入口。离屏取证量出来的。
        let isText = tool == .text
        let label = isText ? L("Screenshot Font Size") : L("Screenshot Thickness")
        let labelWidth = ceil((label as NSString).size(withAttributes: Self.labelAttributes).width)
        laid.append(("label", NSRect(x: pad, y: rowY, width: labelWidth, height: Self.rowHeight), ""))
        let swatchWidth: CGFloat = 22
        let chevronWidth: CGFloat = 14
        let valueWidth: CGFloat = 26
        let rightEdge = pad + body
        let moreX = rightEdge - chevronWidth
        let colorX = moreX - swatchWidth
        let valueX = colorX - 6 - valueWidth
        let trackRight = valueX - 6
        let trackLeft = pad + labelWidth + 8
        let trackWidth = max(Self.minTrackWidth, trackRight - trackLeft)
        laid.append(("slider", NSRect(x: min(trackLeft, trackRight - Self.minTrackWidth),
                                      y: rowY, width: trackWidth, height: Self.rowHeight),
                     isText ? L("Screenshot Font Size") : L("Screenshot Line Width")))
        laid.append(("value", NSRect(x: valueX, y: rowY, width: valueWidth, height: Self.rowHeight), ""))
        laid.append(("color", NSRect(x: colorX, y: rowY + 2, width: swatchWidth, height: Self.rowHeight - 4),
                     L("Screenshot Color")))
        laid.append(("more", NSRect(x: moreX, y: rowY, width: chevronWidth, height: Self.rowHeight),
                     L("Screenshot More Colors")))
        rowY += Self.rowHeight + Self.rowGap

        if isText {
            let chip: CGFloat = 22
            var cx = pad + ceil((L("Screenshot Style") as NSString)
                .size(withAttributes: Self.labelAttributes).width) + 8
            laid.append(("label.style", NSRect(x: pad, y: rowY, width: cx - pad - 8,
                                               height: Self.rowHeight), ""))
            laid.append(("bold", NSRect(x: cx, y: rowY, width: chip, height: Self.rowHeight),
                         L("Screenshot Bold")))
            cx += chip + 4
            laid.append(("italic", NSRect(x: cx, y: rowY, width: chip, height: Self.rowHeight),
                         L("Screenshot Italic")))
            cx += chip + 10
            laid.append(("border", NSRect(x: cx, y: rowY + 2, width: chip, height: Self.rowHeight - 4),
                         L("Screenshot Text Border")))
            cx += chip + 6
            laid.append(("background", NSRect(x: cx, y: rowY + 2, width: chip, height: Self.rowHeight - 4),
                         L("Screenshot Text Background")))
        }
        cells = laid
    }

    // MARK: - 绘制

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
    ]

    override func draw(_ dirtyRect: NSRect) {
        let style = ToolbarStyle.resolved(for: effectiveAppearance)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: Self.cornerRadius,
                                yRadius: Self.cornerRadius)
        style.barFill.setFill()
        body.fill()
        style.barBorder.setStroke()
        body.lineWidth = 1
        body.stroke()
        drawPointer(style: style)

        let ink = style.glyph
        for cell in cells {
            switch cell.id {
            case let id where id.hasPrefix("label"):
                let text = id == "label.style" ? L("Screenshot Style")
                    : (tool == .text ? L("Screenshot Font Size") : L("Screenshot Thickness"))
                draw(text, in: cell.rect, color: ink, font: .systemFont(ofSize: 12))
            case "slider":
                drawSlider(cell.rect, style: style, ink: ink)
            case "value":
                draw("\(Int(sliderValue))", in: cell.rect, color: ink,
                     font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), alignRight: true)
            case "color":
                drawColorChip(cell.rect, color: self.style.color, ring: ink, style: style)
            case "more":
                drawChevron(cell.rect, color: ink, open: paletteTarget != nil)
            case "bold", "italic":
                let on = cell.id == "bold" ? self.style.bold : self.style.italic
                if on {
                    style.chipIdle.setFill()
                    NSBezierPath(roundedRect: cell.rect, xRadius: 5, yRadius: 5).fill()
                }
                let font = cell.id == "bold"
                    ? NSFont.boldSystemFont(ofSize: 13)
                    : NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13),
                                                   toHaveTrait: .italicFontMask)
                draw(cell.id == "bold" ? "B" : "I", in: cell.rect, color: ink, font: font)
            case "border":
                drawBorderChip(cell.rect, color: self.style.borderColor, style: style, ink: ink)
            case "background":
                drawColorChip(cell.rect, color: self.style.backgroundColor, ring: ink, style: style)
            case "none":
                drawNoneChip(cell.rect, style: style, ink: ink)
            case let id where id.hasPrefix("palette."):
                let index = Int(id.dropFirst("palette.".count)) ?? 0
                drawColorChip(cell.rect, color: ScreenshotToolbarView.palette[index],
                              ring: ink, style: style, selected: isSamePaletteEntry(index))
            case "custom":
                drawCustomChip(cell.rect, style: style, ink: ink,
                               selected: customColorSelected)
            default:
                break
            }
        }
    }

    /// 指向那一格的小三角：和面板同底同描边，画成一整块才看不出接缝。
    /// 尖画在 `bodyRect` 之外、`bounds` 之内那 6pt 上 —— 画到 bounds 外面就会被
    /// `cacheDisplay` 裁掉（见 `bodyRect`）。
    private func drawPointer(style: ToolbarStyle) {
        let half: CGFloat = 5
        let tip = Self.pointerHeight
        let body = bodyRect
        let base = pointerUp ? body.minY : body.maxY
        let path = NSBezierPath()
        path.move(to: CGPoint(x: pointerX - half, y: base))
        path.line(to: CGPoint(x: pointerX + half, y: base))
        path.line(to: CGPoint(x: pointerX, y: pointerUp ? base - tip : base + tip))
        path.close()
        style.barFill.setFill()
        path.fill()
        style.barBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        // 压住三角形和圆角矩形之间那两条描边。
        (pointerUp ? NSBezierPath(rect: CGRect(x: pointerX - half + 0.5, y: body.minY,
                                               width: half * 2 - 1, height: 1.5))
                   : NSBezierPath(rect: CGRect(x: pointerX - half + 0.5, y: body.maxY - 1.5,
                                               width: half * 2 - 1, height: 1.5))).fill()
    }

    private func drawSlider(_ rect: NSRect, style: ToolbarStyle, ink: NSColor) {
        let range = sliderRange
        let fraction = (sliderValue - range.lowerBound) / (range.upperBound - range.lowerBound)
        let y = rect.midY
        let track = NSBezierPath(roundedRect: CGRect(x: rect.minX, y: y - 1.5,
                                                     width: rect.width, height: 3),
                                 xRadius: 1.5, yRadius: 1.5)
        style.chipIdle.setFill()
        track.fill()
        let filled = NSBezierPath(roundedRect: CGRect(x: rect.minX, y: y - 1.5,
                                                      width: max(3, rect.width * fraction), height: 3),
                                  xRadius: 1.5, yRadius: 1.5)
        ToolbarStyle.accent.setFill()
        filled.fill()
        let knob = CGRect(x: rect.minX + rect.width * fraction - 6, y: y - 6, width: 12, height: 12)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        ink.setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }

    private func drawChevron(_ rect: NSRect, color: NSColor, open: Bool) {
        color.setStroke()
        let path = NSBezierPath()
        let w: CGFloat = 5
        let y = rect.midY
        if open {
            path.move(to: CGPoint(x: rect.midX - w, y: y + w / 2))
            path.line(to: CGPoint(x: rect.midX, y: y - w / 2))
            path.line(to: CGPoint(x: rect.midX + w, y: y + w / 2))
        } else {
            path.move(to: CGPoint(x: rect.midX - w, y: y - w / 2))
            path.line(to: CGPoint(x: rect.midX, y: y + w / 2))
            path.line(to: CGPoint(x: rect.midX + w, y: y - w / 2))
        }
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// 一枚色块。nil 表示「这一项没开」——画成中灰底加一道斜线，比留白好认。
    private func drawColorChip(_ rect: NSRect, color: NSColor?, ring: NSColor,
                               style: ToolbarStyle, selected: Bool = false) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        if let color {
            color.setFill()
            path.fill()
        } else {
            style.chipIdle.setFill()
            path.fill()
            drawNoneMark(rect, color: ring)
        }
        (selected ? ToolbarStyle.accent : ring).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 4, yRadius: 4)
        outline.lineWidth = selected ? 2 : 1
        outline.stroke()
    }

    /// 边框那一格：只描一圈，中间留空 —— 和背景那枚实心块区分开，用户才知道哪个是描边。
    private func drawBorderChip(_ rect: NSRect, color: NSColor?, style: ToolbarStyle, ink: NSColor) {
        style.chipIdle.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        if let color {
            color.setStroke()
        } else {
            ink.setStroke()
            drawNoneMark(rect, color: ink)
        }
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5),
                                   xRadius: 2, yRadius: 2)
        outline.lineWidth = 2
        outline.stroke()
    }

    /// 自定义那一格：一整条色相带（红→黄→绿→蓝→紫），不是加号也不是彩点。它挨在七档
    /// 预设后面，作用就是「这里不吃这七档，任意色都能挑」—— 一块实心彩虹在七个纯色块里
    /// 最跳，用户不用读提示也知道它跟旁边那些不一样。
    private func drawCustomChip(_ rect: NSRect, style: ToolbarStyle, ink: NSColor, selected: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let hues = [NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                    NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.84, blue: 0.24, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.5, blue: 1, alpha: 1),
                    NSColor(srgbRed: 0.68, green: 0.2, blue: 1, alpha: 1)]
        if let gradient = NSGradient(colors: hues) {
            gradient.draw(in: rect, angle: 0)
        } else {
            // 取不到渐变也不能留一块空洞：退成中灰底，至少看得出那有一格能点。
            style.chipIdle.setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        (selected ? ToolbarStyle.accent : ink).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 4, yRadius: 4)
        outline.lineWidth = selected ? 2 : 1
        outline.stroke()
    }

    private func drawNoneChip(_ rect: NSRect, style: ToolbarStyle, ink: NSColor) {
        style.barFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        drawNoneMark(rect, color: ink)
        ink.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 4, yRadius: 4)
        outline.lineWidth = 1
        outline.stroke()
    }

    private func drawNoneMark(_ rect: NSRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + 3, y: rect.maxY - 3))
        path.line(to: CGPoint(x: rect.maxX - 3, y: rect.minY + 3))
        path.lineWidth = 1.4
        path.stroke()
    }

    private func isSamePaletteEntry(_ index: Int) -> Bool {
        guard let target = paletteTarget else { return false }
        let current: NSColor?
        switch target {
        case .main: current = style.color
        case .border: current = style.borderColor
        case .background: current = style.backgroundColor
        }
        guard let current else { return false }
        return current.isEqual(ScreenshotToolbarView.palette[index])
    }

    private func draw(_ text: String, in rect: NSRect, color: NSColor, font: NSFont,
                      alignRight: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let x = alignRight ? rect.maxX - size.width : rect.midX - size.width / 2
        (text as NSString).draw(at: CGPoint(x: x, y: rect.midY - size.height / 2),
                                withAttributes: attributes)
    }

    // MARK: - 交互

    /// 面板整块吃掉落在它里面的点击：留着缝让事件穿过去，就是在面板底下画了一条注解。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let id = cellID(at: local) else { return }
        press(cell: id, trackX: local.x)
    }

    /// 按格子的 id 走一次分发。拆出来是给取证用的：面板上有哪些格、格在哪儿，都跟着工具和
    /// 调色板开合变；测试拿坐标点它等于把布局也钉死，指 id 点才验的是「这一格该办的事」。
    /// `trackX` 只有滑杆那一格吃 —— 不给就按格子里，等于滑到中间。
    func press(cell id: String, trackX: CGFloat? = nil) {
        let x = trackX ?? cells.first { $0.id == id }?.rect.midX ?? bounds.minX
        switch id {
        case "slider":
            drag = .slider
            setValue(fromTrackX: x)
        case "color":
            toggle(.main)
        case "more":
            toggle(paletteTarget ?? .main)
        case "border":
            toggle(.border)
        case "background":
            toggle(.background)
        case "none":
            applyNone()
        case "custom":
            openCustomPicker()
        case let other where other.hasPrefix("palette."):
            if let index = Int(other.dropFirst("palette.".count)) {
                applyPalette(ScreenshotToolbarView.palette[index])
            }
        case "bold":
            style.bold.toggle()
            commit()
        case "italic":
            style.italic.toggle()
            commit()
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag == .slider else { return }
        setValue(fromTrackX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
    }

    private func cellID(at point: CGPoint) -> String? {
        cells.first { $0.rect.contains(point) }?.id
    }

    private func setValue(fromTrackX x: CGFloat) {
        guard let track = cells.first(where: { $0.id == "slider" })?.rect else { return }
        let range = sliderRange
        let fraction = min(max((x - track.minX) / max(1, track.width), 0), 1)
        let span = range.upperBound - range.lowerBound
        // 取整：滑杆要的是「一眼读得出的那个数」，13.7 号字既显示不下也没人调得准。
        let value = min(max((range.lowerBound + fraction * span).rounded(),
                            range.lowerBound), range.upperBound)
        if tool == .text { style.fontSize = value } else { style.lineWidth = value }
        commit()
    }

    private func toggle(_ target: ColorTarget) {
        paletteTarget = paletteTarget == target ? nil : target
        placeCells()
        // 多一行/少一行都改变面板高度：下沿（和尖）得钉在原处，所以往上长。
        // 摆位继续沿用上次记下的容器和条子范围 —— 换高度不是重新放开左右限制的机会。
        if let cell = anchorCell {
            place(over: cell, in: anchorContainer ?? superview?.bounds ?? bounds,
                  within: anchorLimits)
        } else {
            needsDisplay = true
        }
    }

    private func applyPalette(_ color: NSColor) {
        switch paletteTarget ?? .main {
        case .main: style.color = color
        case .border: style.borderColor = color
        case .background: style.backgroundColor = color
        }
        // 走 `hidePalette()` 而不是只清 `paletteTarget`：预设档是「挑完就收」，取色器
        // 要是还开着，用户关掉它时颜色又会盖掉刚挑的这一档。
        hidePalette()
        commit()
    }

    /// 彩色那一格：把取色器开在**当前落点**那一档上。落点就是调色板现在在给谁挑色 ——
    /// 从「边框」那格展开后进的取色器，改的必须只有边框；那一行收着时才按主色算。
    ///
    /// 开之前先把 `paletteTarget` 定下来：替身/系统面板回吐的颜色要落回这一档，
    /// 而回吐是异步的，那会儿行可能已经被别的路径清了。
    private func openCustomPicker() {
        let target = paletteTarget ?? .main
        paletteTarget = target
        colorPicker.show(initial: selectedColor(for: target) ?? style.color) { [weak self] picked in
            self?.applyCustom(picked, to: target)
        }
        customPickerOpen = true
        needsDisplay = true
    }

    /// 取色器回吐一次颜色。**不收那一行**：用户开着取色器就是来连着试色的，
    /// 行一收，落点就没了，下一次回吐会盖错地方。
    private func applyCustom(_ color: NSColor, to target: ColorTarget) {
        switch target {
        case .main: style.color = color
        case .border: style.borderColor = color
        case .background: style.backgroundColor = color
        }
        commit()
    }

    private func applyNone() {
        switch paletteTarget ?? .main {
        case .main: return
        case .border: style.borderColor = nil
        case .background: style.backgroundColor = nil
        }
        hidePalette()
        commit()
    }

    private func commit() {
        placeCells()
        needsDisplay = true
        onChange?(style)
    }
}
