//
//  AppleScriptsList.swift
//  MacStroke
//
//  Manages a list of user-defined AppleScripts with persistence.
//

import Foundation
import Combine

/// Represents a user-defined AppleScript with metadata.
public struct AppleScriptItem: Codable, Equatable, Sendable, Identifiable {
    /// Unique identifier for the script (original: `id`, a globally unique string)
    public let id: UUID
    /// Human-readable name/title of the script
    public var name: String
    /// The AppleScript source code
    public var source: String
    /// Timestamp when the script was created
    public let createTime: Date

    /// Create a new AppleScript item.
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided)
    ///   - name: Human-readable name for the script
    ///   - source: The AppleScript source code
    ///   - createTime: Creation timestamp (defaults to now)
    public init(
        id: UUID = UUID(),
        name: String,
        source: String,
        createTime: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.createTime = createTime
    }
}

/// Shared script list (original: `[AppleScriptsList sharedAppleScriptsList]`).
/// Observable so the preferences window redraws when scripts are added,
/// renamed or removed; every mutation persists immediately (`save`).
public final class AppleScriptsList: ObservableObject, @unchecked Sendable {
    /// Shared singleton instance
    public static let sharedAppleScriptsList = AppleScriptsList()

    public let objectWillChange = ObservableObjectPublisher()

    /// The file URL for persistent storage
    private let storageURL: URL

    /// Internal storage for scripts, kept in insertion order
    private var scripts: [AppleScriptItem] = []

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Private initializer for singleton pattern
    private init() {
        guard let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            // Fallback to temporary directory if Application Support is unavailable
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacStroke", isDirectory: true)
            self.storageURL = tempDir.appendingPathComponent("appleScripts.json")
            try? FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return
        }
        let macStrokeDir = appSupportURL.appendingPathComponent("MacStroke", isDirectory: true)
        self.storageURL = macStrokeDir.appendingPathComponent("appleScripts.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: macStrokeDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        importLegacyUserDefaultsScripts()
        // Load existing scripts
        load()
    }

    /// Internal initializer for testing with custom storage URL
    /// - Parameter storageURL: Custom file URL for persistence (used in tests)
    internal init(storageURL: URL) {
        self.storageURL = storageURL
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        load()
    }

    /// Number of scripts in the list
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return scripts.count
    }

    /// Title of the script at `index` (original: `titleAtIndex:`)
    public func title(at index: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return scripts[index].name
    }

    /// Source of the script at `index` (original: `scriptAtIndex:`)
    public func script(at index: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return scripts[index].source
    }

    /// Identifier of the script at `index` (original: `idAtIndex:`)
    public func id(at index: Int) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return scripts[index].id
    }

    /// Position of a script by id, or nil (original: `getIndexById:` returning -1)
    public func index(of id: UUID) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return scripts.firstIndex { $0.id == id }
    }

    /// Rename a script (original: `setTitleAtIndex:title:` — mutates in place;
    /// the caller persists when the field editor closes).
    /// No republish: the inline field already shows the new title.
    public func setTitle(at index: Int, _ title: String) {
        mutate(at: index, notify: false, persist: false) { $0.name = title }
    }

    /// Replace a script's source (original: `setScriptAtIndex:script:` — mutate
    /// only, `save` happens when editing ends). Does not republish: the caller is
    /// the very field showing that source, and re-rendering it mid-edit drops
    /// the caret.
    public func setScript(at index: Int, _ script: String, notify: Bool = false) {
        mutate(at: index, notify: notify, persist: false) { $0.source = script }
    }

    /// Remove the script at `index` (original: `removeAtIndex:` + `save`)
    public func remove(at index: Int) {
        lock.lock()
        guard scripts.indices.contains(index) else {
            lock.unlock()
            return
        }
        scripts.remove(at: index)
        lock.unlock()
        objectWillChange.send()
        save()
    }

    /// Add a new script to the list
    /// - Parameters:
    ///   - name: The name/title of the script
    ///   - source: The AppleScript source code
    /// - Returns: The created AppleScriptItem
    @discardableResult
    public func addScript(name: String, source: String) -> AppleScriptItem {
        let item = AppleScriptItem(name: name, source: source)
        lock.lock()
        scripts.append(item)
        lock.unlock()
        objectWillChange.send()
        save()
        return item
    }

    /// Remove a script by its ID
    /// - Parameter id: The UUID of the script to remove
    /// - Returns: True if a script was removed, false if not found
    @discardableResult
    public func removeScript(id: UUID) -> Bool {
        lock.lock()
        let initialCount = scripts.count
        scripts.removeAll { $0.id == id }
        let removed = scripts.count < initialCount
        lock.unlock()
        if removed {
            objectWillChange.send()
            save()
        }
        return removed
    }

    /// Get a script by its ID
    /// - Parameter id: The UUID of the script to retrieve
    /// - Returns: The AppleScriptItem if found, nil otherwise
    public func getScriptById(id: UUID) -> AppleScriptItem? {
        lock.lock()
        defer { lock.unlock() }
        return scripts.first { $0.id == id }
    }

    /// Get all scripts as an array, in insertion order
    /// (original: the table simply indexes `_appleScriptsList`).
    /// - Returns: Array of all AppleScriptItems
    public func getAllScripts() -> [AppleScriptItem] {
        lock.lock()
        defer { lock.unlock() }
        return scripts
    }

    private func mutate(at index: Int,
                        notify: Bool = true,
                        persist: Bool = true,
                        _ change: (inout AppleScriptItem) -> Void) {
        lock.lock()
        guard scripts.indices.contains(index) else {
            lock.unlock()
            return
        }
        change(&scripts[index])
        lock.unlock()
        if notify {
            objectWillChange.send()
        }
        if persist {
            save()
        }
    }

    /// Persist the current scripts to disk
    public func save() {
        lock.lock()
        let scriptsToSave = scripts
        lock.unlock()

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(scriptsToSave)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Log error but don't crash - persistence failure shouldn't break the app
            NSLog("%@", "[AppleScriptsList] Failed to save scripts: \(error)")
        }
    }

    /// One-time import of the ObjC build's storage. It archived an array of
    /// `{title, script, id}` dictionaries into `UserDefaults["appleScripts"]`,
    /// while this port keeps a JSON file; the legacy ids are dropped because
    /// rules are not read from UserDefaults, so nothing can reference them.
    private func importLegacyUserDefaultsScripts() {
        let key = "appleScripts"
        guard !FileManager.default.fileExists(atPath: storageURL.path),
              let data = UserDefaults.standard.object(forKey: key) as? Data,
              let imported = Self.scripts(fromLegacyArchive: data), !imported.isEmpty else { return }
        scripts = imported
        save()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.synchronize()
    }

    /// Decode the ObjC build's archived script dictionaries (`nil` when the
    /// blob holds something else).
    static func scripts(fromLegacyArchive data: Data) -> [AppleScriptItem]? {
        guard let archived = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, NSDictionary.self, NSString.self], from: data)
        else { return nil }
        guard let dictionaries = archived as? [[String: String]] else { return nil }
        return dictionaries.map { AppleScriptItem(name: $0["title"] ?? "", source: $0["script"] ?? "") }
    }

    /// Load scripts from disk
    private func load() {        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loadedScripts = try decoder.decode([AppleScriptItem].self, from: data)
            lock.lock()
            scripts = loadedScripts
            lock.unlock()
        } catch {
            NSLog("%@", "[AppleScriptsList] Failed to load scripts: \(error)")
            // Don't overwrite existing scripts on load failure
        }
    }
}