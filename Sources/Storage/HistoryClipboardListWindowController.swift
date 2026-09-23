//
//  HistoryClipboardListWindowController.swift
//  MacStroke
//
//  Spotlight-style clipboard history panel:
//  - rounded borderless-looking HUD blur panel, centered on screen
//  - a large Spotlight-style search field on top: typing filters the loaded
//    entries instantly, Arrow keys drive the row selection, Return copies the
//    selected entry (the original's entry point was double-click)
//  - single source-list style result column: "[n] content" for pinned rows
//    (gray) and "n content" for history rows; the pin button (↑ / −) is
//    revealed on row hover or selection, Spotlight-style
//  - text rows show their content; image rows show the PNG as a thumbnail and
//    file rows the real Finder icon, with a searchable name/dimension summary
//  - original features kept: double-click copy + close, pin / unpin,
//    clear / clearTop / clearAll with sheet confirmations, bottom tips label,
//    scroll-to-bottom pagination (30 per page), Esc close from any focus,
//    floating level 21
//

import Foundation
import AppKit

public final class HistoryClipboardListWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate {

    /// All loaded entries (pinned entries first). Setting it resets the query.
    public var entries: [HistoryClipboardEntry] = [] {
        didSet {
            fullEntries = entries
            searchField?.stringValue = ""
            query = ""
            rebuildFiltered()
        }
    }

    /// Entries currently shown in the result list (query-filtered snapshot).
    public private(set) var displayedEntries: [HistoryClipboardEntry] = []

    /// Live window query (empty shows everything loaded so far).
    public private(set) var query: String = ""

    private var fullEntries: [HistoryClipboardEntry] = [] {
        didSet { rebuildFiltered() }
    }

    private let entriesStore: HistoryClipboardManager
    private var isLoadingNextPage = false
    private var observedClipView: NSClipView?

    private var tableView: NSTableView?
    private var searchField: NSSearchField?

    private enum Layout {
        static let width: CGFloat = 660
        static let height: CGFloat = 480
        static let searchTop: CGFloat = 14
        static let searchHeight: CGFloat = 36
        static let side: CGFloat = 14
        static let rowHeight: CGFloat = 28
        static let iconRowHeight: CGFloat = 44
    }

    /// Case-insensitive substring filter over decoded content; the
    /// pinned-first order of the loaded snapshot is preserved.
    static func filterEntries(_ entries: [HistoryClipboardEntry], query: String, decoded: (HistoryClipboardEntry) -> String) -> [HistoryClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { decoded($0).range(of: q, options: .caseInsensitive) != nil }
    }

    public init(manager: HistoryClipboardManager? = nil) {
        self.entriesStore = manager ?? HistoryClipboardManager()
        super.init(window: nil)

        // Spotlight-style panel: no visible titlebar chrome, native rounded
        // corners and shadow, full-size blur content. The titled style is kept
        // so the panel can still become key (typing, Esc, sheet confirmations).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("History Clipboard")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 520, height: 360)
        window.level = NSWindow.Level(rawValue: 21)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
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
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        window.contentView = effect

        let clip = EscClosesView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.frame = effect.bounds
        clip.autoresizingMask = [.width, .height]
        effect.addSubview(clip)

        // Spotlight-style search field across the top.
        let search = makeSearchField()
        search.frame = NSRect(x: Layout.side,
                              y: Layout.height - Layout.searchTop - Layout.searchHeight,
                              width: Layout.width - Layout.side * 2,
                              height: Layout.searchHeight)
        search.autoresizingMask = [.width, .minYMargin]
        clip.addSubview(search)
        self.searchField = search

        // Bottom-right buttons, left to right: clearTop / clear / clearAll.
        for (title, action, frame) in [
            (L("clearTop"), #selector(clearAllTop(_:)), NSRect(x: Layout.width - 14 - 244, y: 8, width: 90, height: 28)),
            (L("clear"), #selector(clearHistoryList(_:)), NSRect(x: Layout.width - 14 - 150, y: 8, width: 70, height: 28)),
            (L("clearAll"), #selector(clearAll(_:)), NSRect(x: Layout.width - 14 - 76, y: 8, width: 76, height: 28)),
        ] {
            let button = NSButton(frame: frame)
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            button.autoresizingMask = [.minXMargin, .maxYMargin]
            button.target = self
            button.action = action
            clip.addSubview(button)
        }

        // Bottom-left tips label; wide enough for the localized sentence and
        // allowed to wrap, so it never clips.
        let tips = NSTextField(labelWithString: L(
            "tips: Type to search, Enter copies the selected content to the clipboard so you can paste it anywhere."
        ))
        tips.font = NSFont.systemFont(ofSize: 10)
        tips.textColor = .secondaryLabelColor
        tips.frame = NSRect(x: 14, y: 8, width: 380, height: 28)
        tips.autoresizingMask = [.maxXMargin, .maxYMargin]
        tips.maximumNumberOfLines = 2
        tips.lineBreakMode = .byWordWrapping
        tips.cell?.wraps = true
        clip.addSubview(tips)

        // Result list: single column, no header, source-list rounded selection.
        let tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(doubleClick(_:))
        tableView.addTableColumn(makeColumn(identifier: "result", title: "", width: Layout.width - 20))

        let listTopY = Layout.height - Layout.searchTop - Layout.searchHeight - 8
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.frame = NSRect(x: 6, y: 44, width: Layout.width - 12, height: listTopY - 44)
        scrollView.autoresizingMask = [.width, .height]
        clip.addSubview(scrollView)
        self.tableView = tableView

        let clipView = scrollView.contentView
        observedClipView = clipView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        clipView.postsBoundsChangedNotifications = true

        window.initialFirstResponder = search
    }

    private func makeSearchField() -> NSSearchField {
        let search = NSSearchField()
        search.placeholderString = L("Search clipboard history")
        search.font = NSFont.systemFont(ofSize: 22, weight: .light)
        search.focusRingType = .none
        search.delegate = self
        ((search.cell as? NSSearchFieldCell)?.searchButtonCell as? NSButtonCell)?
            .imageScaling = .scaleProportionallyDown
        return search
    }

    private func makeColumn(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 100
        column.maxWidth = 10_000
        column.resizingMask = [.autoresizingMask]
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

    private func rebuildFiltered() {
        displayedEntries = Self.filterEntries(fullEntries, query: query, decoded: summary(for:))
        tableView?.reloadData()
        if query.isEmpty {
            tableView?.deselectAll(nil)
        } else {
            selectFirstMatched()
        }
    }

    // MARK: - Search

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.userInfo?["NSControl"] as? NSSearchField else { return }
        controlTextDidChangeForSearch(field)
    }

    /// Spotlight keyboard flow: arrows move the result selection, Return
    /// copies, Esc closes the panel.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            copyRowToPasteboardAndClose(tableView?.selectedRow ?? -1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // The field editor owns Esc while the search field is focused, so
            // close the panel here instead of walking up the responder chain.
            window?.close()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection { current, count in (current + 1) % count }
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection { current, count in current <= 0 ? count - 1 : current - 1 }
            return true
        default:
            return false
        }
    }

    private func controlTextDidChangeForSearch(_ field: NSSearchField) {
        query = field.stringValue
        rebuildFiltered()
        scrollListToTop()
    }

    private func scrollListToTop() {
        tableView?.scrollRowToVisible(0)
    }

    private func selectFirstMatched() {
        guard !displayedEntries.isEmpty, let tableView = tableView else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    /// Move the Spotlight-style selection from the search field with Arrow keys.
    private func moveSelection(_ next: (Int, Int) -> Int) {
        guard let tableView = tableView, !displayedEntries.isEmpty else { return }
        let count = displayedEntries.count
        let current = tableView.selectedRow
        let row = next(current, count)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    // MARK: - Interactions

    /// Double-click: copy the entry content to the pasteboard and close
    /// (original behavior; Return routes here too via the search delegate).
    @objc private func doubleClick(_ sender: Any?) {
        copyRowToPasteboardAndClose(tableView?.clickedRow ?? tableView?.selectedRow ?? -1)
    }

    private func copyRowToPasteboardAndClose(_ row: Int) {
        guard row >= 0, row < displayedEntries.count else { return }
        let entry = displayedEntries[row]
        // Original removes the row from its snapshot before writing the pasteboard.
        if let index = fullEntries.firstIndex(where: { $0.id == entry.id }) {
            var updated = fullEntries
            updated.remove(at: index)
            fullEntries = updated
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.kind {
        case .text:
            pasteboard.setString(entriesStore.textContent(for: entry), forType: .string)
        case .image:
            guard let data = entriesStore.imageData(for: entry),
                  let tiff = NSImage(data: data)?.tiffRepresentation else { break }
            // Reuse the screenshot: declare both PNG and TIFF so every receiver
            // (Preview, Office, chat apps) finds a type it accepts.
            pasteboard.declareTypes([.tiff, .png], owner: nil)
            pasteboard.setData(tiff, forType: .tiff)
            if let png = HistoryClipboardManager.pngData(from: data) {
                pasteboard.setData(png, forType: .png)
            }
        case .file:
            // Reuse the copy: writeObjects([NSURL]) is what Finder's own paste
            // board writer produces, so Cmd+V in Finder copies the files again.
            let urls = entriesStore.filePaths(for: entry).map { URL(fileURLWithPath: $0) as NSURL }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls)
            }
        }
        window?.close()
    }

    /// Pin the entry at the button's row (original: addTop:). Image rows pin a
    /// copy of their PNG payload; file rows pin the same path list.
    @objc private func addTop(_ sender: NSButton) {
        guard let entry = entry(for: sender) else { return }
        switch entry.kind {
        case .text: _ = entriesStore.addTop(content: entriesStore.textContent(for: entry))
        case .image: _ = entriesStore.addTopImage(for: entry)
        case .file: _ = entriesStore.addTopFile(for: entry)
        }
        reload()
        tableView?.scrollRowToVisible(0)
    }

    /// Unpin the pinned entry at the button's row (original: removeTop:).
    @objc private func removeTop(_ sender: NSButton) {
        guard let entry = entry(for: sender),
              let index = fullEntries.firstIndex(where: { $0.id == entry.id }),
              index < entriesStore.topCount else { return }
        entriesStore.removeTop(at: index)
        reload()
    }

    /// Resolve the entry behind a per-row button by its stable database id.
    private func entry(for button: NSButton) -> HistoryClipboardEntry? {
        displayedEntries.first { $0.id == Int64(button.tag) }
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

    // MARK: - Entry text and image previews

    /// Row text, used for display and as the search match target. Image and
    /// file rows carry a generated summary instead of pixels or raw paths so
    /// they stay searchable by name.
    private func summary(for entry: HistoryClipboardEntry) -> String {
        switch entry.kind {
        case .text:
            return entriesStore.textContent(for: entry).replacingOccurrences(of: "\n", with: " ")
        case .image:
            let size = thumbnail(for: entry)?.size ?? .zero
            let dimensions = size.width > 0 ? "\(Int(size.width))×\(Int(size.height))" : ""
            return [L("image"), dimensions, stamp(for: entry)].filter { !$0.isEmpty }.joined(separator: " ")
        case .file:
            // The row icon already says "file", so the text is the names.
            let names = entriesStore.filePaths(for: entry).map { ($0 as NSString).lastPathComponent }
            let head = names.count > 1 ? LFormat("%d files:", names.count) : ""
            let shown = names.prefix(2).joined(separator: ", ")
            let tail = names.count > 2 ? "…" : ""
            return [head, shown + tail, stamp(for: entry)].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private func stamp(for entry: HistoryClipboardEntry) -> String {
        Self.summaryFormatter.string(from: Date(timeIntervalSince1970: entry.createTime))
    }

    private static let summaryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// Cached row icon: the stored PNG for image rows, the real Finder icon for
    /// file rows. Read once per entry so scrolling does not re-decode them.
    private func thumbnail(for entry: HistoryClipboardEntry) -> NSImage? {
        guard entry.kind == .image || entry.kind == .file else { return nil }
        if let cached = thumbnailCache[entry.content] { return cached }
        let image: NSImage?
        switch entry.kind {
        case .image:
            image = entriesStore.imageData(for: entry).flatMap { NSImage(data: $0) }
        case .file:
            let paths = entriesStore.filePaths(for: entry)
            if paths.count > 1 {
                image = NSWorkspace.shared.icon(forFiles: paths)
            } else {
                image = paths.first.map { NSWorkspace.shared.icon(forFile: $0) }
            }
        case .text:
            image = nil
        }
        if let image {
            thumbnailCache[entry.content] = image
        }
        return image
    }

    private var thumbnailCache: [String: NSImage] = [:]

    // MARK: - Pagination

    /// Load the next page when the user scrolls to the bottom of the list
    /// (original: DMRefreshTableView state machine → getHistoryClipboardList:NO).
    /// Only while browsing: a query filters the loaded snapshot.
    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard query.isEmpty,
              let clipView = observedClipView,
              let documentView = clipView.documentView else { return }

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
        let next = entriesStore.nextPage(currentHistoryCount: fullEntries.count)
        if !next.isEmpty {
            var updated = fullEntries
            updated.append(contentsOf: next)
            fullEntries = updated
        }
        isLoadingNextPage = false
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayedEntries.count
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SpotlightRowView()
    }

    /// Icon rows (images, files) are taller so the thumbnail has room, like
    /// Spotlight's file results.
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < displayedEntries.count else { return Layout.rowHeight }
        return displayedEntries[row].kind == .text ? Layout.rowHeight : Layout.iconRowHeight
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedEntries.count else { return nil }
        let entry = displayedEntries[row]
        let cell = ResultCellView()

        // Pinned rows keep the original's gray "[n]" numbering.
        let isPinned = entry.isTop
        let globalIndex = fullEntries.firstIndex(where: { $0.id == entry.id }) ?? row
        let topCount = entriesStore.topCount
        let number = isPinned ? "[\(globalIndex + 1)]" : "\(max(1, globalIndex - topCount + 1))"

        if let image = thumbnail(for: entry) {
            let thumb = NSImageView()
            thumb.image = image
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = 3
            thumb.layer?.masksToBounds = true
            thumb.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
            cell.addSubview(thumb)
            cell.thumbnail = thumb
        }

        let label = NSTextField(labelWithString: "\(number) \(summary(for: entry))")
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = isPinned ? NSColor.secondaryLabelColor : NSColor.labelColor
        label.autoresizingMask = [.width, .height]
        cell.addSubview(label)
        cell.textField = label

        // Pin / unpin button, revealed on row hover or selection like
        // Spotlight's row accessories.
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.font = NSFont.systemFont(ofSize: 14)
        button.contentTintColor = .secondaryLabelColor
        button.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        button.tag = Int(entry.id)
        button.target = self
        if isPinned {
            button.title = "−"
            button.toolTip = L("remove top")
            button.action = #selector(removeTop(_:))
        } else {
            button.title = "↑"
            button.toolTip = L("top")
            button.action = #selector(addTop(_:))
        }
        button.isHidden = true
        cell.addSubview(button)
        cell.label = label
        cell.pinButton = button
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? SpotlightRowView {
            rowView.revealButton = button
        }
        return cell
    }

    /// Source-list rounded selection capsule plus Spotlight-style hover reveal
    /// for the row's pin button.
    final class SpotlightRowView: NSTableRowView {
        weak var revealButton: NSButton?
        private var hovered = false

        override func drawSelection(in dirtyRect: NSRect) {
            guard selectionHighlightStyle != .none else { return }
            let inset = bounds.insetBy(dx: 6, dy: 1)
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6).fill()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            guard superview != nil else { return }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil))
        }

        override func didAddSubview(_ subview: NSView) {
            super.didAddSubview(subview)
            // Cell views are attached during table validation, possibly after
            // the selection change; re-run the reveal for the new content.
            refreshReveal()
        }

        override func mouseEntered(with event: NSEvent) {
            hovered = true
            refreshReveal()
        }

        override func mouseExited(with event: NSEvent) {
            hovered = false
            refreshReveal()
        }

        override var isSelected: Bool {
            didSet { refreshReveal() }
        }

        override var isEmphasized: Bool {
            didSet { refreshReveal() }
        }

        private func refreshReveal() {
            revealButton?.isHidden = !(hovered || isSelected || isEmphasized)
        }
    }
}

/// Panel container: Esc pressed while the result list (or a button) holds the
/// focus travels the responder chain here, matching the original's
/// `cancelOperation:` close behavior.
private final class EscClosesView: NSView {
    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }
}

/// Frame-based cell: view-based tables hand out cells whose height is
/// ambiguous under Auto Layout (the row content collapsed to 0pt), so the
/// label and pin button are laid out manually like the original xib cells.
private final class ResultCellView: NSTableCellView {
    weak var label: NSTextField?
    weak var pinButton: NSButton?
    weak var thumbnail: NSImageView?

    override func layout() {
        super.layout()
        thumbnail?.frame = NSRect(x: 8, y: (bounds.height - 32) / 2, width: 32, height: 32)
        let textX: CGFloat = thumbnail == nil ? 8 : 48
        label?.frame = NSRect(x: textX, y: (bounds.height - 17) / 2,
                              width: max(20, bounds.width - textX - 36), height: 17)
        pinButton?.frame = NSRect(x: bounds.width - 30, y: (bounds.height - 20) / 2,
                                  width: 24, height: 20)
    }
}
