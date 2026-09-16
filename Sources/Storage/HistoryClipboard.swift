//
//  HistoryClipboard.swift
//  MacStroke
//
//  Clipboard history storage using SQLite with top/favorites support.
//  Data layer only - no pasteboard timer logic.
//

import Foundation
import SQLite

/// A single clipboard history entry.
public struct HistoryClipboardEntry: Codable, Equatable {
    public let id: Int64
    public let content: String  // Base64 encoded
    public let isTop: Bool
    public let createTime: TimeInterval
    public let modifyTime: TimeInterval

    public init(id: Int64, content: String, isTop: Bool, createTime: TimeInterval, modifyTime: TimeInterval) {
        self.id = id
        self.content = content
        self.isTop = isTop
        self.createTime = createTime
        self.modifyTime = modifyTime
    }
}

/// Manages clipboard history with SQLite storage.
/// Thread-safe implementation with NSLock.
public final class HistoryClipboardManager {
    // MARK: - Constants

    /// Default database path
    private static let defaultDatabasePath = "\(NSHomeDirectory())/Library/Application Support/MacStroke/clipboard.db"

    /// Table name
    private static let tableName = "local_history_clipoard"

    /// Page size for pagination
    public static let pageSize = 30

    // MARK: - UserDefaults Keys

    public enum UserDefaultsKey: String {
        case clipoardStroageLocal = "clipoardStroageLocal"
        case enableLimitTop = "enableLimitTop"
        case limitTop = "limitTop"
        case enableLimitTotal = "enableLimitTotal"
        case limitTotal = "limitTotal"
        case enableLimitSaveDays = "enableLimitSaveDays"
        case limitSaveDays = "limitSaveDays"
        case enableHistoryClipboard = "enableHistoryClipboard"
    }

    // MARK: - Private Properties

    private let db: Connection?
    private let lock = NSLock()
    private let userDefaults: UserDefaults

    // MARK: - SQLite Expressions

    private let table = Table(tableName)
    private let idCol = Expression<Int64>("id")
    private let contentCol = Expression<String>("content")
    private let isTopCol = Expression<Int64>("is_top")
    private let createTimeCol = Expression<Double>("create_time")
    private let modifyTimeCol = Expression<Double>("modify_time")

    // MARK: - Initialization

    /// Initialize with default database path
    public convenience init() {
        self.init(databasePath: Self.defaultDatabasePath, userDefaults: .standard)
    }

    /// Initialize with custom database path (for testing)
    /// - Parameters:
    ///   - databasePath: Path to the SQLite database file
    ///   - userDefaults: UserDefaults instance (for testing)
    public init(databasePath: String, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        do {
            try FileManager.default.createDirectory(
                atPath: (databasePath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true,
                attributes: nil
            )
            self.db = try Connection(databasePath)
            createTable()
        } catch {
            print("[HistoryClipboard] Failed to create database: \(error)")
            self.db = nil
        }
    }

    /// Create the history table if it doesn't exist
    private func createTable() {
        guard let db = db else { return }
        do {
            try db.run(table.create(ifNotExists: true) { t in
                t.column(idCol, primaryKey: .autoincrement)
                t.column(contentCol)
                t.column(isTopCol)
                t.column(createTimeCol)
                t.column(modifyTimeCol)
            })
            // Create index for faster queries
            try db.run(table.createIndex(isTopCol, ifNotExists: true))
        } catch {
            print("[HistoryClipboard] Failed to create table: \(error)")
        }
    }

    // MARK: - Public Methods

    /// Insert a new clipboard entry
    /// - Parameters:
    ///   - content: The clipboard content (will be base64 encoded)
    ///   - isTop: Whether this is a pinned/top entry
    /// - Returns: The created HistoryClipboardEntry, or nil if failed
    @discardableResult
    public func insertLocalHistoryClipboard(content: String, isTop: Bool) -> HistoryClipboardEntry? {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return nil }

        // Base64 encode the content
        let base64Content = content.data(using: .utf8)?.base64EncodedString() ?? ""
        let now = Date().timeIntervalSince1970
        let isTopValue = isTop ? Int64(1) : Int64(0)

        do {
            let rowId = try db.run(table.insert(
                contentCol <- base64Content,
                isTopCol <- isTopValue,
                createTimeCol <- now,
                modifyTimeCol <- now
            ))

            return HistoryClipboardEntry(
                id: rowId,
                content: base64Content,
                isTop: isTop,
                createTime: now,
                modifyTime: now
            )
        } catch {
            print("[HistoryClipboard] Failed to insert: \(error)")
            return nil
        }
    }

    /// Select clipboard entries filtered by isTop flag with pagination
    /// - Parameters:
    ///   - isTop: Filter by top/pinned status
    ///   - start: Offset (0-based)
    ///   - end: Limit (number of items to return)
    /// - Returns: Array of HistoryClipboardEntry ordered by id DESC
    public func selectLocalHistoryClipoardIsTop(isTop: Bool, start: Int, end: Int) -> [HistoryClipboardEntry] {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return [] }
        let isTopValue = isTop ? Int64(1) : Int64(0)

        var entries: [HistoryClipboardEntry] = []

        do {
            let query = table
                .filter(isTopCol == isTopValue)
                .order(idCol.desc)
                .limit(end, offset: start)

            for row in try db.prepare(query) {
                let entry = HistoryClipboardEntry(
                    id: row[idCol],
                    content: row[contentCol],
                    isTop: row[isTopCol] == 1,
                    createTime: row[createTimeCol],
                    modifyTime: row[modifyTimeCol]
                )
                entries.append(entry)
            }
        } catch {
            print("[HistoryClipboard] Failed to select: \(error)")
        }

        return entries
    }

    /// Get count of entries filtered by isTop flag
    /// - Parameter isTop: Filter by top/pinned status
    /// - Returns: Number of entries
    public func getCount(isTop: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return 0 }
        let isTopValue = isTop ? Int64(1) : Int64(0)

        do {
            let count = try db.scalar(table.filter(isTopCol == isTopValue).count)
            return count
        } catch {
            print("[HistoryClipboard] Failed to get count: \(error)")
            return 0
        }
    }

    /// Delete the earliest (oldest) entry for the given isTop filter
    /// - Parameter isTop: Filter by top/pinned status
    /// - Returns: true if an entry was deleted
    @discardableResult
    public func deleteEarliestItem(isTop: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return false }
        let isTopValue = isTop ? Int64(1) : Int64(0)

        do {
            let query = table
                .filter(isTopCol == isTopValue)
                .order(idCol.asc)
                .limit(1)

            let deleted = try db.run(query.delete())
            return deleted > 0
        } catch {
            print("[HistoryClipboard] Failed to delete earliest: \(error)")
            return false
        }
    }

    /// Delete entries older than the specified number of days
    /// - Parameter days: Number of days to keep (entries older than this will be deleted)
    /// - Returns: true if any entries were deleted
    @discardableResult
    public func deleteExpiredHistory(days: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return false }

        let cutoffTime = Date().timeIntervalSince1970 - TimeInterval(days * 24 * 60 * 60)

        do {
            let deleted = try db.run(table.filter(createTimeCol < cutoffTime).delete())
            return deleted > 0
        } catch {
            print("[HistoryClipboard] Failed to delete expired: \(error)")
            return false
        }
    }

    /// Clear all non-top (history) entries
    /// - Returns: true if any entries were deleted
    @discardableResult
    public func clearHistoryList() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return false }

        do {
            let deleted = try db.run(table.filter(isTopCol == 0).delete())
            return deleted > 0
        } catch {
            print("[HistoryClipboard] Failed to clear history: \(error)")
            return false
        }
    }

    /// Clear all top/pinned entries
    public func clearTop() {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return }

        do {
            try db.run(table.filter(isTopCol == 1).delete())
        } catch {
            print("[HistoryClipboard] Failed to clear top: \(error)")
        }
    }

    /// Clear all entries and reset autoincrement sequence
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        guard let db = db else { return }

        do {
            try db.run(table.delete())
            // Reset the autoincrement sequence
            try db.run("DELETE FROM sqlite_sequence WHERE name = ?", Self.tableName)
        } catch {
            print("[HistoryClipboard] Failed to clear all: \(error)")
        }
    }

    /// Get the count of top/pinned entries
    public var topCount: Int {
        return getCount(isTop: true)
    }
}