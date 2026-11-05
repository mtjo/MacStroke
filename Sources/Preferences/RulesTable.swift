//
//  RulesTable.swift
//  MacStroke
//
//  The rules list rendered the way the original renders it: a view-based
//  NSTableView whose 84pt rows host a live control in every cell
//  (AppPrefsWindowController.m `tableViewForRules:row:`).
//

import AppKit
import SwiftUI
import GestureEngine
import RuleEngine
import Storage
import AppleScriptRunner

/// NSComboBox that reports its own selection changes. The original registers an
/// `NSComboBoxSelectionDidChangeNotification` observer per combo box; a subclass
/// keeps the observer's lifetime tied to the control.
final class CallbackComboBox: NSComboBox {
    var onSelectionChange: ((Int) -> Void)?

    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observer = NotificationCenter.default.addObserver(
            forName: NSComboBox.selectionDidChangeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self, let onSelectionChange = self.onSelectionChange else { return }
            let index = self.indexOfSelectedItem
            if index >= 0 { onSelectionChange(index) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// NSView port of the original `DrawGesture` cell view: a 60pt canvas, centred
/// on the short axis, offset 12pt to the bottom right, with a per-segment colour
/// ramp of `(0.5t, 0.47 + 0.53t, 0.9)` where `t = index / points.count`.
final class GestureThumbView: NSView {
    var points: [CGPoint] = [] {
        didSet { needsDisplay = true }
    }

    /// Original `mouseDown:` only reacts to a double click, opening the same
    /// preset-gesture modal as the "Draw Gesture" button.
    var onDoubleClick: (() -> Void)?

    /// Hovering replays the drawing order — the only way to tell a gesture apart
    /// from its reversed twin, whose static thumbnail is the same shape.
    private lazy var replay = GestureReplayAnimator(view: self)
    private var trackingArea: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let width = abs(maxX - minX)
        let height = abs(maxY - minY)
        let canvas = 60.0
        let zoom = max(width / canvas, height / canvas)
        guard zoom > 0 else { return }
        let fixX = (width < height ? (canvas - width / zoom) / 2 : 0) + 12
        let fixY = (width > height ? (canvas - height / zoom) / 2 : 0) + 12
        let scaled = points.map { point in
            CGPoint(x: (point.x - minX) / zoom + fixX, y: (point.y - minY) / zoom + fixY)
        }
        GestureStrokeRenderer.draw(scaled, progress: replay.progress)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        replay.start()
    }

    override func mouseExited(with event: NSEvent) {
        replay.stop()
    }
}

/// 规则页里滚轮档的手势格：图标 + 一行读法，双击同样打开选择面板。
/// 没有轨迹点可比，所以它不画 `GestureThumbView`，也没有回放可言。
final class InstantGestureThumbView: NSView {
    let gesture: InstantGesture
    var onDoubleClick: (() -> Void)?

    init(gesture: InstantGesture, frame: NSRect) {
        self.gesture = gesture
        super.init(frame: frame)
        let label = NSTextField(labelWithString: L(gesture.locKey))
        // 10pt：五档里最长的那句（英文 "Forward Button"）在 84pt 的格子里 11pt 会被截尾。
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = WheelGestureGlyph.cellLabelRect(in: frame)
        // 不加任何 autoresizing：规则表拿回容器后还会改一次它的尺寸（初值是零），
        // 比例自适应会把这行字连同图标一起放大一倍、顶出格外（2026-11-03 实测）。
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        WheelGestureGlyph.draw(gesture, in: WheelGestureGlyph.cellGlyphRect(in: bounds))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

/// 规则表每一格的容器：列宽变化时把可拉伸的那个控件铺满格子。
///
/// 格子里原来全是固定帧（Gesture 100、Filter 160、Note 400），列一窄控件就按
/// 自己的初值画出去、被表格裁掉。不能用 `autoresizingMask` 修：容器是被表格从
/// 零尺寸改成列宽的，比例自适应会把 100pt 的框直接放大成「100 + 列宽」。
/// 这里按容器的 `bounds` 记账，与它此前多宽无关。
final class RuleCellContainer: NSView {
    /// 跟着列宽走的那个控件；nil 表示格子里是固定尺寸的缩略图或按钮。
    weak var stretchable: NSView? {
        didSet { layoutContent() }
    }

    private let horizontalInset: CGFloat = 2

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    /// 固定尺寸的格子水平居中，宽度不动 —— 手势缩略图必须保持 84pt 见方，
    /// 它的绘制坐标系不随外框缩放。
    private func layoutContent() {
        guard let stretchable else {
            for subview in subviews {
                subview.frame.origin.x = max(0, (bounds.width - subview.frame.width) / 2)
            }
            return
        }
        var frame = stretchable.frame
        frame.origin.x = horizontalInset
        frame.size.width = max(0, bounds.width - horizontalInset * 2)
        stretchable.frame = frame
    }
}

/// 规则表的滚动容器：窗口变窄时按比例收六列（到各自下限为止），再窄才横向滚。
///
/// 列宽不交给 `NSTableView` 自己收：`.uniformColumnAutoresizingStyle` 只在表格
/// **变宽**时分摊多出来的宽度，视口比列宽总和窄时表格保持建表宽度（2026-11-04
/// 实测：544pt 视口下六列仍是 741.85pt，最后一列直接落到视口外）。这里按可视宽度
/// 算一次列宽，再把表格宽度对到总和，横向滚动条只在六列触底后出现。
///
/// 分配前要扣掉 AppKit 给每列加的那圈余量：表格的每列帧是「列宽 + intercell
/// 间隔」，外加左右留白，六列实测多出 117pt。只按列宽总和去凑视口，最后一列
/// 连同表头会顶出可视区（2026-11-04 实拍 563pt 视口下表头只剩一个 “D”）。
final class RulesTableScrollView: NSScrollView {
    private weak var rulesTable: NSTableView?
    /// 建表时的列宽作为分配权重，必须在这里存一份：每次布局都改列宽，
    /// 若拿"当前列宽"当权重，下一轮会在已经收窄的宽度上再乘一次比例。
    private var defaultWidths: [CGFloat] = []
    private var minimumWidths: [CGFloat] = []
    /// 列宽之外 AppKit 固定占用的宽度（列间间隔 + 两侧留白）。不随列宽变化，
    /// 建表时量一次即可。
    private var columnOverhead: CGFloat = 0

    init(table: NSTableView, frame: NSRect = .zero) {
        super.init(frame: frame)
        rulesTable = table
        defaultWidths = table.tableColumns.map(\.width)
        minimumWidths = table.tableColumns.map(\.minWidth)
        documentView = table
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder

        // `tile()` 把表格宽度对到「列宽总和 + AppKit 的余量」，两者一减就是余量。
        table.tile()
        let columnTotal = table.tableColumns.map(\.width).reduce(0, +)
        columnOverhead = max(0, table.frame.width - columnTotal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        fitColumns()
    }

    private func fitColumns() {
        guard let table = rulesTable, !defaultWidths.isEmpty else { return }
        let viewport = contentSize.width
        guard viewport > 0 else { return }

        let widths = RulesTable.fittedColumnWidths(available: viewport - columnOverhead,
                                                   defaults: defaultWidths,
                                                   minima: minimumWidths)
        for (column, width) in zip(table.tableColumns, widths)
        where abs(column.width - width) > 0.5 {
            column.width = width
        }
        let total = widths.reduce(0, +) + columnOverhead
        let target = max(total, viewport)
        if abs(table.frame.width - target) > 0.5 {
            table.frame.size.width = target
        }
    }
}

/// The original rules table: six columns, 84pt rows, one live control per cell.
struct RulesTable: NSViewRepresentable {
    @ObservedObject var store: RuleStore
    @Binding var selectedRow: Int
    /// Runs the "Draw Gesture!" modal for the rule at a row index.
    var onDrawGesture: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onDrawGesture: onDrawGesture)
    }

    /// 表格本体的配置（行高、列、窄窗自适应）。单独抽出来，是为了让离屏用例
    /// 拿到的表格和真页面上的那一只**由同一段代码配出来**，而不是在用例里重抄一遍。
    /// 数据源/代理由调用方接；列宽由 `RulesTableScrollView` 按视口分配。
    static func makeTable() -> NSTableView {
        let table = NSTableView()
        table.rowHeight = 84
        table.usesAlternatingRowBackgroundColors = true
        // 列宽不交给 NSTableView 自己做：`.uniformColumnAutoresizingStyle` 只在表格
        // 变宽时分摊多出来的宽度，视口比列宽总和窄时它保持建表宽度（实测 544pt
        // 视口下六列仍是 741.85pt，最后一列落到视口外）。改由滚动容器统一记账。
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autoresizingMask = [.width]
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsEmptySelection = true
        Coordinator.makeColumns().forEach(table.addTableColumn)
        return table
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.selectedRow = $selectedRow
        coordinator.onDrawGesture = onDrawGesture

        let table = Self.makeTable()
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table

        return RulesTableScrollView(table: table)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selectedRow = $selectedRow
        context.coordinator.onDrawGesture = onDrawGesture
        context.coordinator.reloadIfNeeded()
    }
}

extension RulesTable {
    /// 把六列分配到可视宽度里：放得下就按建表宽度等比缩放；比例分法让窄列先
    /// 触底，触底的列钉在最小值，剩下的宽度再按比例分给其余列；视口比所有
    /// 最小值之和还窄时就返回最小值（调用方据此把表格撑开、横向滚动）。
    static func fittedColumnWidths(available: CGFloat,
                                   defaults: [CGFloat],
                                   minima: [CGFloat]) -> [CGFloat] {
        guard defaults.count == minima.count, !defaults.isEmpty, available > 0 else {
            return defaults
        }
        let defaultTotal = defaults.reduce(0, +)
        guard defaultTotal > 0 else { return defaults }
        let minimumTotal = minima.reduce(0, +)
        if available <= minimumTotal { return minima }
        if available >= defaultTotal {
            let scale = available / defaultTotal
            return defaults.map { $0 * scale }
        }

        var widths = defaults
        var free = Set(defaults.indices)
        while !free.isEmpty {
            let fixedTotal = defaults.indices
                .filter { !free.contains($0) }
                .reduce(CGFloat(0)) { $0 + widths[$1] }
            let weight = free.reduce(CGFloat(0)) { $0 + defaults[$1] }
            guard weight > 0 else { break }
            let scale = (available - fixedTotal) / weight
            let clamped = free.filter { defaults[$0] * scale < minima[$0] }
            if clamped.isEmpty {
                for index in free { widths[index] = defaults[index] * scale }
                return widths
            }
            for index in clamped {
                widths[index] = minima[index]
                free.remove(index)
            }
        }
        return widths
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                             NSTextFieldDelegate, NSComboBoxDataSource {
        static let placeholder = "Double click Modify"

        let store: RuleStore
        var onDrawGesture: (Int) -> Void
        var selectedRow: Binding<Int>?
        weak var table: NSTableView?

        /// Field edits are committed through the delegate, so a reload while a
        /// cell field is being typed into would throw away the field editor.
        private var isEditing = false
        private var signature = ""
        private var reloadedRowCount: Int?

        init(store: RuleStore, onDrawGesture: @escaping (Int) -> Void) {
            self.store = store
            self.onDrawGesture = onDrawGesture
        }

        // MARK: Columns

        static func makeColumns() -> [NSTableColumn] {
            // minWidth 取「这一格里的控件再小就没法用」的下限：手势缩略图固定
            // 84pt 见方，手势名和动作类型下拉要露全「PageDown」「Hot Key」，
            // 文本框至少要露出几个字。六列最小值 438pt + AppKit 的列间余量
            // 117pt = 555pt，塞进最小窗口下的表格视口（实测 563pt）；再窄才横向滚。
            let specs: [(identifier: String, title: String, width: Double, minWidth: Double)] = [
                ("Gesture_Image", L("Image"), 84, 84),
                ("Gesture", L("Gesture"), 98, 70),
                ("Type", L("Type"), 96, 78),
                ("Action", L("Action"), 104, 74),
                ("Filter", L("Filter"), 138.8515625, 50),
                ("Note", L("Description"), 221, 82),
            ]
            return specs.map { spec in
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.identifier))
                column.title = spec.title
                column.width = spec.width
                column.minWidth = spec.minWidth
                column.maxWidth = 1000
                column.headerCell.alignment = .center
                return column
            }
        }

        /// Hot Key / Apple Script / Text / Password, in the original combo order
        /// (which is also the persisted `actionType` numbering), plus the port's
        /// screenshot trigger and the two volume steps.
        static var typeTitles: [String] {
            [L("Hot Key"), L("Apple Script"), L("Text"), L("Password"),
             L("Screenshot"), L("Volume Up"), L("Volume Down")]
        }

        // MARK: Reload

        func reloadIfNeeded() {
            guard !isEditing, signature != currentSignature() else { return }
            signature = currentSignature()
            // The first reload only fills the table; a later one that grows it
            // means "+" appended a rule at the bottom, off-screen on a long list.
            let appended = reloadedRowCount.map { store.rules.count > $0 } ?? false
            reloadedRowCount = store.rules.count
            table?.reloadData()
            if appended, let last = store.rules.indices.last {
                table?.scrollRowToVisible(last)
            }
            publishSelection()
        }

        /// Force a rebuild even while a field editor is open (the original calls
        /// `reloadData` after the action type or the gesture changes).
        func forceReload() {
            signature = currentSignature()
            reloadedRowCount = store.rules.count
            table?.reloadData()
            publishSelection()
        }

        private func currentSignature() -> String {
            store.rules.map { rule in
                let spare = rule.spareActions
                return "\(rule.name)\u{1}\(rule.note)\u{1}\(rule.filter)\u{1}"
                    + "\(rule.template.points.count)\u{1}\(Self.typeIndex(for: rule.action))\u{1}"
                    + "\(spare.text)\u{1}\(spare.password)\u{1}\(spare.appleScriptId)\u{1}"
                    + "\(rule.instantGesture?.rawValue ?? "")"
            }.joined(separator: "\u{2}")
        }

        private func publishSelection() {
            let row = table?.selectedRow ?? -1
            guard let selectedRow, selectedRow.wrappedValue != row else { return }
            // Reloads run inside a SwiftUI view update; writing the binding there
            // is undefined behaviour, so hand it to the next runloop turn.
            DispatchQueue.main.async { selectedRow.wrappedValue = row }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            store.rules.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            84
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            true
        }

        // MARK: Cell views

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier.rawValue,
                  let rule = rule(at: row) else { return nil }
            let container = RuleCellContainer()
            switch identifier {
            case "Gesture_Image":
                addGestureCell(to: container, rule: rule, row: row)
            case "Gesture", "Filter", "Note":
                addTextCell(to: container, identifier: identifier, rule: rule, row: row)
            case "Type":
                addTypeCell(to: container, rule: rule, row: row)
            case "Action":
                addActionCell(to: container, rule: rule, row: row)
            default:
                break
            }
            return container
        }

        private func addGestureCell(to container: RuleCellContainer, rule: Rule, row: Int) {
            // 滚轮档优先于「有没有轨迹点」：这类规则压根不画笔画。
            if let instant = rule.instantGesture {
                let thumb = InstantGestureThumbView(
                    gesture: instant, frame: NSRect(x: 0, y: 0, width: 84, height: 84))
                // 固定帧、不要 autoresizing：容器交回表格后会被从零尺寸改成 84×84，
                // `[.width, .height]` 比例自适应把格子放大成 168×168，图标被顶出
                // 格子上沿、只剩一半可见（2026-11-03 实测，见 WheelRuleGestureGlyphTests）。
                thumb.onDoubleClick = { [weak self] in self?.onDrawGesture(row) }
                container.addSubview(thumb)
                return
            }
            guard !rule.template.points.isEmpty else {
                // Original: an empty trajectory renders a "Draw Gesture" button
                // instead of the canvas.
                let button = NSButton(frame: NSRect(x: 0, y: 28, width: 80, height: 25))
                button.tag = row
                button.bezelStyle = .texturedSquare
                button.title = L("Draw Gesture")
                button.target = self
                button.action = #selector(drawGestureClicked(_:))
                container.addSubview(button)
                return
            }
            // 固定帧、不要 autoresizing：容器是被表格从零尺寸改成列宽的，
            // 比例自适应会把 84pt 的画布跟着放大一倍（和滚轮档同一个坑）。
            let thumb = GestureThumbView(frame: NSRect(x: 0, y: 0, width: 84, height: 84))
            thumb.points = rule.template.points.map { CGPoint(x: $0.x, y: $0.y) }
            thumb.onDoubleClick = { [weak self] in self?.onDrawGesture(row) }
            container.addSubview(thumb)
        }

        private func addTextCell(to container: RuleCellContainer, identifier: String, rule: Rule, row: Int) {
            let width: CGFloat
            let value: String
            switch identifier {
            case "Gesture":
                width = 100
                value = rule.name
            case "Filter":
                width = 160
                value = rule.filter
            default:
                width = 400
                value = rule.note
            }
            let field = makeField(identifier: identifier, value: value, row: row, width: width)
            container.addSubview(field)
            container.stretchable = field
        }

        private func addTypeCell(to container: RuleCellContainer, rule: Rule, row: Int) {
            let combo = CallbackComboBox(frame: NSRect(x: 0, y: 25, width: 90, height: 27))
            combo.isEditable = false
            combo.completes = false
            combo.tag = row
            combo.addItems(withObjectValues: Self.typeTitles)
            let current = Self.typeIndex(for: rule.action)
            combo.selectItem(at: current)
            combo.onSelectionChange = { [weak self] index in
                guard index != current else { return }
                self?.changeActionType(row: row, to: index)
            }
            container.addSubview(combo)
            container.stretchable = combo
        }

        private func addActionCell(to container: RuleCellContainer, rule: Rule, row: Int) {
            let index = Self.typeIndex(for: rule.action)
            switch index {
            case 0:
                let recorder = ShortcutRecorderView()
                recorder.frame = NSRect(x: 0, y: 27, width: 100, height: 25)
                // 这一格不给清除按钮：动作存的是「要按下哪个键」，(0,0) 在模型里是
                // 「按下 A」而不是「没有」，置空等于给规则塞进一个会打字键的动作。
                recorder.showsClearButton = false
                let (keyCode, flags) = shortcutValue(of: rule)
                recorder.keyCode = keyCode
                recorder.flags = flags
                recorder.onShortcutChanged = { [weak self] code, modifierFlags in
                    self?.setShortcut(row: row, keyCode: code, flags: modifierFlags)
                }
                container.addSubview(recorder)
                container.stretchable = recorder
            case 1:
                let combo = CallbackComboBox(frame: NSRect(x: 0, y: 27, width: 100, height: 25))
                combo.isEditable = false
                combo.completes = false
                combo.usesDataSource = true
                combo.dataSource = self
                combo.tag = row
                let scriptID = scriptID(of: rule)
                let current = UUID(uuidString: scriptID).flatMap(AppleScriptsList.sharedAppleScriptsList.index(of:)) ?? -1
                if current >= 0 { combo.selectItem(at: current) }
                combo.onSelectionChange = { [weak self] index in
                    guard index != current else { return }
                    self?.setAppleScript(row: row, itemIndex: index)
                }
                container.addSubview(combo)
                container.stretchable = combo
            case 2:
                let field = makeField(identifier: "Text", value: textValue(of: rule),
                                      row: row, width: 100)
                container.addSubview(field)
                container.stretchable = field
            case 4:
                // 截图动作没有参数可填，格子里只写清它会做什么。
                let label = Self.makeStaticActionLabel(L("Screenshot"))
                container.addSubview(label)
                container.stretchable = label
            case 5, 6:
                // 音量档位同理：一格就是 ±5%，没有可填的东西，只写清是加还是减。
                let label = Self.makeStaticActionLabel(
                    index == 5 ? L("Volume Up") : L("Volume Down"))
                container.addSubview(label)
                container.stretchable = label
            default:
                let field = makeField(identifier: "Password", value: passwordValue(of: rule),
                                      row: row, width: 100)
                container.addSubview(field)
                container.stretchable = field
            }
        }

        /// 无参数动作（截图）的 Action 格：一句话说明，不给可编辑框。
        private static func makeStaticActionLabel(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: 30, width: 100, height: 20)
            field.alignment = .center
            field.textColor = .secondaryLabelColor
            return field
        }

        private func makeField(identifier: String, value: String, row: Int, width: CGFloat) -> NSTextField {
            let frame = NSRect(x: 0, y: 30, width: width, height: 20)
            let field: NSTextField = identifier == "Password"
                ? NSSecureTextField(frame: frame)
                : NSTextField(frame: frame)
            field.isEditable = true
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = true
            field.bezelStyle = .squareBezel
            field.lineBreakMode = .byTruncatingTail
            field.cell?.wraps = true
            field.cell?.isScrollable = true
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.tag = row
            field.stringValue = value
            field.delegate = self
            return field
        }

        // MARK: AppleScript combo data source (original comboBox:objectValueForItemAtIndex:)

        func numberOfItems(in comboBox: NSComboBox) -> Int {
            AppleScriptsList.sharedAppleScriptsList.count
        }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            guard index < AppleScriptsList.sharedAppleScriptsList.count else { return nil }
            return AppleScriptsList.sharedAppleScriptsList.title(at: index)
        }

        // MARK: Field editing (original control:textShouldEndEditing:)

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            defer { isEditing = false }
            guard let control = obj.object as? NSControl,
                  let identifier = control.identifier?.rawValue else { return }
            let row = control.tag
            let value = (control as? NSTextField)?.stringValue ?? ""
            switch identifier {
            case "Gesture":
                write(row) { $0.renamed(to: value) }
            case "Filter":
                // Original setWildFilter:atIndex: also forces the type back to wildcard.
                write(row) { $0.withFilter(value) }
            case "Note":
                write(row) { $0.withNote(value) }
            case "Text":
                write(row) { $0.withText(value) }
            case "Password":
                write(row) { $0.withPassword(value) }
            default:
                // The original ends every text-edit commit with an unconditional
                // save of both lists, even for identifiers it does not handle.
                break
            }
            signature = currentSignature()
        }

        // MARK: Cell actions

        @objc private func drawGestureClicked(_ sender: NSButton) {
            onDrawGesture(sender.tag)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            publishSelection()
        }

        private func changeActionType(row: Int, to index: Int) {
            // Original setActionTypeWithActionType: only rewrites actionType, so
            // whatever was typed for the other types survives.
            write(row) { $0.withActionType(index) }
            forceReload()
        }

        private func setShortcut(row: Int, keyCode: UInt16, flags: UInt) {
            // Original setShortcutWithKeycode:withFlag:atIndex: also pins the type
            // to Hot Key and saves.
            write(row) { $0.withShortcut(keyCode: keyCode, flags: flags) }
            signature = currentSignature()
        }

        private func setAppleScript(row: Int, itemIndex: Int) {
            let list = AppleScriptsList.sharedAppleScriptsList
            guard itemIndex < list.count else { return }
            write(row) { $0.withAppleScript(id: list.id(at: itemIndex).uuidString) }
            signature = currentSignature()
        }

        // MARK: Rule values

        private func rule(at row: Int) -> Rule? {
            store.rules.indices.contains(row) ? store.rules[row] : nil
        }

        private func write(_ row: Int, _ transform: (Rule) -> Rule) {
            guard let old = rule(at: row) else { return }
            store.rules[row] = transform(old)
            store.save()
            AppleScriptsList.sharedAppleScriptsList.save()
        }

        static func typeIndex(for action: RuleAction) -> Int {
            switch action {
            case .applescript: return 1
            case .text, .copyToClipboard: return 2
            case .password: return 3
            case .screenshot: return 4
            case .volumeUp: return 5
            case .volumeDown: return 6
            default: return 0
            }
        }

        private func shortcutValue(of rule: Rule) -> (UInt16, UInt) {
            if case .shortcut(let keyCode, let flags) = rule.action { return (keyCode, flags) }
            return (UInt16(truncatingIfNeeded: rule.spareActions.shortcutCode),
                    UInt(truncatingIfNeeded: rule.spareActions.shortcutFlag))
        }

        private func scriptID(of rule: Rule) -> String {
            if case .applescript(let reference) = rule.action,
               UUID(uuidString: reference) != nil { return reference }
            return rule.spareActions.appleScriptId
        }

        private func textValue(of rule: Rule) -> String {
            switch rule.action {
            case .text(let value), .copyToClipboard(let value): return value
            default: return rule.spareActions.text
            }
        }

        private func passwordValue(of rule: Rule) -> String {
            if case .password(let value) = rule.action { return value }
            return rule.spareActions.password
        }
    }
}

/// Per-column writes on an otherwise immutable `Rule`: every field lives in its
/// own slot of the original rule dictionary, so editing one never touches the
/// values held for the other action types.
private extension Rule {
    func renamed(to newName: String) -> Rule {
        copying(name: newName)
    }

    func withNote(_ value: String) -> Rule {
        copying(note: value)
    }

    func withFilter(_ value: String) -> Rule {
        // Original setWildFilter:atIndex: also forces the type back to wildcard.
        copying(filter: value, filterType: "wildcard")
    }

    func withText(_ value: String) -> Rule {
        var spare = spareActions
        spare.text = value
        return copying(action: .text(value), spare: spare)
    }

    func withPassword(_ value: String) -> Rule {
        var spare = spareActions
        spare.password = value
        return copying(action: .password(value), spare: spare)
    }

    func withShortcut(keyCode: UInt16, flags: UInt) -> Rule {
        var spare = spareActions
        spare.shortcutCode = Int(keyCode)
        spare.shortcutFlag = Int(flags)
        return copying(action: .shortcut(keyCode: keyCode, flags: flags), spare: spare)
    }

    func withAppleScript(id: String) -> Rule {
        var spare = spareActions
        spare.appleScriptId = id
        return copying(action: .applescript(id), spare: spare)
    }

    func withActionType(_ index: Int) -> Rule {
        let spare = spareActions
        let action: RuleAction
        switch index {
        case 1: action = .applescript(spare.appleScriptId)
        case 2: action = .text(spare.text)
        case 3: action = .password(spare.password)
        case 4: action = .screenshot
        case 5: action = .volumeUp
        case 6: action = .volumeDown
        default:
            action = .shortcut(keyCode: UInt16(truncatingIfNeeded: spare.shortcutCode),
                               flags: UInt(truncatingIfNeeded: spare.shortcutFlag))
        }
        return copying(action: action, spare: spare)
    }

    func copying(name newName: String? = nil, note newNote: String? = nil,
                 filter newFilter: String? = nil, filterType newFilterType: String? = nil,
                 action newAction: RuleAction? = nil,
                 spare newSpare: RuleSpareActions? = nil) -> Rule {
        Rule(
            name: newName ?? name,
            description: description,
            template: template,
            minSimilarityScore: minSimilarityScore,
            action: newAction ?? action,
            note: newNote ?? note,
            isEnabled: isEnabled,
            triggerOnEveryMatch: triggerOnEveryMatch,
            filter: newFilter ?? filter,
            filterType: newFilterType ?? filterType,
            // 就地编辑任何一列都不该把滚轮档丢掉（Rule 的这个入参默认是 nil，
            // 不显式透传就等于每改一格都退成轨迹规则）。
            spareActions: newSpare ?? spareActions,
            instantGesture: instantGesture
        )
    }
}
