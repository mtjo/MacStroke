//
//  ScreenshotAnnotation.swift
//  MacStroke
//
//  截图之后的注解层：矩形、椭圆、箭头、画笔、文字、马赛克、序号。
//
//  一条贯穿全局的约定 —— **所有注解坐标都是遮罩视图的点坐标**（整屏 flipped 视图，
//  原点在本屏左上角）。绘制、命中、合成三条路径都吃同一套坐标，所以导出时只需要
//  「平移进选区 + 按 scale 放大」一次，不会各算各的。
//
//  马赛克不是画笔轨迹而是一块矩形像素化：真按笔刷涂抹要把轨迹栅格化成 mask，
//  代价和收益完全不成比例（QQ 自己也提供矩形打码）。画笔只做「沿点列描一条」，
//  它不进 mask，所以两者的数据结构分得开：椭圆跟矩形共用两个对角点，只有画笔
//  额外背着一串轨迹点。
//
//  导出用「离屏渲染一个 flipped 视图」而不是直接往 CGBitmapContext 里画：后者要
//  自己管 CTM 翻转和文字方向（本机探针实测：identity 下 draw 正立、加翻转反而倒，
//  而 NSString 又跟着 NSGraphicsContext 的 flipped 状态走），而视图这条路的方向
//  已经被 ScreenshotOverlayRenderTests 验过一遍，注解和底图共用它才不会错位。
//

import AppKit
import CoreGraphics
import CoreText
import Storage

/// 用户在工具条上选的字。
public enum ScreenshotTool: Int, CaseIterable {
    case rect, ellipse, arrow, pen, text, mosaic, number

    /// 这一格的中文名：注解条上的悬停提示和偏好页的下拉共用这一份，免得两处各写一遍
    /// 文案、改一处漏一处。
    public var title: String {
        switch self {
        case .rect: return L("Screenshot Rect")
        case .ellipse: return L("Screenshot Ellipse")
        case .arrow: return L("Screenshot Arrow")
        case .pen: return L("Screenshot Pen")
        case .text: return L("Screenshot Text")
        case .mosaic: return L("Screenshot Mosaic")
        case .number: return L("Screenshot Number")
        }
    }

    /// 库里存的工具序号。-1 是偏好页上的「关闭」，认不出的值也当关闭处理。
    public init?(stored: Int) {
        self.init(rawValue: stored)
    }
}

/// 一条画好的注解。不可变：要改就返回新的一条，调用方换掉数组里那个元素 ——
/// 拖动过程中没有中间态被改在半路上，撤销/重做才敢整表存快照。
///
/// 「画完之后还要改」那一套（平移/缩放/改样式）也不破坏这条 —— 每个编辑操作都**返回
/// 新的一条**，调用方换掉数组里那一个元素。所以 `Equatable` 是编辑之后才需要的：
/// 拖动一帧没真的挪动，就别占一步撤销（合成的 `==` 走 `NSObject.isEqual`，颜色比的是值
/// 不是指针，正是这里要的口径）。
public struct ScreenshotAnnotation: Equatable {
    public let tool: ScreenshotTool
    public let color: NSColor
    /// 点为单位；合成时随视图缩放自动变成像素宽度。
    public let lineWidth: CGFloat
    /// 矩形/椭圆/马赛克 = 拖选的两个对角；箭头 = 起点；文字/序号 = 锚点；画笔 = 轨迹第一点。
    public let start: CGPoint
    /// 画笔 = 轨迹最后一点。
    public let end: CGPoint
    /// 画笔的整条轨迹（含首尾）；其余工具为空，几何一律看 `start`/`end`。
    public let points: [CGPoint]
    public let text: String
    public let number: Int

    /// 字号。**只有文字用得到**：序号的数字大小仍跟着粗细走（见 `badgeRadius`）。
    /// 不传就退回 `max(13, lineWidth*4)` —— 那是「粗细当字号」这条老路，旧数据、
    /// 以及面板上没滑过字号的场合都还走它。
    public let fontSize: CGFloat
    /// 文字的两个样式位。`bold` 默认 true = 这次改动之前的样子（那时文字恒用 `boldSystemFont`）。
    public let bold: Bool
    public let italic: Bool
    /// 文字描一圈：nil = 不描。背景同理：nil = 不铺底。
    public let borderColor: NSColor?
    public let backgroundColor: NSColor?

    public init(tool: ScreenshotTool, color: NSColor, lineWidth: CGFloat, start: CGPoint,
                end: CGPoint? = nil, points: [CGPoint] = [], text: String = "", number: Int = 0,
                fontSize: CGFloat? = nil, bold: Bool = true, italic: Bool = false,
                borderColor: NSColor? = nil, backgroundColor: NSColor? = nil) {
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.start = points.first ?? start
        self.end = points.last ?? end ?? start
        self.points = points
        self.text = text
        self.number = number
        self.fontSize = fontSize ?? Self.derivedFontSize(lineWidth: lineWidth)
        self.bold = bold
        self.italic = italic
        self.borderColor = borderColor
        self.backgroundColor = backgroundColor
    }

    /// 拖出来的框。拖拽方向不限，先归一化成左上原点矩形；画笔取整条轨迹的包围盒。
    public var rect: CGRect {
        Self.boundingBox(of: points.isEmpty ? [start, end] : points)
    }

    /// 没显式给字号时的老式子：粗细即字号。
    static func derivedFontSize(lineWidth: CGFloat) -> CGFloat { max(13, lineWidth * 4) }
    /// 序号徽标的半径仍由粗细决定 —— 那一格没有字号可滑，只有「圈多大」。
    public var badgeRadius: CGFloat { max(11, lineWidth * 2.5) }

    // MARK: - 文字这一块

    /// 字和底/框之间留的缝：按字号比例给。24 号留 4pt、72 号留 13pt，读起来才是
    /// 「同一块东西放大了」，而不是底衬永远薄一层。
    public var textPadding: CGFloat { max(2, (fontSize * 0.18).rounded()) }
    /// 描边宽度也跟着字号走：字放大而边框不变粗，就成了贴着一圈的发丝线。
    public var textBorderWidth: CGFloat { max(1, (fontSize * 0.06).rounded()) }
    static let textCornerRadius: CGFloat = 4

    /// 组合后的字体。粗体走 `NSFontManager` 而不是 `boldSystemFont`，是为了让「粗 + 斜」
    /// 这一档有真正的粗斜体（`boldSystemFont` 再叠 italic 会退成普通斜体）。
    public var textFont: NSFont {
        Self.font(size: fontSize, bold: bold, italic: italic)
    }

    /// 字号 + 粗斜体 → 字体。单独拆出来是给就地输入框用的：打字时看到的那套字，
    /// 和落笔后烘进成品图的那套必须是同一条式子，否则回车一瞬间字就跳。
    ///
    /// 注意这条只管**有斜体脸的那一段**（拉丁、西里尔…）。中文不在这里解决 ——
    /// 见 `italicStyledText(_:font:color:flipped:)`，那一手才是 issue #73 的修复。
    public static func font(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var font = NSFont.systemFont(ofSize: size)
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    // MARK: - 中文的斜体要自己造（issue #73：beck023「英文可以设置斜体,但是中文设置了不生效」）

    /// 合成斜体（synthesized oblique）的剪切量，就是 tanθ。0.2 ≈ 11.3°，和 SF 真斜体
    /// 自己的倾角同一档 —— 中文补的这一点斜必须跟旁边英文真斜体看上去是一路的字，
    /// 再大就成了歪，再小就看不出勾了斜体。
    public static let italicShear: CGFloat = 0.2

    /// 这张脸到底有没有斜体：把它交给 `NSFontManager` 加一档 italic，名字变了才算真有其脸。
    /// `.SFNS-RegularItalic` → 还是它（有脸）；`PingFang SC` → 也还是它（**没脸**）。
    /// 本机取证：`NSFont(name: "PingFang SC Regular")` 加 italic 之后 `fontName` 一个字符都没变，
    /// 成品图上「中」按这条老路画出来斜差 0.00（同一把尺子量拉丁真斜体是 +4.86）——
    /// 系统里根本没有中文斜体字面，转换只能原样把正体还回来，这就是「勾了斜体没反应」的
    /// 全部真相，不是我们把开关接漏了。
    static func hasItalicFace(_ font: NSFont) -> Bool {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask).fontName != font.fontName
    }

    /// 给整张字补一圈剪切矩阵。
    ///
    /// 只加 x ← y 这一项：基线（y=0）上的推进量一个像素都不动，所以量宽、底框、命中、
    /// 选区钳制四条路径全跟着原样，变的只有观感 —— 这是选它而不选「画之前 concatenate 一个
    /// CTM」的原因，后者要把外框一起重算。
    ///
    /// 符号跟设备 y 轴走，而这个**只能量出来、不能推出来**：成品图侧同一条「中」实测
    /// （48pt，正体斜差 0.00 当原点）—— flipped 上下文里给负号剪切量出 **−4.61，是向左倒**，
    /// 换正号才和拉丁真斜体同一侧（同一把尺子量「A」＝ +4.86）。三条绘制路径（屏上遮罩、
    /// 预览、导出）都在 flipped 视图里，所以 flipped 那一档取**正**号。写反不是「看不出来」，
    /// 是画出一部向左倒的倒斜体 —— 所以这一条交给 `ScreenshotItalicTests` 的数字判据钉住。
    public static func oblique(_ font: NSFont, flipped: Bool) -> NSFont {
        var matrix = CGAffineTransform(a: 1, b: 0, c: flipped ? italicShear : -italicShear, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font, font.pointSize, &matrix, nil) as NSFont
    }

    /// 一行字按「每个字实际吃到哪张脸」分段排版：真斜体脸在的那段（拉丁）一个字都不动，
    /// 回退到没斜体脸的那段（中文、日文、emoji…）换成剪切版。
    ///
    /// 逐字问 CoreText 要它实际选中的脸，而不是按字符表猜「这段算不算中文」—— 以后系统
    /// 真给某个字加了斜体字面，`hasItalicFace` 会答 true，这一手自己就退场，不用回来删代码。
    /// 不勾斜体时原样返回单段正体，正体那条路径的字节数都不变。
    public static func italicStyledText(_ text: String, font: NSFont, color: NSColor,
                                        flipped: Bool) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let traits = NSFontManager.shared.traits(of: font)
        guard traits.contains(.italicFontMask), !text.isEmpty else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        let string = text as NSString
        let sheared = oblique(font, flipped: flipped)
        let result = NSMutableAttributedString()
        var index = 0
        while index < string.length {
            let resolved = face(for: string, at: index, in: font)
            var end = index + resolved.length
            // 连续同一张字的片段合成一段：一个字一个 run 会让一行三十个汉字变成三十段。
            while end < string.length {
                let next = face(for: string, at: end, in: font)
                if next.name != resolved.name { break }
                end += next.length
            }
            // 同一张脸内部再分「有没有斜体脸」：正体脸才补剪切，真斜体脸保持原样。
            let needsShear = resolved.name != font.fontName && !hasItalicFace(resolved.font)
            result.append(NSAttributedString(
                string: string.substring(with: NSRange(location: index, length: end - index)),
                attributes: [.font: needsShear ? sheared : font, .foregroundColor: color]))
            index = end
        }
        return result
    }

    /// 某个位置上实际吃到的那张脸。代理对（emoji、部分生僻字）整对一起算，
    /// 不然把一个字符劈成两半，CoreText 会给回一张替代字体的脸，分段就裂了。
    private static func face(for string: NSString, at index: Int, in font: NSFont)
        -> (font: NSFont, name: String, length: Int) {
        let unit = string.character(at: index)
        let length = (0xD800...0xDBFF).contains(unit) && index + 1 < string.length ? 2 : 1
        let resolved = CTFontCreateForString(font, string, CFRange(location: index, length: length)) as NSFont
        return (resolved, resolved.fontName, length)
    }

    /// 字本身量出来的大小（不含内边距）。量的是**组合后的字体**，所以勾上粗体/斜体之后
    /// 宽度会跟着变 —— 底和框要罩住的正是这一份，按普通字宽算会短一截。
    public var textSize: CGSize {
        NSAttributedString(string: text, attributes: [.font: textFont]).size()
    }

    /// 落点框：以 `start` 为字的首行左上角，向外扩一圈给底和框。绘制、命中、
    /// 「这条在不在选区里」三条路径都读它，所以以后挪一条文字只需要动 `start`。
    public var textBoxRect: CGRect {
        let size = textSize
        return CGRect(x: start.x - textPadding, y: start.y - textPadding,
                      width: size.width + textPadding * 2, height: size.height + textPadding * 2)
    }

    /// 实际会占到的范围，用来判断「这条要不要画、有没有落在选区里」。
    /// `rect` 对文字和序号不够用：它们的 start 只是一个锚点。
    public var dirtyRect: CGRect {
        switch tool {
        case .text:
            return textBoxRect
        case .number:
            return Self.badgeBox(start: start, radius: badgeRadius)
        case .pen:
            // 描边以路径为中心，包围盒不放心半根线宽就会贴着选区边缘磨掉一圈。
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        default:
            return rect
        }
    }

    // MARK: - 画笔轨迹

    /// 轨迹点之间的最小间距：一次拖动能报上几百个点，全收进点列会把一条随手线变成
    /// 上千个线段，绘制、撤销、导出三条路径都跟着变慢，而肉眼看不出区别。
    public static let penMinDistance: CGFloat = 2

    /// 方形标记的圆角：直角框压在截图上太硬。刻意只给 4pt —— 再大就成了「圆角矩形」
    /// 这个形状本身，用户想框的是那块内容。
    static let rectCornerRadius: CGFloat = 4

    /// 轨迹又拖到一个点：离上一点不到 `penMinDistance` 的丢弃。抽稀只在这一处做，
    /// 于是进到点列里的点永远干净，绘制侧不用再判。
    public static func penPath(byAppending point: CGPoint, to points: [CGPoint]) -> [CGPoint] {
        guard let last = points.last else { return [point] }
        return hypot(point.x - last.x, point.y - last.y) < penMinDistance ? points : points + [point]
    }

    /// 拖动中的画笔换一条：结构体不可变，点列只能整条换掉。
    /// 样式那几个字段得原样带过去 —— 漏一个，画到一半字号就跳回默认。
    public func extendingPen(to point: CGPoint) -> ScreenshotAnnotation {
        ScreenshotAnnotation(tool: tool, color: color, lineWidth: lineWidth, start: start,
                             points: Self.penPath(byAppending: point, to: points),
                             fontSize: fontSize, bold: bold, italic: italic,
                             borderColor: borderColor, backgroundColor: backgroundColor)
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var edges = (minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for point in points.dropFirst() {
            edges.minX = min(edges.minX, point.x)
            edges.minY = min(edges.minY, point.y)
            edges.maxX = max(edges.maxX, point.x)
            edges.maxY = max(edges.maxY, point.y)
        }
        return CGRect(x: edges.minX, y: edges.minY,
                      width: edges.maxX - edges.minX, height: edges.maxY - edges.minY)
    }

    /// 在**当前**图形上下文（假定是 flipped 视图的上下文）里画自己。
    public func draw(shot: ScreenshotFrame) {
        switch tool {
        case .rect:
            strokeOutline(Self.roundedOutline)
        case .ellipse:
            strokeOutline { NSBezierPath(ovalIn: $0) }
        case .arrow:
            drawArrow()
        case .pen:
            drawPen()
        case .text:
            drawText()
        case .mosaic:
            drawMosaic(shot: shot)
        case .number:
            drawBadge()
        }
    }

    // MARK: - 各工具画法

    /// 框类工具共用的一条路径：内缩半个线宽 —— 描边以路径为中心，不缩就会有一半糊到选区外。
    private func strokeOutline(_ path: (CGRect) -> NSBezierPath) {
        color.setStroke()
        let outline = path(rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        outline.lineWidth = lineWidth
        outline.stroke()
    }

    /// 圆角不能超过短边的一半：拖出一条只有几点开外的框时，超半径的圆角路径会自己
    /// 咬穿对边，画出来是一坨而不是一个扁框。
    private static func roundedOutline(_ rect: CGRect) -> NSBezierPath {
        let radius = max(0, min(rectCornerRadius, min(rect.width, rect.height) / 2))
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    /// 沿点列描一条。圆头 + 圆角转折：默认 Butt 端点在拐角处会豁出缺口，
    /// 手写的圈看着像被咬过。
    private func drawPen() {
        guard points.count > 1 else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawArrow() {
        color.setStroke()
        color.setFill()
        let head = max(9, lineWidth * 4)
        let angle = atan2(end.y - start.y, end.x - start.x)
        // 杆只画到头部起点：粗线的圆头会把三角头糊成一坨。
        let shaft = CGPoint(x: end.x - cos(angle) * head * 0.8,
                            y: end.y - sin(angle) * head * 0.8)
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: shaft)
        line.lineWidth = lineWidth
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.stroke()

        let triangle = NSBezierPath()
        triangle.move(to: end)
        triangle.line(to: barb(angle + .pi - 0.45, head))
        triangle.line(to: barb(angle + .pi + 0.45, head))
        triangle.close()
        triangle.fill()
    }

    private func barb(_ angle: CGFloat, _ length: CGFloat) -> CGPoint {
        CGPoint(x: end.x + cos(angle) * length, y: end.y + sin(angle) * length)
    }

    /// 文字分三层：底 → 框 → 字。底和框都罩在 `textBoxRect` 上（按量出来的字宽向外扩一圈），
    /// 字本身仍然画在 `start` —— 输入框落在哪儿字就在哪儿，勾上「背景」不该让字跳位。
    private func drawText() {
        let box = textBoxRect
        if let background = backgroundColor {
            background.setFill()
            Self.textOutline(box).fill()
        }
        if let border = borderColor {
            border.setStroke()
            let inset = textBorderWidth / 2
            let outline = Self.textOutline(box.insetBy(dx: inset, dy: inset))
            outline.lineWidth = textBorderWidth
            outline.stroke()
        }
        // 斜体要分段画：拉丁吃真斜体脸、中文那一段补合成剪切（issue #73）。正体仍走单段，
        // 少一次分段也就少一遍逐字解析。flipped 从**当前上下文**读，三条绘制路径都是 flipped
        // 视图，兜底给 true 是因为量过的斜向只在 flipped 下成立。
        let styled = italic
            ? Self.italicStyledText(text, font: textFont, color: color,
                                    flipped: NSGraphicsContext.current?.isFlipped ?? true)
            : NSAttributedString(string: text, attributes: [
                .font: textFont,
                .foregroundColor: color,
            ])
        styled.draw(at: start)
    }

    /// 底和框共用的一条圆角路径：短边不到两倍圆角时把圆角收到短边一半，否则
    /// 一条两个字的短注脚会画成一粒胶囊。
    private static func textOutline(_ box: CGRect) -> NSBezierPath {
        let radius = min(textCornerRadius, min(box.width, box.height) / 2)
        return NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    }

    private func drawMosaic(shot: ScreenshotFrame) {
        guard let tile = ScreenshotMosaic.tile(from: shot.image, viewRect: rect, scale: shot.scale) else { return }
        let context = NSGraphicsContext.current
        let previous = context?.imageInterpolation
        // 关掉插值才会看见方块；平滑插值打出来的只是一团糊。
        context?.imageInterpolation = .none
        NSImage(cgImage: tile, size: rect.size).draw(in: rect)
        context?.imageInterpolation = previous ?? .default
        // 这里**不**描边。打码块的边框是拖动过程中的辅助线（画在遮罩里，见
        // `ScreenshotSelectionView.drawMosaicGuide`），松手就该没了 —— 它是「帮你看清
        // 这块到哪为止」，不是内容的一部分，更不该被带进成品 PNG。
    }

    private func drawBadge() {
        // 和命中、编辑外框同一块矩形（`badgeBox`）：绘制自己算一遍，改框子的时候就会
        // 出现「看得见却点不着」或反过来「点着了画到别处」。
        let box = Self.badgeBox(start: start, radius: badgeRadius)
        color.setFill()
        NSBezierPath(ovalIn: box).fill()
        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.boldSystemFont(ofSize: badgeRadius),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
    }
}

/// 一条注解上能被抓住改的位置。
///
/// 分两类是因为它们改的东西不一样：`box` 动的是包围盒（框类重映射、画笔跟着拉伸、
/// 文字和序号等比改字号），`tail`/`head` 只挪箭头那一个端点 —— 箭头没有「缩放包围盒」
/// 这一档，拖它的角等于把一支箭拉成另一支箭，要改方向和长短就该抓那两颗点。
///
/// internal 而非 public：它带着 `RegionHandle`（遮罩那边的把手枚举），一条注解的把手
/// 语义和遮罩的命中算法必须同源，不能拆成两套公开 API 各长各的。
enum AnnotationGrab: Hashable {
    case box(RegionHandle)
    case tail
    case head

    var isEndpoint: Bool {
        switch self {
        case .box: return false
        case .tail, .head: return true
        }
    }

    /// 抓它时光标该变什么：端点跟「挪这一条」同一档，盒把手沿用选区那八个的方向。
    var cursor: NSCursor {
        switch self {
        case .tail, .head: return .openHand
        case .box(let handle): return handle.cursor
        }
    }
}

// MARK: - 画完之后还要改（用户 2026-10-19：「添加的注释方向方框等要支持编辑」）
//
// 这一整段全是**纯函数**：吃一条注解、返回新的一条，不碰视图、不读全局。遮罩那边只
// 负责「哪一条、按住了哪儿、拖到哪儿」，几何与样式怎么变都在这里算完 —— 这样单测能
// 直接把一条矩形拉大、把一支箭掉头、把一行字放大，不用先搭一屏遮罩。
//
// 坐标口径和绘制侧同一条：一律是遮罩视图的点坐标（整屏 flipped）。
extension ScreenshotAnnotation {
    /// 缩到比这更小，把手就挤在一起没法再抓了。比选区那档（`minRegionSize` = 20）小得多：
    /// 一枚序号本来就只有二十几点宽，按选区的下限它压根缩不动。
    static let minEditSize: CGFloat = 6

    /// 选中之后画框、摆把手的那一块。
    ///
    /// 不能直接用 `rect`：文字和序号的 `start` 只是锚点，`rect` 对它们是零面积 ——
    /// 那两个要读真正占到的地方（字的外框 / 徽标圆的外切方）。
    var editBox: CGRect {
        switch tool {
        case .text: return textBoxRect
        case .number: return Self.badgeBox(start: start, radius: badgeRadius)
        default: return rect
        }
    }

    /// 这条注解露出哪些把手。数组顺序就是命中顺序（先查的赢），角排在边前面 ——
    /// 和选区那八个同一口径，否则拖角会退化成只动一条边。
    var editableGrabs: [AnnotationGrab] {
        switch tool {
        case .arrow:
            // 端点优先：一支水平/垂直的箭，它的端点正好落在自己包围盒的角上 ——
            // 那一下该挪的是箭尾/箭头，不是那块隐形的盒子。
            return [.head, .tail]
        case .text, .number:
            // 只给四个角。边把手只能改一个方向，而字和徽标是等比放大的 —— 拖右边那条
            // 会把「24 号字」变成「横向拉长的 24 号字」，模型里没有这一档。
            return RegionHandle.cornerOrder.map { .box($0) }
        default:
            return RegionHandle.grabOrder.map { .box($0) }
        }
    }

    /// 某个把手的命中区（遮罩坐标）：围着**看得见的那颗手柄**的一小块 16×16。
    ///
    /// 端点沿用选区角把手同一档边距（`handleSlop`）。盒把手**不**抄选区那条
    /// `zone(_:of:)`：那条是「沿整条边铺开的长条」，给选区合适（整条边框都是改框的把手），
    /// 给注解就是把整条墨迹都划成了缩放 —— 空心框的线本来就贴着边，选中之后再照着框线
    /// 一按想挪，结果缩了框，第二次拖动全废。收成中点一小块之后：角上两种算法给的是
    /// 同一块（角本来就是 2×slop 的方块），边只认中点那一小片，边上其余地方交还给
    /// 「整条平移」。
    func grabZone(_ grab: AnnotationGrab) -> CGRect {
        let center = grabCenter(grab)
        let slop = ScreenshotSelectionView.handleSlop
        return CGRect(x: center.x - slop, y: center.y - slop, width: slop * 2, height: slop * 2)
    }

    /// 把手画在哪儿：盒把手在包围盒的角/边中点，端点就在线段那头。
    func grabCenter(_ grab: AnnotationGrab) -> CGPoint {
        switch grab {
        case .box(let handle): return ScreenshotSelectionView.center(of: handle, in: editBox)
        case .tail: return start
        case .head: return end
        }
    }

    /// 这一点按住了这条注解的哪个把手（没按到任何把手就返回 nil）。
    func grab(at point: CGPoint) -> AnnotationGrab? {
        editableGrabs.first { grabZone($0).contains(point) }
    }

    /// 这一点是否按在注解**本体**上（把手不算）。
    ///
    /// 空心框只认「看得见的那条线」±(半个线宽 + slop)：整块都认的话，画一个大框就等于
    /// 把框住的那片选区平移全吃掉了 —— 用户照着框里面一按想拖的是选区，结果框自己跑了。
    /// 打码、文字、序号是实心的一块，整块都能抓。
    func contains(_ point: CGPoint, slop: CGFloat) -> Bool {
        let band = lineWidth / 2 + slop
        switch tool {
        case .rect:
            let outer = rect.insetBy(dx: -band, dy: -band)
            guard outer.contains(point) else { return false }
            // `rect` 内缩到线内侧以外才算「中间」；框窄到两条边重合时内缩矩形翻面，
            // `contains` 恒假 —— 那时候整块都当线上，反而点得着。
            return !rect.insetBy(dx: band, dy: band).contains(point)
        case .ellipse:
            let halfW = rect.width / 2, halfH = rect.height / 2
            guard halfW > 0.001, halfH > 0.001 else { return false }
            let r = hypot((point.x - rect.midX) / halfW, (point.y - rect.midY) / halfH)
            // 归一化半径差 × 短半轴 ≈ 到曲线的点距（长轴那头会略宽松几像素，命中够用）。
            return abs(r - 1) <= band / min(halfW, halfH)
        case .arrow:
            return Self.distance(point, toSegment: start, and: end) <= band
        case .pen:
            guard points.count > 1 else { return false }
            for index in 1 ..< points.count where Self.distance(point, toSegment: points[index - 1],
                                                                and: points[index]) <= band {
                return true
            }
            return false
        case .mosaic:
            return rect.contains(point)
        case .text:
            return textBoxRect.insetBy(dx: -slop, dy: -slop).contains(point)
        case .number:
            return hypot(point.x - start.x, point.y - start.y) <= badgeRadius + slop
        }
    }

    /// 点到线段的最短距离（画笔和箭头判命中都靠它）。
    static func distance(_ point: CGPoint, toSegment a: CGPoint, and b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - (a.x + dx * t), point.y - (a.y + dy * t))
    }

    // MARK: 改一条

    /// 整条平移。样式一个字段都不碰。
    func movedBy(_ offset: CGSize) -> ScreenshotAnnotation {
        mappingPoints { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
    }

    /// 按住某个把手拖到 `point`，另一头钉住；不许缩出 `limit`（遮罩那边传的是整块屏）。
    ///
    /// **每次都从按下那一刻的原样算**，不从上一帧的结果接着算：拖动期间鼠标一帧几像素，
    /// 逐帧累加会把圆角、字号这些取整过的量越拖越偏（选区平移也是同一口径，见 `moveStart`）。
    func applyingResize(_ grab: AnnotationGrab, to point: CGPoint, limit: CGRect) -> ScreenshotAnnotation {
        switch grab {
        case .tail, .head:
            let next = CGPoint(x: min(max(point.x, limit.minX), limit.maxX),
                               y: min(max(point.y, limit.minY), limit.maxY))
            return withArrowEndpoint(head: grab == .head, to: next)
        case .box(let handle):
            let box = editBox
            let target = ScreenshotSelectionView.resize(box, edges: handle.edges, to: point,
                                                        limit: limit, minSize: Self.minEditSize)
            switch tool {
            case .text: return scaledText(to: target, handle: handle)
            case .number: return scaledBadge(to: target, handle: handle)
            default: return mappingPoints(Self.boxMap(from: box, to: target))
            }
        }
    }

    /// 挪箭头的一个端点，另一端钉住。箭头的「缩放」就是这两颗点：长短和方向都在里面，
    /// 粗细交给面板的滑杆。
    func withArrowEndpoint(head: Bool, to point: CGPoint) -> ScreenshotAnnotation {
        copying(start: head ? start : point, end: head ? point : end)
    }

    /// 换成面板上那一套值，几何（位置、轨迹、文字内容、序号）原样留着。
    ///
    /// 只给「被选中的那一条」用（用户 2026-10-19 定的口径：改样式不许回头把同工具
    /// 画过的其他条一起刷掉）。整套样式都从 `style` 来，所以这里直接走 `init`，
    /// 描边/背景能传成 nil（= 关掉）。
    func styled(with style: ScreenshotToolStyle) -> ScreenshotAnnotation {
        ScreenshotAnnotation(tool: tool, color: style.color, lineWidth: style.lineWidth,
                             start: start, end: points.isEmpty ? end : nil, points: points,
                             text: text, number: number, fontSize: style.fontSize,
                             bold: style.bold, italic: style.italic,
                             borderColor: style.borderColor, backgroundColor: style.backgroundColor)
    }

    /// 只换文字内容：位置、字号、颜色、描边、背景一个都不动。双击一条已写的字改内容
    /// 走这条路（用户 2026-10-19 定的口径：改旧字 = 双击它）。
    ///
    /// 不复用 `styled(with:)`：那条整套样式都从面板来，改一个字不该把描边色、背景色按
    /// 面板当前那套重铺一遍。也不开 `copying(text:)` 那条口子：`copying` 是这一文件的
    /// 内部手脚（`nil` 一律读作「照抄」），暴露出去就成了谁都能拼一条的万能构造器。
    func replacingText(_ text: String) -> ScreenshotAnnotation {
        ScreenshotAnnotation(tool: tool, color: color, lineWidth: lineWidth, start: start,
                             end: points.isEmpty ? end : nil, points: points,
                             text: text, number: number, fontSize: fontSize,
                             bold: bold, italic: italic,
                             borderColor: borderColor, backgroundColor: backgroundColor)
    }

    /// 这条现在那一套值 —— 选中它之后面板上显示的就是它（反过来读，不各存一份）。
    var styleValue: ScreenshotToolStyle {
        ScreenshotToolStyle(color: color, lineWidth: lineWidth, fontSize: fontSize,
                            bold: bold, italic: italic,
                            borderColor: borderColor, backgroundColor: backgroundColor)
    }

    // MARK: 几何换算（内部）

    /// 逐字段照抄自己，只换掉传进来的那几样。
    ///
    /// 为什么要手写一遍 `init`：`init` 不传 `fontSize` 会按粗细重算派生档（「粗细即字号」
    /// 那条老式子），靠默认参数复制一条「48 号字」回来就变回 24 —— `extendingPen` 当年
    /// 漏带字段跳的是同一个坑。所以这里的 `nil` 一律读作「照抄」；真要把某个字段清空
    /// （比如去掉描边色）走 `styled(with:)`，那儿整套值都来自面板，本来就不必留旧值。
    private func copying(start: CGPoint? = nil, end: CGPoint? = nil, points: [CGPoint]? = nil,
                         color: NSColor? = nil, lineWidth: CGFloat? = nil,
                         fontSize: CGFloat? = nil, bold: Bool? = nil,
                         italic: Bool? = nil) -> ScreenshotAnnotation {
        ScreenshotAnnotation(tool: tool, color: color ?? self.color,
                             lineWidth: lineWidth ?? self.lineWidth,
                             start: start ?? self.start,
                             // 有轨迹时 `init` 按点列首尾推 start/end，这里再传一遍会打架。
                             end: points == nil ? (end ?? self.end) : nil,
                             points: points ?? self.points, text: text, number: number,
                             fontSize: fontSize ?? self.fontSize,
                             bold: bold ?? self.bold, italic: italic ?? self.italic,
                             borderColor: borderColor, backgroundColor: backgroundColor)
    }

    /// 每个坐标都过一遍 `map`（非轨迹工具就 start/end 两个点）。
    private func mappingPoints(_ map: (CGPoint) -> CGPoint) -> ScreenshotAnnotation {
        copying(start: map(start), end: map(end), points: points.isEmpty ? nil : points.map(map))
    }

    /// 把 `old` 这块映射到 `new`：两轴各自缩放再平移。
    ///
    /// 退化那一轴（拖成一条竖线/横线的画笔，宽或高为 0）不缩放、只跟着平移 —— 除零之外，
    /// 「零宽放大成 80 宽」会把一条竖线糊成一块谁都没要的板。
    static func boxMap(from old: CGRect, to new: CGRect) -> (CGPoint) -> CGPoint {
        let sx = old.width >= 1 ? new.width / old.width : 1
        let sy = old.height >= 1 ? new.height / old.height : 1
        return { CGPoint(x: new.minX + ($0.x - old.minX) * sx,
                         y: new.minY + ($0.y - old.minY) * sy) }
    }

    /// 等比缩放用的系数：面积比开方。角把手拖出「两倍长 × 两倍宽」= 放大两倍。
    static func uniformScale(from old: CGRect, to new: CGRect) -> CGFloat {
        let ratio = max(0, new.width * new.height) / max(1, old.width * old.height)
        return max(0.05, sqrt(ratio))
    }

    /// 拖某个角时**不动**的那一头：拖右下角 = 左上角钉住。
    static func fixedCorner(of handle: RegionHandle, in box: CGRect) -> CGPoint {
        CGPoint(x: handle.edges.contains(.left) ? box.maxX : box.minX,
                y: handle.edges.contains(.top) ? box.maxY : box.minY)
    }

    /// 文字：改的是字号，不是把字拉扁。所以先由目标框推出字号，让盒子跟着字号自己长，
    /// 再把新盒子钉回被拖那个角的对角上 —— 拖到哪只是「要多大」的输入。
    private func scaledText(to target: CGRect, handle: RegionHandle) -> ScreenshotAnnotation {
        let range = ScreenshotToolStyle.fontRange
        let raw = fontSize * Self.uniformScale(from: editBox, to: target)
        // 取整：13.7 号字既显示不出、也没法第二次精确复现，缩放两下就会漂。
        let size = min(max(raw.rounded(), range.lowerBound), range.upperBound)
        let scaled = copying(fontSize: size)
        let box = scaled.textBoxRect
        let anchor = Self.fixedCorner(of: handle, in: target)
        let origin = CGPoint(x: handle.edges.contains(.left) ? anchor.x - box.width : anchor.x,
                             y: handle.edges.contains(.top) ? anchor.y - box.height : anchor.y)
        return scaled.copying(start: CGPoint(x: origin.x + scaled.textPadding,
                                             y: origin.y + scaled.textPadding))
    }

    /// 序号：那一格没有字号可滑，圈的大小就是粗细（见 `badgeRadius`），所以缩放改的是
    /// `lineWidth`。`badgeRadius` 有 11 的下限，缩到那以下会停住 —— 数字总比圈大就没法看了。
    private func scaledBadge(to target: CGRect, handle: RegionHandle) -> ScreenshotAnnotation {
        let range = ScreenshotToolStyle.widthRange
        let raw = lineWidth * Self.uniformScale(from: editBox, to: target)
        let width = min(max(raw, range.lowerBound), range.upperBound)
        let scaled = copying(lineWidth: width)
        let radius = scaled.badgeRadius
        let anchor = Self.fixedCorner(of: handle, in: target)
        let center = CGPoint(x: handle.edges.contains(.left) ? anchor.x - radius : anchor.x + radius,
                             y: handle.edges.contains(.top) ? anchor.y - radius : anchor.y + radius)
        return scaled.copying(start: center)
    }

    /// 序号徽标的外切方（绘制侧 `drawBadge` 用的是同一块，别各算各的）。
    static func badgeBox(start: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: start.x - radius, y: start.y - radius,
               width: radius * 2, height: radius * 2)
    }
}

/// 像素化：缩小 1/block 再关插值放大回去。均值由降采样顺手做掉，不自己遍历像素。
enum ScreenshotMosaic {
    /// 方块边长按**像素**算：打码的效果取决于分辨率，跟用户拖了多少点无关。
    static let blockSize: CGFloat = 12

    static func tile(from image: CGImage, viewRect: CGRect, scale: CGFloat) -> CGImage? {
        let pixel = CGRect(x: viewRect.minX * scale, y: viewRect.minY * scale,
                           width: viewRect.width * scale, height: viewRect.height * scale)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let region = pixel.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1,
              let source = image.cropping(to: region) else { return nil }
        let width = max(1, Int(region.width / blockSize))
        let height = max(1, Int(region.height / blockSize))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        // 这里**不能**加翻转：/tmp 上的探针实测 identity 下 `draw` 就是正立的，
        // translate+scale(1,-1) 反而把小块画倒了。
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

/// 把「选区那块底图 + 落在其中的注解」烘成一张最终图。
public enum ScreenshotComposer {
    public static func compose(shot: ScreenshotFrame, selection: CGRect,
                               annotations: [ScreenshotAnnotation]) -> CGImage? {
        guard selection.width > 0, selection.height > 0 else { return nil }
        // 整屏铺一遍再裁，而不是裁完再画：注解本来就是整屏视图坐标，这样三条绘制
        // 路径（屏上遮罩、预览、导出）用的是同一个坐标空间，不会各算各的。
        let view = ScreenshotExportView(frame: NSRect(origin: .zero, size: shot.pointSize))
        view.shot = shot
        view.annotations = annotations
        // 渲染之前把视图挂到一扇从没上屏的窗上：不挂窗时 AppKit 的 focus 上下文不完整，
        // 文字类注解会缺笔画（离屏取证实测）。orderOut 保证不会闪一下。
        let host = ScreenshotOverlayWindow(screenFrame: NSRect(origin: .zero, size: shot.pointSize))
        host.contentView = view
        host.orderOut(nil)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let rendered = bitmap.cgImage else { return nil }

        // 裁切矩形按**渲染结果**的实际比例算，不照抄 shot.scale：离屏位图每点对多少
        // 像素由那块屏的 backing scale 决定，两者不一致时（缩放分辨率、非 Retina 外接
        // 屏）照抄就会裁到别处去。
        let ratioX = CGFloat(rendered.width) / shot.pointSize.width
        let ratioY = CGFloat(rendered.height) / shot.pointSize.height
        let rect = CGRect(x: (selection.minX * ratioX).rounded(.down),
                          y: (selection.minY * ratioY).rounded(.down),
                          width: ceil(selection.width * ratioX),
                          height: ceil(selection.height * ratioY))
            .intersection(CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let cut = rendered.cropping(to: rect.integral) else { return nil }
        return cut
    }
}

/// 只用来导出的离屏视图：1:1 铺底图，注解按视图坐标直接画在上面。
private final class ScreenshotExportView: NSView {
    var shot: ScreenshotFrame?
    var annotations: [ScreenshotAnnotation] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let shot else { return }
        NSImage(cgImage: shot.image, size: bounds.size).draw(in: bounds)
        for annotation in annotations {
            annotation.draw(shot: shot)
        }
    }
}
