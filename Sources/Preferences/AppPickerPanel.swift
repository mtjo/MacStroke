//
//  AppPickerPanel.swift
//  MacStroke
//
//  Programmatic equivalent of the original AppPickerWindowController: a modal
//  window listing running apps with a checkbox column (icon + bundle ID).
//  Supports multi-select (rule filter, black/white lists) and the original
//  `selectOne` single-select mode (right-click app list).
//

import AppKit
import Storage

public final class AppPickerPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private final class Row {
        let bundleID: String
        let icon: NSImage
        var checked: Bool
        init(bundleID: String, icon: NSImage, checked: Bool) {
            self.bundleID = bundleID
            self.icon = icon
            self.checked = checked
        }
    }

    /// Show the picker modally. Returns the selected bundle IDs (nil on cancel).
    public static func pick(title: String,
                            preselected: Set<String> = [],
                            singleSelection: Bool = false) -> [String]? {
        let panel = AppPickerPanel(preselected: preselected, singleSelection: singleSelection)
        return panel.run(title: title)
    }

    private let rows: [Row]
    private let singleSelection: Bool
    private var window: NSWindow!

    private init(preselected: Set<String>, singleSelection: Bool) {
        self.singleSelection = singleSelection

        var list: [Row] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !($0.bundleIdentifier ?? "").isEmpty }
            .map { app in
                Row(bundleID: app.bundleIdentifier!,
                    icon: app.icon ?? NSImage(size: NSSize(width: 16, height: 16)),
                    checked: preselected.contains(app.bundleIdentifier!))
            }
        list.sort { $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending }

        // Patterns already in the filter but not currently running stay listed, checked.
        for extra in preselected.sorted() where !list.contains(where: { $0.bundleID == extra }) {
            list.append(Row(bundleID: extra, icon: Self.icon(forBundleID: extra), checked: true))
        }
        rows = list
    }

    private static func icon(forBundleID bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(size: NSSize(width: 16, height: 16))
    }

    private func run(title: String) -> [String]? {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title

        let columns: [(String, NSUserInterfaceItemIdentifier, CGFloat)] = [
            ("", NSUserInterfaceItemIdentifier("CheckBox"), 26),
            ("", NSUserInterfaceItemIdentifier("Icon"), 22),
            (L("Bundle ID"), NSUserInterfaceItemIdentifier("BundleID"), 300),
        ]
        let tableView = NSTableView()
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 2, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        for (label, id, width) in columns {
            let col = NSTableColumn(identifier: id)
            col.title = label
            col.width = width
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 48, width: 356, height: 280))
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let ok = NSButton(title: L("OK"), target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.frame = NSRect(x: 288, y: 12, width: 80, height: 28)
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 204, y: 12, width: 80, height: 28)

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        content.addSubview(ok)
        content.addSubview(cancel)
        window.contentView = content

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        window.contentView = nil

        guard response == .OK else { return nil }
        return rows.filter(\.checked).map(\.bundleID)
    }

    @objc private func okClicked() {
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelClicked() {
        NSApp.stopModal(withCode: .cancel)
    }

    @objc private func checkClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < rows.count else { return }
        rows[row].checked = sender.state == .on
        if singleSelection, sender.state == .on {
            for (i, r) in rows.enumerated() where i != row && r.checked {
                r.checked = false
            }
        }
        (sender.superview?.superview as? NSTableView)?.reloadData()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, isRowSelectable row: Int) -> Bool { false }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let item = rows[row]
        switch id.rawValue {
        case "CheckBox":
            let checkBox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkClicked(_:)))
            checkBox.tag = row
            checkBox.state = item.checked ? .on : .off
            return checkBox
        case "Icon":
            let imageView = NSImageView()
            imageView.image = item.icon
            return imageView
        default:
            let textField = NSTextField(labelWithString: item.bundleID)
            textField.font = .systemFont(ofSize: 11)
            textField.lineBreakMode = .byTruncatingTail
            return textField
        }
    }
}
