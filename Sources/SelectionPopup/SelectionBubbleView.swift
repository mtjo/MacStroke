//
//  SelectionBubbleView.swift
//  MacStroke
//
//  气泡本体：一枚胶囊 + 四格（复制 / 搜索 / 翻译 / 朗读）。
//
//  自绘而不是 NSStackView + NSButton：这层是 borderless 的浮窗，标准按钮的 bezel 在里面
//  会渲染成系统设置里那种灰块（同一个结论在截图注解条上先踩过，见
//  `Sources/Screenshot/ScreenshotToolbar.swift` 开头那段）。
//
//  底衬和墨色**跟随系统外观**，语义色在 `draw` 之前按视图外观解析成具体 sRGB —— 离屏取证走
//  `cacheDisplay`，那条路只重放视图自己的绘制代码：layer 的 backgroundColor、image view 的
//  tintColor 都不在里面，而图形上下文带的外观和视图的不一定是同一个。
//
//  没有悬停提示气泡：这一层只待 6 秒，为它再铺一层跟着鼠标的小气泡是自找麻烦。四格靠图标
//  表意，`tip` 只写进无障碍标签，读屏软件和取证都读得到。
//
//  也没有 Esc：焦点根本不在我们这（面板是 nonactivating 的，前台还是那个文本 App），Esc 归
//  那个 App。关掉气泡靠点别处、切 App、或等它自己收。
//

import AppKit
import Storage

/// 气泡上的一格。
struct SelectionBubbleItem: Equatable {
    /// 这一格是干什么的。取证按它核对顺序和存在性 —— 文案会随语言变，这个不会。
    let id: String
    /// SF Symbol 名。系统版本不带这个 symbol 时退化成问号，好过胶囊上出现一块空白。
    let symbol: String
    /// 无障碍标签（本地化后的文字）。
    let tip: String

    init(id: String, symbol: String, tip: String) {
        self.id = id
        self.symbol = symbol
        self.tip = tip
    }
}

extension SelectionBubbleItem {
    /// 一格长什么样：图标和文案都取自 `SelectionBubbleAction` 那份定义，这里不再抄一遍。
    init(action: SelectionBubbleAction) {
        self.id = action.rawValue
        self.symbol = action.symbol
        self.tip = L(action.titleKey)
    }

    /// 四格全开时的顺序（取证用例用它当基准）。
    static let defaultItems: [SelectionBubbleItem] = SelectionBubbleAction.allCases.map(SelectionBubbleItem.init)

    /// 按偏好里打开的那几格摆出来，顺序仍走 `SelectionBubbleAction.allCases`。
    static func items(for actions: [SelectionBubbleAction]) -> [SelectionBubbleItem] {
        actions.map(SelectionBubbleItem.init)
    }
}

/// 浮层配色。写法照 `ToolbarStyle`：语义色按外观解析成具体值再缓存，两档各一份。
struct BubbleStyle {
    let fill: NSColor
    let border: NSColor
    let glyph: NSColor
    /// 被按下那一格的底：比墨色淡一档，点下去要看得见。
    let pressed: NSColor

    private static var cache: [NSAppearance.Name: BubbleStyle] = [:]

    static func resolved(for appearance: NSAppearance) -> BubbleStyle {
        if let hit = cache[appearance.name] { return hit }
        let made = BubbleStyle(
            fill: concrete(.windowBackgroundColor, in: appearance).withAlphaComponent(0.96),
            border: concrete(.separatorColor, in: appearance),
            glyph: concrete(.labelColor, in: appearance),
            pressed: concrete(.quaternaryLabelColor, in: appearance)
        )
        cache[appearance.name] = made
        return made
    }

    /// 先在 `performAsCurrentDrawingAppearance` 里把语义色固化，之后 `setFill()` 拿到的是常量。
    private static func concrete(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolvedColor = color
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.sRGB) ?? color
        }
        return resolvedColor
    }
}

/// 一格：图标 + 自己的按下态。
final class SelectionBubbleCell: NSView {
    let item: SelectionBubbleItem
    private let action: () -> Void
    private var isPressed = false { didSet { needsDisplay = true } }
    private let template: NSImage?
    private var tinted: [NSColor: NSImage] = [:]

    init(item: SelectionBubbleItem, frame: NSRect, action: @escaping () -> Void) {
        self.item = item
        self.action = action
        self.template = SelectionBubbleCell.templateImage(item.symbol)
        super.init(frame: frame)
        setAccessibilityLabel(item.tip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = BubbleStyle.resolved(for: effectiveAppearance)
        if isPressed {
            style.pressed.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
        }
        guard let image = image(for: style.glyph) else { return }
        // 按原尺寸居中：draw(in:) 会把图铺满给定矩形，直接喂 bounds 就成拉扁的大图标。
        let side = min(image.size.width, bounds.width - 8)
        let ratio = side / max(image.size.width, 1)
        let box = CGRect(x: bounds.midX - side / 2, y: bounds.midY - image.size.height * ratio / 2,
                         width: side, height: image.size.height * ratio)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        // 必须自己把按下吃掉：不实现就顺着 responder chain 冒到胶囊，那点被当成「按在空白处」，
        // 用户点一下格子顺带把整枚气泡点没了。同一个坑在截图注解条上见过。
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
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

    private static func templateImage(_ name: String) -> NSImage? {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)
        base?.isTemplate = true
        return base?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }
}

/// 胶囊本体：底 + 边框 + 四格。
final class SelectionBubbleView: NSView {
    private let items: [SelectionBubbleItem]
    /// 此刻摆出来的格子 id（按左到右顺序）。取证用它核对，不看文案。
    private(set) var cellIDs: [String] = []

    init(items: [SelectionBubbleItem]) {
        self.items = items
        super.init(frame: NSRect(origin: .zero, size: SelectionBubbleLayout.capsuleSize(cellCount: items.count)))
        buildCells()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// 点格子之后要做的事由外面接，视图自己不认识剪贴板、浏览器和语音合成。
    var onAction: ((String) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let style = BubbleStyle.resolved(for: effectiveAppearance)
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        style.fill.setFill()
        body.fill()
        style.border.setStroke()
        body.lineWidth = 1
        body.stroke()
    }

    private func buildCells() {
        let count = items.count
        for (index, item) in items.enumerated() {
            let cell = SelectionBubbleCell(item: item,
                                           frame: SelectionBubbleLayout.cellFrame(index: index, cellCount: count)) { [weak self] in
                self?.onAction?(item.id)
            }
            addSubview(cell)
            cellIDs.append(item.id)
        }
    }
}
