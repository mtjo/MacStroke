//
//  AppleScriptsList.swift
//  MacStroke
//
//  Manages a list of user-defined AppleScripts with persistence.
//

import Foundation

/// Represents a user-defined AppleScript with metadata.
public struct AppleScriptItem: Codable, Equatable, Sendable {
    /// Unique identifier for the script
    public let id: UUID
    /// Human-readable name/title of the script
    public let name: String
    /// The AppleScript source code
    public let source: String
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

/// Thread-safe singleton class for managing a collection of AppleScripts with persistence.
public final class AppleScriptsList: @unchecked Sendable {
    /// Shared singleton instance
    public static let sharedAppleScriptsList = AppleScriptsList()

    /// The file URL for persistent storage
    private let storageURL: URL

    /// Internal storage for scripts
    private var scripts: [AppleScriptItem] = []

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Private initializer for singleton pattern
    private init() {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let macStrokeDir = appSupportURL.appendingPathComponent("MacStroke", isDirectory: true)
        self.storageURL = macStrokeDir.appendingPathComponent("appleScripts.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: macStrokeDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Load existing scripts
        load()
    }

    /// Number of scripts in the list
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return scripts.count
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

    /// Get all scripts as an array
    /// - Returns: Array of all AppleScriptItems, sorted by creation time (newest first)
    public func getAllScripts() -> [AppleScriptItem] {
        lock.lock()
        defer { lock.unlock() }
        return scripts.sorted { $0.createTime > $1.createTime }
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
            print("[AppleScriptsList] Failed to save scripts: \(error)")
        }
    }

    /// Load scripts from disk
    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
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
            print("[AppleScriptsList] Failed to load scripts: \(error)")
            // Don't overwrite existing scripts on load failure
        }
    }
}