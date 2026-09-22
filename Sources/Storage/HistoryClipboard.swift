//
//  HistoryClipboard.swift
//  MacStroke
//
//  Clipboard history storage using SQLite with top/favorites support.
//

import Foundation
import SQLite
import AppKit

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

    /// RAM mode still has to be one shared store: the clipboard monitor, the
    /// menu bar and the history window each build their own manager, so a
    /// private `:memory:` connection would show an empty list.
    static let ramDatabasePath = "file:macstroke_clipboard?mode=memory&cache=shared"

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

    // Timer for pasteboard monitoring
    private var timer: Timer?
    private var changeCount: Int = 0
    private var currentPage: Int = 0

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
        // Original has a single switch: `clipoardStroageLocal` false means RAM.
        let useRAM = !UserDefaults.standard.bool(forKey: UserDefaultsKey.clipoardStroageLocal.rawValue)
        let databasePath = useRAM ? Self.ramDatabasePath : Self.defaultDatabasePath
        self.init(databasePath: databasePath, userDefaults: UserDefaults.standard)
    }

    /// Initialize with custom database path (for testing)
    /// - Parameters:
    ///   - databasePath: Path to the SQLite database file, or the RAM URI
    ///   - userDefaults: UserDefaults instance (for testing)
    public init(databasePath: String, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if databasePath == Self.defaultDatabasePath {
            Self.migrateLegacyDatabaseIfNeeded(at: databasePath)
        }

        do {
            // The RAM "path" is a URI, not a file, so there's no parent directory to make.
            if databasePath != Self.ramDatabasePath {
                try FileManager.default.createDirectory(
                    atPath: (databasePath as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
            self.db = try Connection(databasePath)
            createTable()
        } catch {
            NSLog("%@", "[HistoryClipboard] Failed to create database: \(error)")
            self.db = nil
        }
    }

    /// The original ObjC MacStroke kept the same `local_history_clipoard`
    /// table in ~/Library/Caches/MacStroke/database.sqlite; adopt that file
    /// on first launch so existing clipboard history carries over.
    private static func migrateLegacyDatabaseIfNeeded(at path: String) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return }
        let legacy = "\(NSHomeDirectory())/Library/Caches/MacStroke/database.sqlite"
        guard fm.fileExists(atPath: legacy) else { return }
        try? fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? fm.copyItem(atPath: legacy, toPath: path)
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
            NSLog("%@", "[HistoryClipboard] Failed to create table: \(error)")
        }
    }

    // MARK: - Internal Methods (lock-free, assume lock is held by caller)

    private func insertLocalHistoryClipboardInternal(content: String, isTop: Bool) -> HistoryClipboardEntry? {
        guard let db = db else { return nil }

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
            NSLog("%@", "[HistoryClipboard] Failed to insert: \(error)")
            return nil
        }
    }

    private func selectLocalHistoryClipoardIsTopInternal(isTop: Bool, start: Int, end: Int) -> [HistoryClipboardEntry] {
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
            NSLog("%@", "[HistoryClipboard] Failed to select: \(error)")
        }

        return entries
    }

    private func getCountInternal(isTop: Bool) -> Int {
        guard let db = db else { return 0 }
        let isTopValue = isTop ? Int64(1) : Int64(0)

        do {
            let count = try db.scalar(table.filter(isTopCol == isTopValue).count)
            return count
        } catch {
            NSLog("%@", "[HistoryClipboard] Failed to get count: \(error)")
            return 0
        }
    }

    @discardableResult
    private func deleteEarliestItemInternal(isTop: Bool) -> Bool {
        guard let db = db else { return false }
        let isTopValue = isTop ? Int64(1) : Int64(0)

        do {
            let query = table
                .filter(isTopCol == isTopValue)
                .order(idCol.asc)
                .limit(1)

            // Original returns the exec result, so a no-op delete still succeeds.
            try db.run(query.delete())
            return true
        } catch {
            NSLog("%@", "[HistoryClipboard] Failed to delete earliest: \(error)")
            return false
        }
    }

    @discardableResult
    private func deleteExpiredHistoryInternal(days: Int) -> Bool {
        guard let db = db else { return false }

        let cutoffTime = Date().timeIntervalSince1970 - TimeInterval(days * 24 * 60 * 60)

        do {
            // Original SQL: `WHERE is_top=0 AND create_time < cutoff` — pinned
            // entries are never expired away.
            try db.run(table.filter(isTopCol == 0 && createTimeCol < cutoffTime).delete())
            return true
        } catch {
            NSLog("%@", "[HistoryClipboard] Failed to delete expired: \(error)")
            return false
        }
    }

    @discardableResult
    private func clearHistoryListInternal() -> Bool {
        guard let db = db else { return false }

        do {
            try db.run(table.filter(isTopCol == 0).delete())
            return true
        } catch {
            NSLog("%@", "[HistoryClipboard] Failed to clear history: \(error)")
            return false
        }
    }

    private func clearTopInternal() {
        guard let db = db else { return }

        do {
            try db.run(table.filter(isTopCol == 1).delete())
        } catch {
            NSLog("%@", "[HistoryClipboard] Failed to clear top: \(error)")
        }
    }

    private func clearAllInternal() {
        guard let db = db else { return }

        do {
            try db.run(table.delete())
            try db.run("DELETE FROM sqlite_sequence WHERE name = ?", Self.tableName)
        } catch {
            NSLog("%@", "[HistoryClipboard] Failed to clear all: \(error)")
        }
    }

    private var topCountInternal: Int {
        return getCountInternal(isTop: true)
    }

    /// Internal: enforce all limits (assumes lock is held).
    /// Mirrors the original `deleteExpired`: the pinned-count trim always runs,
    /// the total-count and age trims only apply to local storage.
    private func enforceLimits() {
        let storageLocal = userDefaults.bool(forKey: UserDefaultsKey.clipoardStroageLocal.rawValue)
        let enableLimitTotal = userDefaults.bool(forKey: UserDefaultsKey.enableLimitTotal.rawValue)
        let limitTotal = userDefaults.integer(forKey: UserDefaultsKey.limitTotal.rawValue)
        let enableLimitTop = userDefaults.bool(forKey: UserDefaultsKey.enableLimitTop.rawValue)
        let limitTop = userDefaults.integer(forKey: UserDefaultsKey.limitTop.rawValue)
        let enableLimitSaveDays = userDefaults.bool(forKey: UserDefaultsKey.enableLimitSaveDays.rawValue)
        let limitSaveDays = userDefaults.integer(forKey: UserDefaultsKey.limitSaveDays.rawValue)

        // Enforce top count limit
        if enableLimitTop && limitTop > 0 {
            let topCount = getCountInternal(isTop: true)
            if topCount > limitTop {
                let excess = topCount - limitTop
                for _ in 0..<excess {
                    guard deleteEarliestItemInternal(isTop: true) else { break }
                }
            }
        }

        guard storageLocal else { return }

        // Enforce total count limit
        if enableLimitTotal && limitTotal > 0 {
            let totalCount = getCountInternal(isTop: false)
            if totalCount > limitTotal {
                let excess = totalCount - limitTotal
                for _ in 0..<excess {
                    guard deleteEarliestItemInternal(isTop: false) else { break }
                }
            }
        }

        // Enforce expiry by days (0 days wipes every unpinned entry — original quirk)
        if enableLimitSaveDays {
            _ = deleteExpiredHistoryInternal(days: limitSaveDays)
        }
    }

    /// Internal: get top list (assumes lock is held)
    private func getTopListInternal() -> [HistoryClipboardEntry] {
        return selectLocalHistoryClipoardIsTopInternal(isTop: true, start: 0, end: 1000)
    }

    // MARK: - Public Methods (lock around internal methods)

    /// Insert a new clipboard entry
    @discardableResult
    public func insertLocalHistoryClipboard(content: String, isTop: Bool) -> HistoryClipboardEntry? {
        lock.lock()
        defer { lock.unlock() }
        return insertLocalHistoryClipboardInternal(content: content, isTop: isTop)
    }

    /// Select clipboard entries filtered by isTop flag with pagination
    public func selectLocalHistoryClipoardIsTop(isTop: Bool, start: Int, end: Int) -> [HistoryClipboardEntry] {
        lock.lock()
        defer { lock.unlock() }
        return selectLocalHistoryClipoardIsTopInternal(isTop: isTop, start: start, end: end)
    }

    /// Get count of entries filtered by isTop flag
    public func getCount(isTop: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return getCountInternal(isTop: isTop)
    }

    /// Delete the earliest (oldest) entry for the given isTop filter
    @discardableResult
    public func deleteEarliestItem(isTop: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deleteEarliestItemInternal(isTop: isTop)
    }

    /// Delete entries older than the specified number of days
    @discardableResult
    public func deleteExpiredHistory(days: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deleteExpiredHistoryInternal(days: days)
    }

    /// Clear all non-top (history) entries
    @discardableResult
    public func clearHistoryList() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clearHistoryListInternal()
    }

    /// Clear all top/pinned entries
    public func clearTop() {
        lock.lock()
        defer { lock.unlock() }
        clearTopInternal()
    }

    /// Clear all entries and reset autoincrement sequence
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        clearAllInternal()
    }

    /// Get the count of top/pinned entries
    public var topCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return topCountInternal
    }

    // MARK: - Pasteboard Timer Integration

    /// Enable/disable clipboard history monitoring
    @discardableResult
    public func enableHistoryClipboard() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let enabled = userDefaults.bool(forKey: UserDefaultsKey.enableHistoryClipboard.rawValue)

        // Original only checks `enableHistoryClipboard`: monitoring runs in RAM
        // mode too, the storage switch just decides where entries live.
        if enabled {
            // Invalidate existing timer if running
            timer?.invalidate()

            // Initialize change count from pasteboard
            changeCount = NSPasteboard.general.changeCount

            // Create and start timer (0.5s interval)
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.handleTimer()
            }

            // Ensure timer runs in common modes
            if let timer = timer {
                RunLoop.main.add(timer, forMode: .common)
            }

            // Run initial expiry cleanup (lock already held)
            enforceLimits()

            return true
        } else {
            timer?.invalidate()
            timer = nil
            return false
        }
    }

    /// Timer callback to check for pasteboard changes (assumes lock NOT held; acquires it)
    private func handleTimer() {
        lock.lock()
        defer { lock.unlock() }

        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard currentChangeCount > changeCount else { return }

        // Original asks the pasteboard type list for an exact string membership.
        if pasteboard.types?.contains(.string) ?? false {
            let content = pasteboard.string(forType: .string) ?? ""
            if insertLocalHistoryClipboardInternal(content: content, isTop: false) != nil {
                cropTotalAfterInsert()
            }
        }

        changeCount = currentChangeCount
    }

    /// On insert the original trims just one earliest history row, and only in
    /// local storage mode (`handleTimer` → `STROAGE_LOCAL` branch).
    private func cropTotalAfterInsert() {
        guard userDefaults.bool(forKey: UserDefaultsKey.clipoardStroageLocal.rawValue) else { return }
        let enableLimitTotal = userDefaults.bool(forKey: UserDefaultsKey.enableLimitTotal.rawValue)
        let limitTotal = userDefaults.integer(forKey: UserDefaultsKey.limitTotal.rawValue)
        guard enableLimitTotal && limitTotal > 0 else { return }
        if getCountInternal(isTop: false) > limitTotal {
            _ = deleteEarliestItemInternal(isTop: false)
        }
    }

    /// Get combined history list (top entries + history entries) with pagination
    public func getHistoryClipboardList(firstPage: Bool) -> [HistoryClipboardEntry] {
        lock.lock()
        defer { lock.unlock() }

        var result: [HistoryClipboardEntry] = []

        let topEntries = getTopListInternal()
        result.append(contentsOf: topEntries)

        if firstPage {
            currentPage = 0
        }

        let historyEntries = selectLocalHistoryClipoardIsTopInternal(
            isTop: false,
            start: currentPage * Self.pageSize,
            end: Self.pageSize
        )
        result.append(contentsOf: historyEntries)

        return result
    }

    /// Get all top/pinned entries
    public func getTopList() -> [HistoryClipboardEntry] {
        lock.lock()
        defer { lock.unlock() }
        return getTopListInternal()
    }

    /// Load next page of history entries
    public func nextPage(currentHistoryCount: Int) -> [HistoryClipboardEntry] {
        lock.lock()
        defer { lock.unlock() }

        currentPage += 1
        return selectLocalHistoryClipoardIsTopInternal(
            isTop: false,
            start: currentPage * Self.pageSize,
            end: Self.pageSize
        )
    }

    /// Add a new top/pinned entry
    @discardableResult
    public func addTop(content: String) -> HistoryClipboardEntry? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = insertLocalHistoryClipboardInternal(content: content, isTop: true) else {
            return nil
        }

        let enableLimitTop = userDefaults.bool(forKey: UserDefaultsKey.enableLimitTop.rawValue)
        let limitTop = userDefaults.integer(forKey: UserDefaultsKey.limitTop.rawValue)

        if enableLimitTop && limitTop > 0 {
            let topCount = getCountInternal(isTop: true)
            if topCount > limitTop {
                let excess = topCount - limitTop
                for _ in 0..<excess {
                    guard deleteEarliestItemInternal(isTop: true) else { break }
                }
            }
        }

        return entry
    }

    /// Remove a top/pinned entry by its index in the top list
    public func removeTop(at index: Int) {
        lock.lock()
        defer { lock.unlock() }

        let topEntries = getTopListInternal()
        guard index >= 0 && index < topEntries.count else { return }

        let entryToRemove = topEntries[index]
        guard let db = db else { return }

        do {
            try db.run(table.filter(idCol == entryToRemove.id).delete())
        } catch {
            NSLog("%@", "[HistoryClipboard] Failed to remove top entry: \(error)")
        }
    }

    /// Delete expired entries based on all limit settings (lock already held by caller; public wrapper acquires it)
    public func deleteExpired() {
        lock.lock()
        defer { lock.unlock() }
        enforceLimits()
    }

    /// Stop clipboard history monitoring and invalidate timer
    public func stopHistoryClipboard() {
        lock.lock()
        defer { lock.unlock() }

        timer?.invalidate()
        timer = nil
    }

    /// Clean up timer on deinit
    deinit {
        timer?.invalidate()
        timer = nil
    }
}
