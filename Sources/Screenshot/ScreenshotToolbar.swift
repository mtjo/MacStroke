//
//  ScreenshotToolbar.swift
//  MacStroke
//
//  选区确定后浮出来的注解条：工具 / 颜色 / 线宽 / 撤销 / 存文件 / 复制 / 取消。
//
//  自绘而不是 NSStackView + NSButton：这层窗是 CGShieldingWindowLevel 的 borderless
//  窗，标准按钮的 bezel 在里面会渲染成系统设置里那种灰块。
//
//  样式照 QQ 那条注解条（用户指定参照物）：胶囊底 + 线性图标的**图标语言**、格子顺序，
//  出口是红✕、绿✓。但借的只是样子 —— 底衬和墨色**跟随系统外观**（用户 2026-10-16 补的一句：
//  「我是要图标参考，但是还要跟随主题功能」），浅桌面底下就是浅底深图标。选中态仍铺系统蓝、
//  不跟强调色走：深底浅底上「蓝格 + 白图标」都够跳，而用户把强调色调成浅色时铺强调色会白
//  图标糊进格子里。
//
//  底色和图标都走 `draw(_:)`，不用 CALayer 背景、也不用 NSImageView 的 tintColor：
//  离屏取证靠 `cacheDisplay`，那条路只重放视图自己的绘制代码，layer 的 backgroundColor
//  和 image view 的 tint 都不在里面（实测过：条子在 PNG 里是空的）。
//
//  语义色必须在 `draw` **之前**解析成具体值（见 `ToolbarStyle.resolved(for:)`）：它们要按当前
//  图形上下文的外观取值，而离屏那条上下文的外观和视图的不是同一个 —— 直接把 `windowBackgroundColor`
//  拿进 draw 里 `setFill()`，浅色外观下烘出来的仍是深底。写死一档的只有调色板那五个墨色（要进
//  成品 PNG，见 `ScreenshotToolbarView.palette`）和选中蓝。
//
//  条子是遮罩视图的子视图，但**只有可点元素吃掉事件**：空白处 hitTest 直接放行回遮罩
//  （见 hitTest 那段注释）。用户按住空白处是要把整条拖走 —— 全屏截图时条子压在画面上，
//  挪不开就没法编辑被盖住的那块。
//

import AppKit
import Storage

/// 浮层的配色：语义色按视图的外观解析成具体 sRGB，两档各缓存一份。
///
/// internal 而不是 private：顶部模式条（`ScreenshotModeBarView`）和实时采集控制面板
/// 要和注解条同一档底、同一套墨色，用户切明暗时三条浮层必须一起翻。
struct ToolbarStyle {
    let barFill: NSColor
    let barBorder: NSColor
    let glyph: NSColor
    /// 色块/线宽格的选中底：中性一档，压得住又不抢内容。
    let chipIdle: NSColor
    let separator: NSColor
    /// 色块自带一圈描边：白色块压在浅底上、黑色块压在深底上都要留得住边。
    let swatchRing: NSColor
    /// QQ 的两个出口各自带色：红色✕ discard、绿色✓ 出图，靠颜色而不是位置表意。
    let cancel: NSColor
    let confirm: NSColor

    /// 选中格：铺系统蓝、图形转白。这一档不跟外观、也不跟用户的强调色走。
    static let accent = NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
    static let onAccent = NSColor.white

    /// 靠自身颜色表意的那几枚出口，墨色要等外观解析出来才有值。
    enum Role { case cancel, confirm }

    /// 只在主线程读写：视图的 `draw` 全在主线程。
    private static var cache: [NSAppearance.Name: ToolbarStyle] = [:]

    static func resolved(for appearance: NSAppearance) -> ToolbarStyle {
        if let hit = cache[appearance.name] { return hit }
        let made = ToolbarStyle.build(appearance)
        cache[appearance.name] = made
        return made
    }

    private static func build(_ appearance: NSAppearance) -> ToolbarStyle {
        ToolbarStyle(
            barFill: concrete(.windowBackgroundColor, in: appearance).withAlphaComponent(0.94),
            barBorder: concrete(.separatorColor, in: appearance),
            glyph: concrete(.labelColor, in: appearance),
            chipIdle: concrete(.tertiaryLabelColor, in: appearance),
            separator: concrete(.quaternaryLabelColor, in: appearance),
            swatchRing: concrete(.tertiaryLabelColor, in: appearance),
            cancel: concrete(.systemRed, in: appearance),
            confirm: concrete(.systemGreen, in: appearance)
        )
    }

    /// 把语义色在该外观下读成一个具体的 sRGB 值。
    ///
    /// `usingColorSpace(.sRGB)` 取的是**当时** `NSAppearance.current` 那一档，而视图 draw 时
    /// 图形上下文带的外观不一定是视图自己那个（离屏 `cacheDisplay` 尤其如此），所以先在
    /// `performAsCurrentDrawingAppearance` 里固化，之后 `setFill()` 拿到的是常量，不会再飘。
    private static func concrete(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolvedColor = color
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.sRGB) ?? color
        }
        return resolvedColor
    }
}

/// 注解条上的一个可点元素。
private final class ScreenshotToolbarItem: NSView {
    enum Glyph {
        case symbol(String)
        /// 打码标记：4x4 像素格。系统那个 `mosaic` 是「几块不等大的板子拼成的方框」，
        /// 读起来像分栏布局而不像打码（用户原话「不够形象」），QQ 那枚是像素格。
        case checkerboard
        case swatch(NSColor)
        case stroke(CGFloat)
        case separator
    }

    let action: (() -> Void)?
    /// 这一格是干什么的：取证要按顺序核对条子上都摆了哪些格（文案会随语言变，这个不会）。
    let id: String
    /// 悬停时提示的文字。不走 `NSView.toolTip`，理由见 `ScreenshotTipView`。
    let tipText: String
    var isActive = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }

    private let glyph: Glyph
    /// 这一格靠自己的颜色表意（红✕、绿✓），其余跟着条子的墨色走。存的是角色不是颜色：
    /// 那两个值要按外观解析，装配时机比绘制时机早，写死就把「跟随主题」废掉了。
    private let tintRole: ToolbarStyle.Role?
    private let template: NSImage?
    /// 图形符号按颜色烫好再缓存：draw 里每次现烫一遍，拖动时每一帧都要重画二十来个格子。
    private var tinted: [NSColor: NSImage] = [:]

    init(glyph: Glyph, width: CGFloat, id: String = "", toolTip: String = "",
         tintRole: ToolbarStyle.Role? = nil, action: (() -> Void)? = nil) {
        self.glyph = glyph
        self.action = action
        self.id = id
        self.tintRole = tintRole
        self.tipText = toolTip
        if case let .symbol(name) = glyph {
            template = ScreenshotToolbarItem.templateImage(name)
        } else {
            template = nil
        }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: ScreenshotToolbarView.itemHeight))
        // 提示气泡是画在遮罩里的，读屏软件看不见，这一行是给无障碍留的底。
        setAccessibilityLabel(toolTip.isEmpty ? nil : toolTip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        if action != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = ToolbarStyle.resolved(for: effectiveAppearance)
        if case .separator = glyph {
            style.separator.setFill()
            CGRect(x: bounds.midX - 0.5, y: 10, width: 1, height: bounds.height - 20).fill()
            return
        }
        let inset = bounds.insetBy(dx: 2, dy: 2)
        if isActive {
            (glyphIsOnAccent ? ToolbarStyle.accent : style.chipIdle).setFill()
            NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6).fill()
        }
        let alpha: CGFloat = isEnabled ? 1 : 0.3
        let ink = inkColor(from: style)
        switch glyph {
        case .checkerboard:
            drawCheckerboard(color: ink, alpha: alpha)
        case .symbol:
            // respectFlipped：视图是 flipped 的，不告诉 AppKit 它会上下颠倒画图标
            // （实测 arrow.up.right 画成 ↘）。
            guard let image = image(for: ink) else { break }
            // 按原尺寸居中画：draw(in:) 会把图铺满给定矩形，直接喂 bounds 就成了
            // 拉扁的大图标（符号自然尺寸约 23x18，格子 32x30）。
            let side = min(image.size.width, bounds.width - 4)
            let ratio = side / image.size.width
            let box = CGRect(x: bounds.midX - side / 2, y: bounds.midY - image.size.height * ratio / 2,
                             width: side, height: image.size.height * ratio)
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: alpha,
                       respectFlipped: true, hints: nil)
        case let .swatch(color):
            drawSwatch(color, active: isActive,
                       ring: isActive ? ToolbarStyle.accent : style.swatchRing, alpha: alpha)
        case let .stroke(width):
            ink.setFill()
            let line = CGRect(x: bounds.minX + 5, y: bounds.midY - width / 2,
                              width: bounds.width - 10, height: width)
            NSBezierPath(roundedRect: line, xRadius: width / 2, yRadius: width / 2).fill()
        case .separator:
            break
        }
    }

    /// 这一格该用什么墨色：选中转白，两个出口各取自己那一档语义色，其余跟条子走。
    private func inkColor(from style: ToolbarStyle) -> NSColor {
        if isActive { return ToolbarStyle.onAccent }
        switch tintRole {
        case .cancel: return style.cancel
        case .confirm: return style.confirm
        case nil: return style.glyph
        }
    }

    /// 色块不能铺蓝底（盖上就认不出这是什么色），它走「中性格子 + 一圈描边」；选中那一档
    /// 描边换成系统蓝。色块本身永远是调色板里写死的那一档 —— 那个值要进成品 PNG。
    private func drawSwatch(_ color: NSColor, active: Bool, ring: NSColor, alpha: CGFloat) {
        let side = min(bounds.width - 8, bounds.height - 16)
        let box = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                         width: side, height: side)
        let circle = NSBezierPath(ovalIn: box)
        color.withAlphaComponent(alpha).setFill()
        circle.fill()
        ring.setStroke()
        let outline = NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = active ? 2 : 1
        outline.stroke()
    }

    /// 4x4 像素格，深浅两档交替 —— 一眼是「这块被打花了」。整块 18pt 见方，和旁边的
    /// 符号图标同量级；格子之间留 0.6pt 缝，不留缝会糊成一整块实心方块。
    private func drawCheckerboard(color: NSColor, alpha: CGFloat) {
        let side: CGFloat = 18
        let box = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                         width: side, height: side)
        let cell = side / 4
        for row in 0..<4 {
            for column in 0..<4 {
                let solid = (row + column).isMultiple(of: 2)
                color.withAlphaComponent(alpha * (solid ? 1 : 0.28)).setFill()
                CGRect(x: box.minX + CGFloat(column) * cell,
                       y: box.minY + CGFloat(row) * cell,
                       width: cell - 0.6, height: cell - 0.6).fill()
            }
        }
    }

    /// 除色块外的格子，选中态整块铺系统蓝、图形转白 —— 和系统分段控件的选中档一个读法。
    private var glyphIsOnAccent: Bool {
        switch glyph {
        case .symbol, .stroke, .checkerboard: return true
        default: return false
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 必须自己把按下吃掉：不实现就会顺着 responder chain 冒到遮罩，那点被当成
        // 「按住条子空白处」，用户点一下工具按钮顺带把整条拖走了。
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }

    private func image(for color: NSColor) -> NSImage? {
        guard let template else { return nil }
        if let hit = tinted[color] { return hit }
        let size = template.size
        guard size.width > 1, size.height > 1 else { return nil }
        let baked = NSImage(size: size)
        baked.lockFocus()
        template.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        baked.unlockFocus()
        tinted[color] = baked
        return baked
    }

    /// 图标缺失时（系统版本不带某个 symbol）退化成问号，好过条子上出现一个空白块。
    /// template 图不烫色存着，烫色留给 `image(for:)`：浅色底要深字、选中格要白字。
    private static func templateImage(_ name: String) -> NSImage? {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)
        base?.isTemplate = true
        return base?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: ScreenshotToolbarView.iconPointSize,
                                        weight: .regular))
    }
}

/// 悬停功能提示：深色小圆角气泡 + 白字，摆在被指到的那一格正上方。
///
/// 不用 `NSView.toolTip`：那是系统另开的一扇窗，层级在整屏遮罩（CGShieldingWindowLevel）
/// 底下，弹了也看不见 —— 同一个坑见过两次（那只 Toast 和放大镜的「已复制」，见
/// `copyMagnifierColor` 的注释）。所以它自己画在遮罩里，是条子的兄弟视图。
final class ScreenshotTipView: NSView {
    static let height: CGFloat = 26
    /// 气泡和格子之间留的缝：贴着摆会像是格子长出来的一块。
    static let gap: CGFloat = 6
    private static let padding: CGFloat = 9
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// 此刻气泡上写的那句话。`private(set)` 是给取证的：悬停到某一格之后，要能读出
    /// 气泡**实际**端出来的文字，才能核对它报的是不是这一格 —— 只断言「有个气泡」等于
    /// 没核对内容，格子和文案串了线照样全绿。
    private(set) var text = ""

    override var isFlipped: Bool { true }

    /// 纯装饰：气泡压在选区上，那一块的点击（画注解、拖条子）不能被它吃掉。和放大镜
    /// `ScreenshotMagnifierView` 同一句放行。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 摆到 `cell`（遮罩坐标的一格）上方；上面顶到屏边就翻到下面，横向钳在屏内。
    func show(_ text: String, cell: NSRect, in container: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        let width = ceil((text as NSString).size(withAttributes: attributes).width)
            + Self.padding * 2
        let margin = ScreenshotToolbarView.edgePadding
        var x = cell.midX - width / 2
        x = min(max(x, container.minX + margin),
                max(container.maxX - width - margin, container.minX + margin))
        var y = cell.minY - Self.gap - Self.height
        if y < container.minY + margin { y = cell.maxY + Self.gap }
        self.text = text
        frame = CGRect(x: x, y: y, width: width, height: Self.height)
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = ToolbarStyle.resolved(for: effectiveAppearance)
        let body = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        // 和条子同一档底：一眼是「条子在说话」，不是屏幕上又多了一个窗。
        style.barFill.setFill()
        body.fill()
        style.barBorder.setStroke()
        body.lineWidth = 1
        body.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font,
                                                         .foregroundColor: style.glyph]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                            y: bounds.midY - size.height / 2),
                                withAttributes: attributes)
    }
}

/// 遮罩上的注解条。
final class ScreenshotToolbarView: NSView {
    static let barHeight: CGFloat = 42
    static let itemHeight: CGFloat = 30
    static let edgePadding: CGFloat = 7
    static let gap: CGFloat = 3
    static let separatorWidth: CGFloat = 10
    static let iconPointSize: CGFloat = 17

    /// 图标格和留白格的两档宽度：工具/出口要按得住，色块与线宽只是挑一个值。
    static let iconItemWidth: CGFloat = 32
    static let optionItemWidth: CGFloat = 22

    /// 调色板：QQ 的默认色是红，白/黑留给深色图和浅底图各一路。
    ///
    /// 前三档**不写 `.systemRed` 那类语义色**：它们是随外观换档的动态色（实测浅/深两套
    /// 差到 0.04，红 1.0/0.231/0.188 → 1.0/0.271/0.228），而这一档色值不只画在色块上 ——
    /// 它还会被带进注解合成，写进成品 PNG。留着动态色就是「条子上挑的红」和「图里的红」
    /// 按各自上下文解析成两种红，深浅桌面下还会飘。数值取浅色外观那一档（QQ 的调色板本来
    /// 就是一套固定色，不跟系统）。
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.0000, green: 0.2314, blue: 0.1882, alpha: 1),
        NSColor(srgbRed: 1.0000, green: 0.8000, blue: 0.0000, alpha: 1),
        NSColor(srgbRed: 0.1569, green: 0.8039, blue: 0.2549, alpha: 1),
        .white, .black,
    ]
    static let lineWidths: [CGFloat] = [2, 4, 7]

    var onTool: ((ScreenshotTool) -> Void)?
    var onColor: ((Int) -> Void)?
    var onWidth: ((Int) -> Void)?
    /// 图钉贴图：把成品钉在屏幕上（QQ 的那枚图钉）。
    var onPin: (() -> Void)?
    /// 裁剪：拿当前选区再框一块。
    var onCrop: (() -> Void)?
    /// 提取文字：认完把文本交回上层，条子只管这一枚按下去了没有。
    var onOCR: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    /// 绿✓：复制到剪贴板并收场，和选区内双击、回车同一条路。
    var onCopy: (() -> Void)?
    var onCancel: (() -> Void)?

    private var entries: [(view: NSView, width: CGFloat)] = []
    private var toolItems: [ScreenshotTool: ScreenshotToolbarItem] = [:]
    private var colorItems: [Int: ScreenshotToolbarItem] = [:]
    private var widthItems: [Int: ScreenshotToolbarItem] = [:]
    private var undoItem: ScreenshotToolbarItem?
    private var redoItem: ScreenshotToolbarItem?
    private var ocrItem: ScreenshotToolbarItem?

    /// 条子宽度是固定的：定位要在还没挂上视图时算，所以 init 里就把总宽算好。
    private(set) var preferredWidth: CGFloat = 0

    /// internal 而非 private：取证要核对「枚举里的工具在条子上一个都没漏」。漏一个
    /// 就是这工具压根选不到，而只看枚举本身看不出这件事。
    var toolsOnBar: Set<ScreenshotTool> { Set(toolItems.keys) }

    /// 条子上每一格都是干什么的，按从左到右的顺序。取证用它核对布局：漏一格、多一格、
    /// 摆错顺序，在代码里都看不出来，只有对着装配好的条子数才看得出来。
    var elementsOnBar: [String] {
        entries.compactMap { ($0.view as? ScreenshotToolbarItem)?.id }.filter { !$0.isEmpty }
    }

    /// 条子上此刻亮着的那一格工具。internal 而非 private：取证要核对「选中态」真的落到了
    /// 格子上，而不是只活在遮罩的状态位里 —— 遮罩自己装了画笔而条子没跟着高亮，
    /// 用户就看不出可以直接开始画。
    var activeToolOnBar: ScreenshotTool? {
        toolItems.first { $0.value.isActive }?.key
    }

    /// 此刻按不动的那几格（灭着的）。取证用它核对「灭」真的落到了格子上，而不是只活在
    /// 遮罩的状态位里 —— 遮罩那边置了 `ocrRunning`，条子没跟着变灰就等于没拦住第二下。
    var disabledElementsOnBar: [String] {
        entries.compactMap { entry -> String? in
            guard let item = entry.view as? ScreenshotToolbarItem,
                  item.action != nil, !item.isEnabled, !item.id.isEmpty else { return nil }
            return item.id
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        // 整条都能拖走，底衬给「抓住可拖」的手形。NSCursor 没有公开的四向箭头光标，
        // 开掌是最接近的一个；按钮自己那条 `.pointingHand` 在更深的视图上，压得过这里。
        addCursorRect(bounds, cursor: .openHand)
    }

    /// 可点元素在**本视图坐标**里的矩形（分隔条和留白不算）。遮罩拿它判两件事：
    /// 按下落在按钮上还是空白处，以及该让光标表达「这里能拖」。
    var actionableRects: [NSRect] {
        entries.compactMap { entry in
            guard let item = entry.view as? ScreenshotToolbarItem, item.action != nil else { return nil }
            return item.frame
        }
    }

    /// 遮罩坐标里这一点是否按在可点元素上。条子和遮罩同为 flipped 视图、无缩放，
    /// 所以换坐标只剩平移，不必绕 `convert`（单测直接喂遮罩坐标，没有 superview）。
    func hasActionable(atOverlayPoint point: NSPoint) -> Bool {
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return actionableRects.contains { $0.contains(local) }
    }

    /// 遮罩坐标里这一点停在哪个格子上、该提示什么。空白处和分隔条答 nil。
    /// 灭着的格子（撤销/重做/识别中）照样答：用户正因为按不动它，才更需要知道它是干什么的。
    func tip(atOverlayPoint point: NSPoint) -> (text: String, cell: NSRect)? {
        for entry in entries {
            guard let item = entry.view as? ScreenshotToolbarItem,
                  item.action != nil, !item.tipText.isEmpty else { continue }
            let cell = item.frame.offsetBy(dx: frame.minX, dy: frame.minY)
            if cell.contains(point) { return (item.tipText, cell) }
        }
        return nil
    }

    /// 条子上每个可点格子各自提示什么，按从左到右的顺序（分隔条和留白不算）。
    ///
    /// 取证用它核对「一格不落、一重不撞」：漏写某格的文案，在代码里就是少传一个参数，
    /// 编译器和肉眼都发现不了；两格串了同一段话（复制粘贴漏改）更是只有对着这张表比
    /// 才看得出来。
    var tipsOnBar: [(id: String, text: String)] {
        entries.compactMap { entry in
            guard let item = entry.view as? ScreenshotToolbarItem,
                  item.action != nil, !item.id.isEmpty else { return nil }
            return (item.id, item.tipText)
        }
    }

    /// 空白处一律放行给遮罩：拖整条这条路要和其他拖动（把手/平移/画注解）走同一棵
    /// 判定树，NSEvent 造不出来，只有收进 `pointerDown` 才验得动。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, hasActionable(atOverlayPoint: point) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = ToolbarStyle.resolved(for: effectiveAppearance)
        style.barFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        style.barBorder.setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 12, yRadius: 12)
        edge.lineWidth = 1
        edge.stroke()
    }

    /// 用户可能在截图还挂着的时候切明暗（系统设置里点一下就换）：整条重画一次，
    /// 否则底衬跟着外观翻了、图标还是上一档墨色。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        subviews.forEach { $0.needsDisplay = true }
    }

    // MARK: - 装配

    private func build() {
        // 顺序照 QQ 那条：形状类 → 贴图/裁剪 → 颜色与线宽 → 撤销/重做 → 出口。
        let tools: [(ScreenshotTool, ScreenshotToolbarItem.Glyph)] = [
            (.rect, .symbol("rectangle")),
            (.ellipse, .symbol("circle")),
            (.arrow, .symbol("arrow.up.right")),
            (.pen, .symbol("pencil")),
            (.text, .symbol("character")),
            (.number, .symbol("1.circle")),
            (.mosaic, .checkerboard),
        ]
        for (tool, glyph) in tools {
            // 提示文案取自 `ScreenshotTool.title`：偏好页那一格下拉读的是同一份，
            // 两边各写一遍就会改一处漏一处。
            let item = iconCell("tool.\(tool)", glyph, tool.title) { [weak self] in self?.onTool?(tool) }
            toolItems[tool] = item
        }
        addSeparator()

        iconCell("pin", .symbol("pin"), L("Screenshot Pin")) { [weak self] in self?.onPin?() }
        iconCell("crop", .symbol("crop"), L("Screenshot Crop")) { [weak self] in self?.onCrop?() }
        // QQ 那枚「虚线框 A」= 识别文字。`text.viewfinder` 就是系统里这个画法（虚线取景框
        // 里一个 A），不用自绘。
        ocrItem = iconCell("ocr", .symbol("text.viewfinder"), L("Screenshot OCR")) { [weak self] in
            self?.onOCR?()
        }
        addSeparator()

        for (index, color) in Self.palette.enumerated() {
            let item = ScreenshotToolbarItem(glyph: .swatch(color), width: Self.optionItemWidth,
                                             id: "color", toolTip: L("Screenshot Color")) { [weak self] in
                self?.onColor?(index)
            }
            colorItems[index] = item
            append(item, width: Self.optionItemWidth)
        }
        for (index, width) in Self.lineWidths.enumerated() {
            let item = ScreenshotToolbarItem(glyph: .stroke(width), width: Self.optionItemWidth,
                                             id: "width", toolTip: L("Screenshot Line Width")) { [weak self] in
                self?.onWidth?(index)
            }
            widthItems[index] = item
            append(item, width: Self.optionItemWidth)
        }
        addSeparator()

        undoItem = iconCell("undo", .symbol("arrow.uturn.backward"), L("Screenshot Undo")) { [weak self] in
            self?.onUndo?()
        }
        redoItem = iconCell("redo", .symbol("arrow.uturn.forward"), L("Screenshot Redo")) { [weak self] in
            self?.onRedo?()
        }
        addSeparator()

        iconCell("save", .symbol("square.and.arrow.down"), L("Screenshot Save")) { [weak self] in
            self?.onSave?()
        }
        // 红✕ discard、绿✓ 出图：QQ 把这两个出口染成各自的语义色，靠颜色而不是位置
        // 告诉用户哪一枚是「算了」。
        iconCell("cancel", .symbol("xmark"), L("Screenshot Cancel"), tintRole: .cancel) { [weak self] in
            self?.onCancel?()
        }
        iconCell("copy", .symbol("checkmark"), L("Screenshot Copy"), tintRole: .confirm) { [weak self] in
            self?.onCopy?()
        }

        preferredWidth = entries.reduce(Self.edgePadding * 2) { $0 + $1.width + Self.gap }
        // 立刻排一次：`actionableRects` 要在还没走过布局的条子上也答得对 ——
        // 遮罩靠它判「这一下按的是按钮还是空白」，答错了点按钮会变成拖整条。
        placeItems()
    }

    /// 一个图标格。`tintRole` 只给那几个靠自身颜色表意的出口，其余跟着条子的墨色走。
    @discardableResult
    private func iconCell(_ id: String, _ glyph: ScreenshotToolbarItem.Glyph, _ tip: String,
                          tintRole: ToolbarStyle.Role? = nil,
                          action: @escaping () -> Void) -> ScreenshotToolbarItem {
        let item = ScreenshotToolbarItem(glyph: glyph, width: Self.iconItemWidth,
                                         id: id, toolTip: tip, tintRole: tintRole, action: action)
        append(item, width: Self.iconItemWidth)
        return item
    }

    private func append(_ view: NSView, width: CGFloat) {
        view.frame = NSRect(x: 0, y: (Self.barHeight - Self.itemHeight) / 2,
                            width: width, height: Self.itemHeight)
        entries.append((view, width))
        addSubview(view)
    }

    private func addSeparator() {
        let view = ScreenshotToolbarItem(glyph: .separator, width: Self.separatorWidth)
        view.frame = NSRect(x: 0, y: 0, width: Self.separatorWidth, height: Self.barHeight)
        entries.append((view, Self.separatorWidth))
        addSubview(view)
    }

    override func layout() {
        super.layout()
        placeItems()
    }

    /// 元素横向铺开、垂直居中。分隔条占满条子高度，其余按 itemHeight。
    private func placeItems() {
        var x = Self.edgePadding
        for entry in entries {
            entry.view.frame.origin = NSPoint(x: x, y: (Self.barHeight - entry.view.frame.height) / 2)
            x += entry.width + Self.gap
        }
    }

    /// 只反映「现在选中了什么」，状态真相都在遮罩视图那边。
    func sync(activeTool: ScreenshotTool?, colorIndex: Int, widthIndex: Int,
              canUndo: Bool, canRedo: Bool, canOCR: Bool) {
        for (tool, item) in toolItems { item.isActive = tool == activeTool }
        for (index, item) in colorItems { item.isActive = index == colorIndex }
        for (index, item) in widthItems { item.isActive = index == widthIndex }
        undoItem?.isEnabled = canUndo
        redoItem?.isEnabled = canRedo
        // 识别在后台跑，跑完之前再点一次就是让 Vision 同时算两遍、结果谁后到还不一定。
        ocrItem?.isEnabled = canOCR
        needsLayout = true
    }
}
