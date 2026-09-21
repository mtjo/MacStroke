//
//  RightClickMenuManager.swift
//  MacStroke
//
//  Manages the FinderSync extension lifecycle: enable/disable, distributed notifications,
//  new text file creation, terminal open, and file path copy.
//

import Foundation
import AppKit

/// Manager for the FinderSyncExtension right-click menu feature.
///
/// - Responsibilities:
///   - Register/unregister distributed notification center observers
///   - Sync shared defaults (enable flags) to the Finder extension
///   - Create new text files at a Finder path (with rename collision handling)
///   - Open a path in the default terminal
///   - Copy a file path to the pasteboard
///   - Enable/disable the FinderSync extension via pluginkit
public final class RightClickMenuManager {

    public static let shared = RightClickMenuManager()

    private let defaults: UserDefaults
    private var queuedUpdates: [String: Int] = [:]
    private var timer: Timer?

    // MARK: - Initialization

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - FinderSync Extension Lifecycle

    /// Register for distributed notifications from the Finder extension
    /// and sync shared defaults.
    public func initFinderSyncExtension() {
        let center = DistributedNotificationCenter.default()
        // `suspensionBehavior: .deliverImmediately`: as a background agent the app
        // gets throttled, and the default (coalescing) behaviour drops requests.
        center.addObserver(
            self,
            selector: #selector(rootPathRequested(_:)),
            name: Notification.Name("RequestObservingPathNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(customMessageReceivedFromFinder(_:)),
            name: Notification.Name("CustomMessageReceivedNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        syncSharedDefaultsToFinderSyncExtension()
    }

    /// Sync enable flags and menu items to the FinderSync extension via distributed notification
    public func syncSharedDefaultsToFinderSyncExtension() {
        let array = [
            Bundle.main.localizedString(forKey: "New text file", value: nil, table: nil),
            Bundle.main.localizedString(forKey: "Open in Terminal", value: nil, table: nil),
            Bundle.main.localizedString(forKey: "Copy file path", value: nil, table: nil)
        ]
        let items = array.joined(separator: ",")

        let enableRightClickMenu = defaults.bool(forKey: "enableRightClickMenu")
        let enableNewFile = defaults.bool(forKey: "newFile")
        let enableOpenInTerminal = defaults.bool(forKey: "openInTerminal")
        let enableCopyFilePath = defaults.bool(forKey: "copyFilePath")

        send(
            "SyncSharedDefaultsNotification",
            data: [
                "enableRightClickMenu": RightClickMenuManager.flagString(enableRightClickMenu),
                "enableNewFile": RightClickMenuManager.flagString(enableNewFile),
                "enableOpenInTerminal": RightClickMenuManager.flagString(enableOpenInTerminal),
                "enableCopyFilePath": RightClickMenuManager.flagString(enableCopyFilePath),
                "items": items
            ]
        )
    }

    /// The original sends these as `%hhd` (so "1"/"0"), and the extension parses
    /// them with `intValue` — "true"/"false" would both read back as 0.
    private static func flagString(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    /// Enable the FinderSync extension
    public func enableFinderExtension() {
        _ = runShell("pluginkit -e use -i net.mtjo.MacStroke.FinderSyncExtension")
    }

    /// Disable the FinderSync extension
    public func disableFinderExtension() {
        _ = runShell("pluginkit -e ignore -i net.mtjo.MacStroke.FinderSyncExtension")
    }

    /// Disable then re-enable the extension after 2 seconds
    public func reEnableFinderExtension() {
        disableFinderExtension()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.enableFinderExtension()
        }
    }

    /// Delayed re-enable: disable, then re-enable after 10s and again after 120s
    public func delayedEnableFinderExtension() {
        disableFinderExtension()
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.enableFinderExtension()
        }
        Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false) { [weak self] _ in
            self?.enableFinderExtension()
        }
    }

    // MARK: - File Operations

    /// Create a new text file in the given Finder directory path.
    /// Handles filename collisions by appending a counter (newTextFile, newTextFile1, …).
    /// Falls back to an AppleScript `do shell script` if direct creation fails.
    public func newFile(path: String) {
        let fileManager = FileManager.default
        var filepath = path + Bundle.main.localizedString(forKey: "newTextFile", value: nil, table: nil)
        var i = 1
        while fileManager.fileExists(atPath: filepath) {
            filepath = filepath + "\(i)"
            i += 1
        }

        if fileManager.createFile(atPath: filepath, contents: nil, attributes: nil) {
            print("[RightClickMenu] File created: \(filepath)")
            return
        }

        // Fallback: use AppleScript with administrator privileges
        let fullScript = "touch \(filepath)"
        let script = "do shell script \"\(fullScript)\" with administrator privileges"
        let appleScript = NSAppleScript(source: script)!
        var errorInfo: NSDictionary?
        _ = appleScript.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            let msg = String(format: Bundle.main.localizedString(forKey: "The current directory: %@ does not have write permission!", value: nil, table: nil), path)
            let alert = NSAlert()
            alert.messageText = msg
            alert.runModal()
        }
    }

    /// Open the given path in the default terminal app.
    public func openInTerminal(path: String) {
        let terminal = defaults.string(forKey: "userTerminal") ?? "Terminal"
        let cmd = "open -a \(terminal) '\(path)'"
        _ = runShell(cmd)
    }

    /// Copy the given file path to the general pasteboard.
    public func copyFilePath(path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    // MARK: - Distributed Notification Handlers

    @objc private func rootPathRequested(_ notif: Notification) {
        send("ObservingPathSetNotification", data: ["path": "/"])
        syncSharedDefaultsToFinderSyncExtension()
    }

    @objc private func customMessageReceivedFromFinder(_ notif: Notification) {
        guard let jsonString = notif.object as? String else { return }
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let operation = dict["operation"] as? String else { return }

        switch operation {
        case "newFile":
            newFile(path: dict["path"] as? String ?? "")
        case "openInTerminal":
            let items = dict["items"] as? String ?? ""
            openInTerminal(path: items.isEmpty ? (dict["path"] as? String ?? "") : items)
        case "copyFilePath":
            let items = dict["items"] as? String ?? ""
            copyFilePath(path: items.isEmpty ? (dict["path"] as? String ?? "") : items)
        default:
            break
        }
    }

    // MARK: - Private Helpers

    private func send(_ name: String, data: [String: Any]) {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name(name),
            object: Bundle.main.bundleIdentifier,
            userInfo: data,
            deliverImmediately: true
        )
    }

    @discardableResult
    private func runShell(_ command: String) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return 1
        }
    }
}
