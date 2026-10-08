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
    private var root: URL?
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
        requestObservingPath()
        retryObservingPathRequest(after: 5, attemptsLeft: 11)
    }

    private func requestObservingPath() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("RequestObservingPathNotification"),
            object: Self.mainAppBundleID,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// When Finder starts this extension at login the main app may not have
    /// registered its notification listeners yet, so the first request is
    /// dropped and we are left with no observed directory — which means Finder
    /// never even asks us for a menu. Keep asking until a root arrives.
    private func retryObservingPathRequest(after delay: TimeInterval, attemptsLeft: Int) {
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.root == nil else { return }
            self.requestObservingPath()
            self.retryObservingPathRequest(after: delay, attemptsLeft: attemptsLeft - 1)
        }
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
        sharedDefaults.set(intFlag(data["enableRightClickMenu"]) != 0, forKey: "enableRightClickMenu")
        sharedDefaults.set(intFlag(data["enableNewFile"]) != 0, forKey: "enableNewFile")
        sharedDefaults.set(intFlag(data["enableOpenInTerminal"]) != 0, forKey: "enableOpenInTerminal")
        sharedDefaults.set(intFlag(data["enableCopyFilePath"]) != 0, forKey: "enableCopyFilePath")
        if let items = data["items"] as? String {
            sharedDefaults.set(items, forKey: "items")
        }
        sharedDefaults.synchronize()
        defaultsChanged()
    }

    /// Original uses `intValue` on the payload, which accepts both the "1"/"0"
    /// strings the main app sends and plain numbers.
    private func intFlag(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int((string as NSString).intValue) }
        return 0
    }

    /// Receive the observing root from the main app (original: `setRoot:`, which
    /// also keeps the last value so a repeat broadcast is a no-op).
    @objc private func observingPathSet(_ notification: Notification) {
        guard let path = notification.userInfo?["path"] as? String else { return }
        let url = URL(fileURLWithPath: path)
        guard url != root else { return }
        root = url
        FIFinderSyncController.default().directoryURLs = [url]
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
                menu.addItem(withTitle: items[0], action: #selector(newFile(_:)), keyEquivalent: "")
                    .image = menuIcon("doc.badge.plus")
            }
            if enableOpenInTerminal, items.count > 1 {
                menu.addItem(withTitle: items[1], action: #selector(openInTerminal(_:)), keyEquivalent: "")
                    .image = menuIcon("terminal")
            }
            if enableCopyFilePath, items.count > 2 {
                menu.addItem(withTitle: items[2], action: #selector(copyFilePath(_:)), keyEquivalent: "")
                    .image = menuIcon("doc.on.clipboard")
            }
        }
        return menu
    }

    /// Finder paints an extension's menu icon exactly as handed over — it ignores
    /// `isTemplate` there — so the glyph has to arrive already coloured. `labelColor`
    /// in the current system appearance is the ink Finder draws the menu's own text
    /// with, so light and dark each get their own rasterisation instead of a second
    /// asset set. `menu(for:)` runs on every right-click, so switching appearance
    /// is picked up by the next menu without restarting the extension.
    private func menuIcon(_ symbol: String) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let side: CGFloat = 16
        let ink = Self.menuInkColor()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let tinted = glyph.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        ) ?? glyph
        // Draw at the symbol's own size: scaling a 13pt glyph up to fill the box
        // thickens its strokes, which is what made these three look heavier than
        // Finder's own menu icons.
        let natural = tinted.size
        let fit = min(1, side / max(natural.width, natural.height))
        let target = NSSize(width: natural.width * fit, height: natural.height * fit)
        tinted.draw(
            in: NSRect(x: (side - target.width) / 2, y: (side - target.height) / 2,
                       width: target.width, height: target.height),
            from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// The colour this menu's text is drawn in, resolved to fixed RGB under the
    /// system appearance. Left dynamic it would flatten to light-mode black when
    /// the image is encoded for the trip to Finder's process.
    private static func menuInkColor() -> NSColor {
        var color = NSColor.labelColor
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? NSColor.labelColor
        }
        return color
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