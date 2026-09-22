//
//  HistoryClipboardListWindowController.swift
//  MacStroke
//
//  Window controller for the clipboard history list.
//  Mirrors the original HistoryClipoardListWindowController.xib + .m:
//  - [n]-numbered pinned entries shown in gray at the top
//  - Pin / unpin button per row (↑ / -)
//  - Double-click copies the entry to the pasteboard and closes the window
//  - clear / clearAll / clearTop buttons at the bottom right, sheet confirmations
//  - tips label at the bottom left, three-column table with headers
//  - Scroll to the bottom loads the next page (30 items per page)
//  - Esc closes the window
//  - Floating window level (21) so it stays on top of other apps
//

import Foundation
import AppKit

public final class HistoryClipboardListWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {

    /// All displayed entries (pinned entries first).
    public var entries: [HistoryClipboardEntry] = [] {
        didSet {
            tableView?.reloadData()
        }
    }

    private let entriesStore: HistoryClipboardManager
    private var isLoadingNextPage = false
    private var observedClipView: NSClipView?

    private var tableView: NSTableView?

    public init(manager: HistoryClipboardManager? = nil) {
        self.entriesStore = manager ?? HistoryClipboardManager()
        super.init(window: nil)

        // Original xib: 780x453 content, min 520x400, titled/closable/miniaturizable/resizable.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 453),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("History Clipboard")
        window.minSize = NSSize(width: 520, height: 400)
        window.level = NSWindow.Level(rawValue: 21)
        window.isReleasedWhenClosed = false
        self.window = window

        buildContentView(in: window)
        window.center()

        // Original loads its data in windowDidLoad, which runs for the freshly
        // allocated controller on every "show history clipboard" call.
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI construction

    private func buildContentView(in window: NSWindow) {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 453))
        contentView.autoresizingMask = [.width, .height]

        // Bottom-left tips label (original frame x=20 y=7 w=534 h=16).
        let tips = NSTextField(labelWithString: L(
            "tips: Double-click the content to copy it to clipboard and then you can paste anywhere ."
        ))
        tips.frame = NSRect(x: 20, y: 7, width: 534, height: 16)
        tips.autoresizingMask = [.maxXMargin, .maxYMargin]
        tips.lineBreakMode = .byClipping
        contentView.addSubview(tips)

        // Bottom-right buttons, left to right: clearTop / clear / clearAll.
        contentView.addSubview(makeButton(
            title: L("clearTop"), action: #selector(clearAllTop(_:)), frame: NSRect(x: 560, y: 0, width: 86, height: 32)
        ))
        contentView.addSubview(makeButton(
            title: L("clear"), action: #selector(clearHistoryList(_:)), frame: NSRect(x: 638, y: 0, width: 70, height: 32)
        ))
        contentView.addSubview(makeButton(
            title: L("clearAll"), action: #selector(clearAll(_:)), frame: NSRect(x: 701, y: 0, width: 80, height: 32)
        ))

        // Table (original scrollView frame -1,31 782x419, autoresizes both axes).
        let tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 3, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsExpansionToolTips = true
        tableView.target = self
        tableView.doubleAction = #selector(doubleClick(_:))

        tableView.addTableColumn(makeColumn(identifier: "id", title: L("id"), width: 42, min: 40, max: 1000))
        tableView.addTableColumn(makeColumn(identifier: "content", title: L("content"), width: 670, min: 40, max: 9999))
        let operateColumn = makeColumn(identifier: "operate", title: L("operate"), width: 50, min: 40, max: 50)
        operateColumn.headerCell.alignment = .center
        tableView.addTableColumn(operateColumn)

        let scrollView = NSScrollView(frame: NSRect(x: -1, y: 31, width: 782, height: 419))
        tableView.headerView = NSTableHeaderView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        contentView.addSubview(scrollView)

        window.contentView = contentView
        self.tableView = tableView

        if let clipView = scrollView.contentView as? NSClipView {
            observedClipView = clipView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            clipView.postsBoundsChangedNotifications = true
        }
    }

    private func makeButton(title: String, action: Selector, frame: NSRect) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = title
        button.bezelStyle = .rounded
        button.autoresizingMask = [.minXMargin, .maxYMargin]
        button.target = self
        button.action = action
        return button
    }

    private func makeColumn(identifier: String, title: String, width: CGFloat, min: CGFloat, max: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = min
        column.maxWidth = max
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        return column
    }

    deinit {
        if let clipView = observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    // MARK: - Showing

    /// Original `windowDidLoad`: drop expired rows, then snapshot page 0.
    public func reload() {
        entriesStore.deleteExpired()
        entries = entriesStore.getHistoryClipboardList(firstPage: true)
    }

    // MARK: - Interactions

    /// Double-click: copy the entry content to the pasteboard and close.
    @objc private func doubleClick(_ sender: Any?) {
        let row = tableView?.clickedRow ?? -1
        guard row >= 0, row < entries.count else { return }
        let text = decodedContent(for: entries[row])
        // Original removes the row from its snapshot before writing the pasteboard.
        var updated = entries
        updated.remove(at: row)
        entries = updated
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        window?.close()
    }

    /// Pin the entry at the button's row (original: addTop:).
    @objc private func addTop(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < entries.count else { return }
        _ = entriesStore.addTop(content: decodedContent(for: entries[row]))
        reload()
        tableView?.scrollRowToVisible(0)
    }

    /// Unpin the pinned entry at the button's row (original: removeTop:).
    @objc private func removeTop(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 else { return }
        entriesStore.removeTop(at: row)
        reload()
    }

    @objc private func clearAll(_ sender: Any?) {
        confirm(L("Are you sure to clear all top records and history clipboard records?")) { [weak self] in
            self?.entriesStore.clearAll()
            self?.reload()
        }
    }

    @objc private func clearHistoryList(_ sender: Any?) {
        confirm(L("Are you sure to clear all history clipboard records?")) { [weak self] in
            self?.entriesStore.clearHistoryList()
            self?.reload()
        }
    }

    @objc private func clearAllTop(_ sender: Any?) {
        confirm(L("Are you sure to clear all top records?")) { [weak self] in
            self?.entriesStore.clearTop()
            self?.reload()
        }
    }

    private func confirm(_ informative: String, action: @escaping () -> Void) {
        guard let window = window else { action(); return }
        let alert = NSAlert()
        alert.messageText = L("warning!")
        alert.informativeText = informative
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Ok"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                action()
            }
        }
    }

    /// Esc closes the window (original: cancelOperation:).
    override public func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    private func decodedContent(for entry: HistoryClipboardEntry) -> String {
        guard let data = Data(base64Encoded: entry.content),
              let text = String(data: data, encoding: .utf8) else {
            return entry.content
        }
        return text
    }

    // MARK: - Pagination

    /// Load the next page when the user scrolls to the bottom of the list
    /// (original: DMRefreshTableView state machine → getHistoryClipboardList:NO).
    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard let clipView = observedClipView,
              let documentView = clipView.documentView,
              let tableView = tableView else { return }

        let visibleRect = clipView.documentVisibleRect
        // Original bails out when the whole document already fits.
        guard documentView.bounds.height > visibleRect.height else { return }

        if visibleRect.maxY >= documentView.bounds.height {
            loadNextPage()
        }
    }

    private func loadNextPage() {
        guard !isLoadingNextPage else { return }
        isLoadingNextPage = true
        let next = entriesStore.nextPage(currentHistoryCount: entries.count)
        if !next.isEmpty {
            entries.append(contentsOf: next)
        }
        isLoadingNextPage = false
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        20
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let topCount = entriesStore.topCount
        let isPinned = row < topCount
        let gray = NSColor(calibratedWhite: 0.65, alpha: 1.0)

        switch tableColumn?.identifier.rawValue {
        case "id":
            let text = isPinned ? "[\(row + 1)]" : "\(row - topCount + 1)"
            let field = NSTextField(labelWithString: text)
            field.lineBreakMode = .byTruncatingTail
            if isPinned {
                field.textColor = gray
            }
            return field

        case "content":
            let field = NSTextField(labelWithString: decodedContent(for: entries[row]).replacingOccurrences(of: "\n", with: " "))
            field.lineBreakMode = .byTruncatingMiddle
            if isPinned {
                field.textColor = gray
            }
            return field

        case "operate":
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 25, height: 25))
            button.bezelStyle = .texturedSquare
            button.tag = row
            button.target = self
            if isPinned {
                button.title = "-"
                button.toolTip = L("remove top")
                button.action = #selector(removeTop(_:))
            } else {
                button.title = "↑"
                button.toolTip = L("top")
                button.action = #selector(addTop(_:))
            }
            return button

        default:
            return nil
        }
    }
}
