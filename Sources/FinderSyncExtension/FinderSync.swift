//
//  FinderSync.swift
//  FinderSyncExtension
//
//  Finder Sync extension providing right-click menu integration.
//
//  Menu matches the original MacStroke FinderSync: New File,
//  Open in Terminal, Copy File Path, Re-enable Extension, Quit.
//

import Foundation
import AppKit
import FinderSync

// MARK: - FinderSync extension

/// The FIFinderSync subclass that provides custom menu items in Finder.
/// Registered as the ObjC class "FinderSync" — the NSExtensionPrincipalClass
/// in the appex Info.plist looks it up by that name.
@objc(FinderSync)
public final class FinderSyncExtensionController: FIFinderSync {

    private var enableRightClickMenu = false
    private var enableNewFile = false
    private var enableOpenInTerminal = false
    private var enableCopyFilePath = false
    private var items: [String] = []
    private let sharedDefaults = UserDefaults.standard

    // MARK: - Lifecycle

    override public init() {
        super.init()
        readSharedDefaults()
        setupCommChannel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    /// Read the enable flags + menu titles from this extension's defaults.
    private func readSharedDefaults() {
        sharedDefaults.synchronize()
        enableRightClickMenu = sharedDefaults.bool(forKey: "enableRightClickMenu")
        enableNewFile = sharedDefaults.bool(forKey: "enableNewFile")
        enableOpenInTerminal = sharedDefaults.bool(forKey: "enableOpenInTerminal")
        enableCopyFilePath = sharedDefaults.bool(forKey: "enableCopyFilePath")
        if let raw = sharedDefaults.string(forKey: "items") {
            items = raw.components(separatedBy: ",")
        }
    }

    /// Register the distributed-notification listeners and ask the main app
    /// for the observing root — the original FinderCommChannel.setup flow:
    /// - SyncSharedDefaultsNotification → persist enable flags into our defaults
    /// - ObservingPathSetNotification  → set the observed root directory
    /// - RequestObservingPathNotification (sent) → main app replies + syncs
    private func setupCommChannel() {
        let center = DistributedNotificationCenter.default()
        let mainAppBundleID = Self.mainAppBundleID

        center.addObserver(
            self,
            selector: #selector(syncSharedDefaults(_:)),
            name: NSNotification.Name("SyncSharedDefaultsNotification"),
            object: mainAppBundleID
        )
        center.addObserver(
            self,
            selector: #selector(observingPathSet(_:)),
            name: NSNotification.Name("ObservingPathSetNotification"),
            object: mainAppBundleID
        )

        // The extension is launching: ask the main app which root to observe.
        center.postNotificationName(
            NSNotification.Name("RequestObservingPathNotification"),
            object: mainAppBundleID,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// The main app's bundle ID, inferred by dropping the extension's last
    /// path component (net.mtjo.MacStroke.FinderSyncExtension → net.mtjo.MacStroke).
    private static var mainAppBundleID: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        var components = bundleID.split(separator: ".").map(String.init)
        if !components.isEmpty {
            components.removeLast()
        }
        return components.joined(separator: ".")
    }

    /// Receive enable flags + localized menu titles from the main app and
    /// persist them into this extension's own UserDefaults (the subsequent
    /// UserDefaults.didChangeNotification refreshes the flags).
    @objc private func syncSharedDefaults(_ notification: Notification) {
        guard let data = notification.userInfo else { return }
        sharedDefaults.set(Int(data["enableRightClickMenu"] as? String ?? "0") != 0, forKey: "enableRightClickMenu")
        sharedDefaults.set(Int(data["enableNewFile"] as? String ?? "0") != 0, forKey: "enableNewFile")
        sharedDefaults.set(Int(data["enableOpenInTerminal"] as? String ?? "0") != 0, forKey: "enableOpenInTerminal")
        sharedDefaults.set(Int(data["enableCopyFilePath"] as? String ?? "0") != 0, forKey: "enableCopyFilePath")
        if let items = data["items"] as? String {
            sharedDefaults.set(items, forKey: "items")
        }
        sharedDefaults.synchronize()
        defaultsChanged()
    }

    /// Receive the observing root from the main app (original: setRoot).
    @objc private func observingPathSet(_ notification: Notification) {
        guard let path = notification.userInfo?["path"] as? String else { return }
        let root = URL(fileURLWithPath: path)
        if FIFinderSyncController.default().directoryURLs != [root] {
            FIFinderSyncController.default().directoryURLs = [root]
        }
    }

    // MARK: - Directory observation

    override public func beginObservingDirectory(at url: URL) {
        // The user is now seeing the container's contents.
    }

    override public func endObservingDirectory(at url: URL) {
        // The user is no longer seeing the container's contents.
    }

    // MARK: - Toolbar item

    override public var toolbarItemName: String {
        Bundle.main.localizedString(forKey: "MacStroke", value: "MacStroke", table: nil)
    }
    override public var toolbarItemToolTip: String {
        Bundle.main.localizedString(forKey: "FinderSyncToolbarTooltip", value: "MacStroke", table: nil)
    }
    override public var toolbarItemImage: NSImage {
        if let url = Bundle.main.url(forResource: "toolbarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "gesture", accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: - Menu

    override public func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")
        if enableRightClickMenu {
            if enableNewFile, !items.isEmpty {
                let item = menu.addItem(withTitle: items[0], action: #selector(newFile(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            }
            if enableOpenInTerminal, items.count > 1 {
                let item = menu.addItem(withTitle: items[1], action: #selector(openInTerminal(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
            }
            if enableCopyFilePath, items.count > 2 {
                let item = menu.addItem(withTitle: items[2], action: #selector(copyFilePath(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            }
        }
        return menu
    }

    // MARK: - Menu item actions

    @objc func newFile(_ sender: Any?) {
        let target = FIFinderSyncController.default().targetedURL()
        let selected = FIFinderSyncController.default().selectedItemURLs()
        let paths = selected?.map { $0.path } ?? []
        let path = target?.path ?? ""
        sendCustomMessage(operation: "newFile", path: path, items: paths.joined(separator: ","))
    }

    @objc func openInTerminal(_ sender: Any?) {
        let target = FIFinderSyncController.default().targetedURL()
        let selected = FIFinderSyncController.default().selectedItemURLs()
        let paths = selected?.map { $0.path } ?? []
        let path = target?.path ?? ""
        sendCustomMessage(operation: "openInTerminal", path: path, items: paths.joined(separator: ","))
    }

    @objc func copyFilePath(_ sender: Any?) {
        let target = FIFinderSyncController.default().targetedURL()
        let selected = FIFinderSyncController.default().selectedItemURLs()
        let paths = selected?.map { $0.path } ?? []
        let path = target?.path ?? ""
        sendCustomMessage(operation: "copyFilePath", path: path, items: paths.joined(separator: ","))
    }

    // MARK: - Defaults

    @objc func defaultsChanged() {
        enableRightClickMenu = sharedDefaults.bool(forKey: "enableRightClickMenu")
        enableNewFile = sharedDefaults.bool(forKey: "enableNewFile")
        enableOpenInTerminal = sharedDefaults.bool(forKey: "enableOpenInTerminal")
        enableCopyFilePath = sharedDefaults.bool(forKey: "enableCopyFilePath")
        if let raw = sharedDefaults.string(forKey: "items") {
            items = raw.components(separatedBy: ",")
        }
    }

    // MARK: - Private helpers

    private func sendCustomMessage(operation: String, path: String, items: String) {
        // Mirror the original FinderCommChannel.send: the JSON payload travels
        // in the notification's `object` field (the main app parses it from
        // there), with no userInfo.
        let center = DistributedNotificationCenter.default()
        let payload: [String: String] = ["operation": operation, "path": path, "items": items]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        center.postNotificationName(
            NSNotification.Name("CustomMessageReceivedNotification"),
            object: json,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}