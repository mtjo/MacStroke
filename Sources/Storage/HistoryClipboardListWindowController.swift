//
//  HistoryClipboardListWindowController.swift
//  MacStroke
//
//  Window controller for displaying clipboard history entries.
//

import Foundation
import AppKit

/// Window controller that shows the clipboard history list.
public final class HistoryClipboardListWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {

    public var entries: [HistoryClipboardEntry] = [] {
        didSet {
            tableView?.reloadData()
        }
    }

    private var manager: HistoryClipboardManager?
    private var clipboardPasteboardObserver: Any?

    private var tableView: NSTableView?
    private let entriesStore = HistoryClipboardManager()

    public init(manager: HistoryClipboardManager? = nil) {
        self.manager = manager ?? HistoryClipboardManager()
        super.init(window: nil)

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let tableView = NSTableView(frame: contentView.bounds)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.autoresizingMask = [.width, .height]

        let idColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("id"))
        idColumn.title = "ID"
        idColumn.minWidth = 40
        idColumn.maxWidth = 60

        let contentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        contentColumn.title = "内容"
        contentColumn.minWidth = 200
        contentColumn.maxWidth = 500

        tableView.addTableColumn(idColumn)
        tableView.addTableColumn(contentColumn)
        tableView.headerView?.isHidden = true

        let scrollView = NSScrollView(frame: contentView.bounds)
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered,
                               defer: false)
        window.contentView = contentView
        window.title = "剪贴板历史"
        window.center()
        self.window = window
        self.tableView = tableView

        // Start monitoring pasteboard for changes
        startPasteboardObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopPasteboardObserver()
    }

    /// Show the window and reload entries.
    public override func showWindow(_ sender: Any?) {
        reloadEntries()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reloadEntries() {
        entries = entriesStore.getHistoryClipboardList(firstPage: true)
    }

    // MARK: - Pasteboard Monitoring

    private func startPasteboardObserver() {
        let pasteboard = NSPasteboard.general
        var lastChangeCount = pasteboard.changeCount

        clipboardPasteboardObserver = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != lastChangeCount {
                lastChangeCount = pasteboard.changeCount
                self.reloadEntries()
            }
        }
    }

    private func stopPasteboardObserver() {
        if let observer = clipboardPasteboardObserver as? Timer {
            observer.invalidate()
        }
        clipboardPasteboardObserver = nil
    }

    // MARK: - Table View Data Source

    public func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    public func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        let entry = entries[row]
        switch column?.identifier.rawValue {
        case "id":
            return "\(entry.id)"
        case "content":
            // Decode base64 content
            if let data = Data(base64Encoded: entry.content),
               let text = String(data: data, encoding: .utf8) {
                return text.count > 80 ? String(text.prefix(80)) + "…" : text
            }
            return entry.content
        default:
            return nil
        }
    }

    // MARK: - Table View Delegate

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // Could add actions on selection
    }
}