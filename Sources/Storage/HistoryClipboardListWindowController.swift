//
//  HistoryClipboardListWindowController.swift
//  MacStroke
//
//  Window controller for the clipboard history list.
//  Mirrors the original HistoryClipoardListWindowController:
//  - [n]-numbered pinned entries shown in gray at the top
//  - Pin / unpin button per row
//  - Double-click copies the entry to the pasteboard and closes the window
//  - Clear All / Clear History / Clear Top buttons with confirmation sheets
//  - Scroll-to-bottom triggers the next page load (30 items per page)
//  - Esc closes the window
//  - Floating window level (21) so it stays on top of other apps
//

import Foundation
import AppKit

public final class HistoryClipboardListWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSWindowDelegate {

    /// All displayed entries (pinned entries first).
    public var entries: [HistoryClipboardEntry] = [] {
        didSet {
            tableView?.reloadData()
        }
    }

    private let entriesStore: HistoryClipboardManager
    private var isLoadingNextPage = false
    private var observedClipView: NSClipView?

    /// Polls the pasteboard while the window is visible so newly copied
    /// content appears in the list immediately.
    private var pasteboardPollTimer: Timer?
    private var lastSeenChangeCount: Int = 0

    private var tableView: NSTableView?
    private var clearAllButton: NSButton?
    private var clearHistoryButton: NSButton?
    private var clearTopButton: NSButton?

    public init(manager: HistoryClipboardManager? = nil) {
        self.entriesStore = manager ?? HistoryClipboardManager()
        super.init(window: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("History Clipboard")
        window.level = NSWindow.Level(rawValue: 21) // floating, matches original
        window.isReleasedWhenClosed = false
        self.window = window

        buildContentView(in: window)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI construction

    private func buildContentView(in window: NSWindow) {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        contentView.autoresizingMask = [.width, .height]

        // Toolbar row with the three clear buttons.
        let buttonRow = NSStackView(views: [])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let clearTopButton = NSButton(title: L("Clear Top"), target: self, action: #selector(clearTop(_:)))
        clearTopButton.bezelStyle = .rounded
        let clearHistoryButton = NSButton(title: L("Clear History"), target: self, action: #selector(clearHistoryList(_:)))
        clearHistoryButton.bezelStyle = .rounded
        let clearAllButton = NSButton(title: L("Clear All"), target: self, action: #selector(clearAll(_:)))
        clearAllButton.bezelStyle = .rounded

        buttonRow.addArrangedSubview(clearTopButton)
        buttonRow.addArrangedSubview(clearHistoryButton)
        buttonRow.addArrangedSubview(clearAllButton)
        buttonRow.addArrangedSubview(NSView()) // spacer
        contentView.addSubview(buttonRow)
        self.clearTopButton = clearTopButton
        self.clearHistoryButton = clearHistoryButton
        self.clearAllButton = clearAllButton

        // Table.
        let tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 20
        tableView.headerView = nil
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let idColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("id"))
        idColumn.width = 40
        tableView.addTableColumn(idColumn)

        let contentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        contentColumn.width = 500
        tableView.addTableColumn(contentColumn)

        let operateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("operate"))
        operateColumn.width = 30
        tableView.addTableColumn(operateColumn)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            buttonRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        window.contentView = contentView
        self.tableView = tableView
        window.delegate = self

        // Double-click pastes the entry and closes the window.
        tableView.target = self
        tableView.doubleAction = #selector(doubleClick(_:))

        // Observe clip-view bounds changes to trigger next-page loading.
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

    deinit {
        if let clipView = observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    // MARK: - Showing

    public override func showWindow(_ sender: Any?) {
        reload()
        startPasteboardPolling()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reload from storage: delete expired items, reset pagination to page 0.
    public func reload() {
        lastSeenChangeCount = NSPasteboard.general.changeCount
        entriesStore.deleteExpired()
        entries = entriesStore.getHistoryClipboardList(firstPage: true)
    }

    // MARK: - NSWindowDelegate (live refresh while visible)

    public func windowWillClose(_ notification: Notification) {
        pasteboardPollTimer?.invalidate()
        pasteboardPollTimer = nil
    }

    /// Poll the pasteboard every 0.5 s while the window is visible and
    /// refresh the list when its change count moves.
    private func startPasteboardPolling() {
        pasteboardPollTimer?.invalidate()
        lastSeenChangeCount = NSPasteboard.general.changeCount
        pasteboardPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            let count = NSPasteboard.general.changeCount
            if count != self.lastSeenChangeCount {
                self.lastSeenChangeCount = count
                self.entriesStore.deleteExpired()
                self.entries = self.entriesStore.getHistoryClipboardList(firstPage: true)
            }
        }
        if let timer = pasteboardPollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    // MARK: - Interactions

    /// Double-click: copy the entry content to the pasteboard and close.
    @objc private func doubleClick(_ sender: Any?) {
        let row = tableView?.clickedRow ?? -1
        guard row >= 0, row < entries.count else { return }
        let text = decodedContent(for: entries[row])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        window?.close()
    }

    /// Pin the entry at the button's row.
    @objc private func addTop(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < entries.count else { return }
        _ = entriesStore.addTop(content: decodedContent(for: entries[row]))
        reload()
        tableView?.scrollRowToVisible(0)
    }

    /// Unpin the pinned entry at the button's row.
    @objc private func removeTop(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < entries.count else { return }
        entriesStore.removeTop(at: row)
        reload()
    }

    @objc private func clearAll(_ sender: Any?) {
        confirm(message: L("warning!"),
                informative: L("Are you sure to clear all top records and history clipboard records?")) { [weak self] in
            self?.entriesStore.clearAll()
            self?.reload()
        }
    }

    @objc private func clearHistoryList(_ sender: Any?) {
        confirm(message: L("warning!"),
                informative: L("Are you sure to clear all history clipboard records?")) { [weak self] in
            self?.entriesStore.clearHistoryList()
            self?.reload()
        }
    }

    @objc private func clearTop(_ sender: Any?) {
        confirm(message: L("warning!"),
                informative: L("Are you sure to clear all top records?")) { [weak self] in
            self?.entriesStore.clearTop()
            self?.reload()
        }
    }

    private func confirm(message: String, informative: String, action: @escaping () -> Void) {
        guard let window = window else { action(); return }
        let alert = NSAlert()
        alert.messageText = message
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

    /// Load the next page when the user scrolls to the bottom of the list.
    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard let clipView = observedClipView,
              let documentView = clipView.documentView,
              let tableView = tableView else { return }

        let visibleRect = clipView.documentVisibleRect
        // Skip when content is fully visible.
        guard documentView.bounds.height > visibleRect.height else { return }

        let bottomOffset = visibleRect.maxY
        if bottomOffset >= documentView.bounds.height - 40 {
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

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let topCount = entriesStore.topCount
        let entry = entries[row]

        switch tableColumn?.identifier.rawValue {
        case "id":
            let field = NSTextField(labelWithString: row < topCount ? "[\(row + 1)]" : "\(row - topCount + 1)")
            field.lineBreakMode = .byTruncatingTail
            if row < topCount {
                field.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
            }
            return field

        case "content":
            let field = NSTextField(labelWithString: decodedContent(for: entry).replacingOccurrences(of: "\n", with: " "))
            field.lineBreakMode = .byTruncatingMiddle
            if row < topCount {
                field.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
            }
            return field

        case "operate":
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 25, height: 20))
            button.bezelStyle = .texturedSquare
            button.tag = row
            if row < topCount {
                button.title = "-"
                button.toolTip = L("remove top")
                button.target = self
                button.action = #selector(removeTop(_:))
            } else {
                button.title = "↑"
                button.toolTip = L("top")
                button.target = self
                button.action = #selector(addTop(_:))
            }
            return button

        default:
            return nil
        }
    }
}
