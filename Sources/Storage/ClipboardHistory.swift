//
//  ClipboardHistory.swift
//  MacStroke
//
//  Clipboard history storage using SQLite.
//  Stores recent clipboard items with timestamps for quick access.
//

import Foundation
import SQLite

/// A single clipboard entry.
public struct ClipboardEntry: Codable {
    public let text: String
    public let timestamp: Date
    public let id: Int64

    public init(text: String, timestamp: Date = Date(), id: Int64 = 0) {
        self.text = text
        self.timestamp = timestamp
        self.id = id
    }
}

/// Manages clipboard history using SQLite.
public final class ClipboardHistoryManager {
    private let db: Connection?
    private let maxEntries: Int

    public init(maxEntries: Int = 50, databasePath: String? = nil) {
        self.maxEntries = maxEntries

        let path = databasePath ?? "\(NSHomeDirectory())/Library/Application Support/MacStroke/clipboard.db"
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true,
                attributes: nil
            )
            self.db = try Connection(path)
            createTable()
        } catch {
            print("[ClipboardHistory] Failed to create database: \(error)")
            self.db = nil
        }
    }

    private func createTable() {
        guard let db = db else { return }
        try? db.run(
            "CREATE TABLE IF NOT EXISTS clipboard (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, timestamp REAL)"
        )
    }

    /// Add a new clipboard entry.
    /// - Parameter text: The clipboard text to store
    public func add(_ text: String) {
        guard let db = db else { return }

        try? db.run(
            "INSERT INTO clipboard (text, timestamp) VALUES (?, ?)",
            text, Date().timeIntervalSince1970
        )

        // Enforce max entries
        prune()
    }

    /// Get the most recent clipboard entries.
    /// - Parameter limit: Maximum number of entries to return
    /// - Returns: Array of clipboard entries, most recent first
    public func recentEntries(limit: Int = 50) -> [ClipboardEntry] {
        guard let db = db else { return [] }

        var entries: [ClipboardEntry] = []
        let query = "SELECT id, text, timestamp FROM clipboard ORDER BY id DESC LIMIT ?"
        if let rows = try? db.prepare(query, limit) {
            for row in rows {
                let entry = ClipboardEntry(
                    text: row[1] as? String ?? "",
                    timestamp: Date(timeIntervalSince1970: row[2] as? Double ?? 0),
                    id: row[0] as? Int64 ?? 0
                )
                entries.append(entry)
            }
        }
        return entries
    }

    /// Remove entries beyond the max limit.
    private func prune() {
        guard let db = db else { return }
        try? db.run(
            "DELETE FROM clipboard WHERE id NOT IN (SELECT id FROM clipboard ORDER BY id DESC LIMIT ?)",
            maxEntries
        )
    }

    /// Clear all clipboard history.
    public func clear() {
        guard let db = db else { return }
        try? db.run("DELETE FROM clipboard")
    }

    /// Get the count of stored entries.
    public var entryCount: Int {
        guard let db = db else { return 0 }
        return (try? db.scalar("SELECT COUNT(*) FROM clipboard")) as? Int ?? 0
    }
}