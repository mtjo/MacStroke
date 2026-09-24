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

        let path = NSBezierPath()
        path.lineWidth = 2
        let total = Double(points.count)
        for i in 0..<(scaled.count - 1) {
            let t = Double(i) / total
            NSColor(red: 0.5 * t, green: 0.47 + 0.53 * t, blue: 0.9, alpha: 1).setStroke()
            path.move(to: scaled[i])
            path.line(to: scaled[i + 1])
            path.stroke()
            path.removeAllPoints()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
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

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.selectedRow = $selectedRow
        coordinator.onDrawGesture = onDrawGesture

        let table = NSTableView()
        table.rowHeight = 84
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsEmptySelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        Coordinator.makeColumns().forEach(table.addTableColumn)
        coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selectedRow = $selectedRow
        context.coordinator.onDrawGesture = onDrawGesture
        context.coordinator.reloadIfNeeded()
    }
}

extension RulesTable {
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
            let specs: [(identifier: String, title: String, width: Double)] = [
                ("Gesture_Image", L("Image"), 84),
                ("Gesture", L("Gesture"), 98),
                ("Type", L("Type"), 96),
                ("Action", L("Action"), 104),
                ("Filter", L("Filter"), 138.8515625),
                ("Note", L("Description"), 221),
            ]
            return specs.map { spec in
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.identifier))
                column.title = spec.title
                column.width = spec.width
                column.minWidth = 40
                column.maxWidth = 1000
                column.headerCell.alignment = .center
                return column
            }
        }

        /// Hot Key / Apple Script / Text / Password, in the original combo order
        /// (which is also the persisted `actionType` numbering).
        static var typeTitles: [String] {
            [L("Hot Key"), L("Apple Script"), L("Text"), L("Password")]
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
                    + "\(spare.text)\u{1}\(spare.password)\u{1}\(spare.appleScriptId)"
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
            let container = NSView()
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

        private func addGestureCell(to container: NSView, rule: Rule, row: Int) {
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
            let thumb = GestureThumbView(frame: NSRect(x: 0, y: 0, width: 84, height: 84))
            thumb.autoresizingMask = [.width, .height]
            thumb.points = rule.template.points.map { CGPoint(x: $0.x, y: $0.y) }
            thumb.onDoubleClick = { [weak self] in self?.onDrawGesture(row) }
            container.addSubview(thumb)
        }

        private func addTextCell(to container: NSView, identifier: String, rule: Rule, row: Int) {
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
        }

        private func addTypeCell(to container: NSView, rule: Rule, row: Int) {
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
        }

        private func addActionCell(to container: NSView, rule: Rule, row: Int) {
            switch Self.typeIndex(for: rule.action) {
            case 0:
                let recorder = ShortcutRecorderView()
                recorder.frame = NSRect(x: 0, y: 27, width: 100, height: 25)
                let (keyCode, flags) = shortcutValue(of: rule)
                recorder.keyCode = keyCode
                recorder.flags = flags
                recorder.onShortcutChanged = { [weak self] code, modifierFlags in
                    self?.setShortcut(row: row, keyCode: code, flags: modifierFlags)
                }
                container.addSubview(recorder)
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
            case 2:
                container.addSubview(makeField(identifier: "Text", value: textValue(of: rule),
                                               row: row, width: 100))
            default:
                container.addSubview(makeField(identifier: "Password", value: passwordValue(of: rule),
                                               row: row, width: 100))
            }
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
            spareActions: newSpare ?? spareActions
        )
    }
}
