//
//  FinderSync.swift
//  FinderSyncExtension
//
//  Finder Sync Extension providing right-click menu integration.
//

import Foundation
import FinderSync

// MARK: - Right-click menu provider for Finder

/// Provides the context menu items shown in Finder's right-click menu.
public final class FinderMenuProvider: NSObject {

    public func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "MacStroke")

        let recognizerItem = NSMenuItem(
            title: NSLocalizedString("Recognize Gesture", comment: ""),
            action: #selector(handleRecognizeGesture),
            keyEquivalent: ""
        )
        recognizerItem.target = self
        menu.addItem(recognizerItem)

        let presetsItem = NSMenuItem(
            title: NSLocalizedString("Preset Gestures", comment: ""),
            action: #selector(handlePresets),
            keyEquivalent: ""
        )
        presetsItem.target = self
        menu.addItem(presetsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("Open Preferences", comment: ""),
            action: #selector(handleOpenPreferences),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        return menu
    }

    @objc private func handleRecognizeGesture() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.macstroke.RecognizeGesture"),
            object: nil
        )
    }

    @objc private func handlePresets() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.macstroke.Presets"),
            object: nil
        )
    }

    @objc private func handleOpenPreferences() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.macstroke.OpenPreferences"),
            object: nil
        )
    }
}

// MARK: - FinderSync extension

/// The FIFinderSync subclass that provides custom menu items in Finder.
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
        sharedDefaults.synchronize()
        enableRightClickMenu = sharedDefaults.bool(forKey: "enableRightClickMenu")
        enableNewFile = sharedDefaults.bool(forKey: "enableNewFile")
        enableOpenInTerminal = sharedDefaults.bool(forKey: "enableOpenInTerminal")
        enableCopyFilePath = sharedDefaults.bool(forKey: "enableCopyFilePath")
        if let raw = sharedDefaults.string(forKey: "items") {
            items = raw.components(separatedBy: ",")
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Directory observation

    override public func beginObservingDirectory(at url: URL) {
        // The user is now seeing the container's contents.
    }

    override public func endObservingDirectory(at url: URL) {
        // The user is no longer seeing the container's contents.
    }

    // MARK: - Toolbar item

    override public var toolbarItemName: String { "MacStroke" }
    override public var toolbarItemToolTip: String { "MacStroke: Click the toolbar item for a menu." }
    override public var toolbarItemImage: NSImage { NSImage(named: "newFile.png")! }

    // MARK: - Menu

    override public func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")
        if enableRightClickMenu {
            if enableNewFile, !items.isEmpty {
                menu.addItem(withTitle: items[0], action: #selector(newFile(_:)), keyEquivalent: "")
            }
            if enableOpenInTerminal, items.count > 1 {
                menu.addItem(withTitle: items[1], action: #selector(openInTerminal(_:)), keyEquivalent: "")
            }
            if enableCopyFilePath, items.count > 2 {
                menu.addItem(withTitle: items[2], action: #selector(copyFilePath(_:)), keyEquivalent: "")
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
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name("CustomMessageReceivedNotification"),
            object: Bundle.main.bundleIdentifier,
            userInfo: ["operation": operation, "path": path, "items": items],
            deliverImmediately: true
        )
    }
}