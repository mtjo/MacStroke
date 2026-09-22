//
//  HistoryClipboardTests.swift
//  MacStroke
//
//  Tests for HistoryClipboard data layer.
//

import XCTest
import AppKit
@testable import Storage
import SQLite

final class HistoryClipboardTests: XCTestCase {

    // MARK: - Test Helpers

    private func getTestDatabasePath() -> String {
        let tempDir = NSTemporaryDirectory()
        let uuid = UUID().uuidString
        return "\(tempDir)history_clipboard_test_\(uuid).db"
    }

    private func createManager() -> HistoryClipboardManager {
        return HistoryClipboardManager(databasePath: getTestDatabasePath())
    }

    /// 固定 suite 名并在每个用例前清空：随机 UUID 会往 ~/Library/Preferences
    /// 里留下成百上千个测试 plist。
    private static let suiteName = "MacStrokeTests.HistoryClipboard"

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    override func setUp() {
        super.setUp()
        let defaults = isolatedDefaults()
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    // MARK: - Insert Tests

    func testInsertAndRetrieveSingleEntry() {
        let manager = createManager()

        let entry = manager.insertLocalHistoryClipboard(content: "Hello, World!", isTop: false)

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.content, "Hello, World!".data(using: .utf8)?.base64EncodedString())
        XCTAssertFalse(entry?.isTop ?? true)
        XCTAssertGreaterThan(entry?.id ?? 0, 0)
        XCTAssertGreaterThan(entry?.createTime ?? 0, 0)
        XCTAssertEqual(entry?.createTime, entry?.modifyTime)
    }

    func testInsertTopEntry() {
        let manager = createManager()

        let entry = manager.insertLocalHistoryClipboard(content: "Pinned item", isTop: true)

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isTop ?? false)
    }

    func testInsertEmptyContent() {
        let manager = createManager()

        let entry = manager.insertLocalHistoryClipboard(content: "", isTop: false)

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.content, "")
    }

    func testInsertUnicodeContent() {
        let manager = createManager()

        let unicodeContent = "🎉 Hello 世界 🌍"
        let entry = manager.insertLocalHistoryClipboard(content: unicodeContent, isTop: false)

        XCTAssertNotNil(entry)
        let expectedBase64 = unicodeContent.data(using: .utf8)?.base64EncodedString()
        XCTAssertEqual(entry?.content, expectedBase64)
    }

    // MARK: - Select Tests

    func testSelectHistoryEntries() {
        let manager = createManager()

        manager.insertLocalHistoryClipboard(content: "First", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Second", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Third", isTop: false)

        let entries = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)

        XCTAssertEqual(entries.count, 3)
        // Should be ordered by id DESC (newest first)
        XCTAssertEqual(entries[0].content, "Third".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(entries[1].content, "Second".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(entries[2].content, "First".data(using: .utf8)?.base64EncodedString())
    }

    func testSelectTopEntries() {
        let manager = createManager()

        manager.insertLocalHistoryClipboard(content: "History 1", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Top 1", isTop: true)
        manager.insertLocalHistoryClipboard(content: "History 2", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Top 2", isTop: true)

        let topEntries = manager.selectLocalHistoryClipoardIsTop(isTop: true, start: 0, end: 10)
        let historyEntries = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)

        XCTAssertEqual(topEntries.count, 2)
        XCTAssertEqual(historyEntries.count, 2)
        // Top entries should be newest first
        XCTAssertEqual(topEntries[0].content, "Top 2".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(topEntries[1].content, "Top 1".data(using: .utf8)?.base64EncodedString())
    }

    func testSelectWithPagination() {
        let manager = createManager()

        for i in 1...5 {
            manager.insertLocalHistoryClipboard(content: "Item \(i)", isTop: false)
        }

        // First page (2 items)
        let page1 = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 2)
        XCTAssertEqual(page1.count, 2)
        XCTAssertEqual(page1[0].content, "Item 5".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(page1[1].content, "Item 4".data(using: .utf8)?.base64EncodedString())

        // Second page (2 items)
        let page2 = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 2, end: 2)
        XCTAssertEqual(page2.count, 2)
        XCTAssertEqual(page2[0].content, "Item 3".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(page2[1].content, "Item 2".data(using: .utf8)?.base64EncodedString())

        // Third page (1 item)
        let page3 = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 4, end: 2)
        XCTAssertEqual(page3.count, 1)
        XCTAssertEqual(page3[0].content, "Item 1".data(using: .utf8)?.base64EncodedString())
    }

    func testSelectEmptyDatabase() {
        let manager = createManager()

        let entries = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)

        XCTAssertEqual(entries.count, 0)
    }

    // MARK: - Count Tests

    func testGetCountHistory() {
        let manager = createManager()

        XCTAssertEqual(manager.getCount(isTop: false), 0)

        manager.insertLocalHistoryClipboard(content: "Item 1", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Item 2", isTop: false)

        XCTAssertEqual(manager.getCount(isTop: false), 2)
    }

    func testGetCountTop() {
        let manager = createManager()

        XCTAssertEqual(manager.getCount(isTop: true), 0)

        manager.insertLocalHistoryClipboard(content: "Top 1", isTop: true)
        manager.insertLocalHistoryClipboard(content: "Top 2", isTop: true)
        manager.insertLocalHistoryClipboard(content: "History 1", isTop: false)

        XCTAssertEqual(manager.getCount(isTop: true), 2)
        XCTAssertEqual(manager.getCount(isTop: false), 1)
    }

    // MARK: - Delete Tests

    func testDeleteEarliestHistoryItem() {
        let manager = createManager()

        manager.insertLocalHistoryClipboard(content: "Oldest", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Middle", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Newest", isTop: false)

        XCTAssertEqual(manager.getCount(isTop: false), 3)

        let deleted = manager.deleteEarliestItem(isTop: false)

        XCTAssertTrue(deleted)
        XCTAssertEqual(manager.getCount(isTop: false), 2)

        let entries = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].content, "Newest".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(entries[1].content, "Middle".data(using: .utf8)?.base64EncodedString())
    }

    func testDeleteEarliestTopItem() {
        let manager = createManager()

        manager.insertLocalHistoryClipboard(content: "Top Oldest", isTop: true)
        manager.insertLocalHistoryClipboard(content: "Top Middle", isTop: true)
        manager.insertLocalHistoryClipboard(content: "Top Newest", isTop: true)

        let deleted = manager.deleteEarliestItem(isTop: true)

        XCTAssertTrue(deleted)
        XCTAssertEqual(manager.getCount(isTop: true), 2)

        let entries = manager.selectLocalHistoryClipoardIsTop(isTop: true, start: 0, end: 10)
        XCTAssertEqual(entries[0].content, "Top Newest".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(entries[1].content, "Top Middle".data(using: .utf8)?.base64EncodedString())
    }

    func testDeleteEarliestFromEmpty() {
        let manager = createManager()

        let deleted = manager.deleteEarliestItem(isTop: false)

        // 原版 execBySQL 只看 SQL 是否执行成功，删了 0 行同样返回 YES
        XCTAssertTrue(deleted)
    }

    func testDeleteExpiredHistory() {
        let manager = createManager()

        // 无法直接造旧时间戳，这里验证 SQL 正常执行：没有过期条目时记录保持原样，
        // 返回值仍是执行成功（原版语义）。
        manager.insertLocalHistoryClipboard(content: "Recent", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Also Recent", isTop: false)

        let deleted = manager.deleteExpiredHistory(days: 30)

        XCTAssertTrue(deleted)
        XCTAssertEqual(manager.getCount(isTop: false), 2)
    }

    // MARK: - Clear Tests

    func testClearHistoryList() {
        let manager = createManager()

        manager.insertLocalHistoryClipboard(content: "History 1", isTop: false)
        manager.insertLocalHistoryClipboard(content: "History 2", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Top 1", isTop: true)

        XCTAssertEqual(manager.getCount(isTop: false), 2)
        XCTAssertEqual(manager.getCount(isTop: true), 1)

        let cleared = manager.clearHistoryList()

        XCTAssertTrue(cleared)
        XCTAssertEqual(manager.getCount(isTop: false), 0)
        XCTAssertEqual(manager.getCount(isTop: true), 1) // Top entries preserved
    }

    func testClearHistoryListEmpty() {
        let manager = createManager()

        let cleared = manager.clearHistoryList()

        XCTAssertTrue(cleared) // 空表删除依旧算执行成功
    }

    func testClearTop() {
        let manager = createManager()

        manager.insertLocalHistoryClipboard(content: "History 1", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Top 1", isTop: true)
        manager.insertLocalHistoryClipboard(content: "Top 2", isTop: true)

        XCTAssertEqual(manager.getCount(isTop: true), 2)

        manager.clearTop()

        XCTAssertEqual(manager.getCount(isTop: true), 0)
        XCTAssertEqual(manager.getCount(isTop: false), 1) // History preserved
    }

    func testClearAll() {
        let manager = createManager()

        manager.insertLocalHistoryClipboard(content: "History 1", isTop: false)
        manager.insertLocalHistoryClipboard(content: "History 2", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Top 1", isTop: true)

        XCTAssertEqual(manager.getCount(isTop: false), 2)
        XCTAssertEqual(manager.getCount(isTop: true), 1)

        manager.clearAll()

        XCTAssertEqual(manager.getCount(isTop: false), 0)
        XCTAssertEqual(manager.getCount(isTop: true), 0)
    }

    // MARK: - Top Count Property

    func testTopCountProperty() {
        let manager = createManager()

        XCTAssertEqual(manager.topCount, 0)

        manager.insertLocalHistoryClipboard(content: "Top 1", isTop: true)
        XCTAssertEqual(manager.topCount, 1)

        manager.insertLocalHistoryClipboard(content: "Top 2", isTop: true)
        XCTAssertEqual(manager.topCount, 2)

        manager.insertLocalHistoryClipboard(content: "History 1", isTop: false)
        XCTAssertEqual(manager.topCount, 2) // Only counts top entries
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAccess() {
        let manager = createManager()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let iterations = 100

        // Concurrent inserts
        for i in 0..<iterations {
            group.enter()
            queue.async {
                manager.insertLocalHistoryClipboard(content: "Item \(i)", isTop: i % 2 == 0)
                group.leave()
            }
        }

        group.wait()

        // Verify all items were inserted
        let totalCount = manager.getCount(isTop: true) + manager.getCount(isTop: false)
        XCTAssertEqual(totalCount, iterations)
    }

    // MARK: - Edge Cases

    func testMultipleManagersSameDatabase() {
        let dbPath = getTestDatabasePath()
        let manager1 = HistoryClipboardManager(databasePath: dbPath)
        let manager2 = HistoryClipboardManager(databasePath: dbPath)

        manager1.insertLocalHistoryClipboard(content: "From Manager 1", isTop: false)

        let entries = manager2.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].content, "From Manager 1".data(using: .utf8)?.base64EncodedString())
    }

    func testBase64Encoding() {
        let manager = createManager()

        let originalContent = "Special chars: \n\t\"'\\"
        let entry = manager.insertLocalHistoryClipboard(content: originalContent, isTop: false)

        XCTAssertNotNil(entry)

        // Verify content is base64 encoded
        let decodedData = Data(base64Encoded: entry!.content)
        XCTAssertNotNil(decodedData)
        let decodedString = String(data: decodedData!, encoding: .utf8)
        XCTAssertEqual(decodedString, originalContent)
    }

    func testDatabasePathCreation() {
        let tempDir = NSTemporaryDirectory()
        let customPath = "\(tempDir)custom_folder/nested/db_test.db"

        let manager = HistoryClipboardManager(databasePath: customPath)
        let entry = manager.insertLocalHistoryClipboard(content: "Test", isTop: false)

        XCTAssertNotNil(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customPath))
    }

    // MARK: - RAM Store Tests

    /// RAM 模式下剪贴板监听器、菜单栏和历史列表窗口会各自 new 一个 manager，
    /// 三个实例必须落在同一个共享内存库上，否则用户记录一打开窗口就消失。
    func testRAMDatabaseIsSharedBetweenManagers() {
        let first = HistoryClipboardManager(databasePath: HistoryClipboardManager.ramDatabasePath)
        first.clearAll()

        XCTAssertNotNil(first.insertLocalHistoryClipboard(content: "ram shared", isTop: false))

        let second = HistoryClipboardManager(databasePath: HistoryClipboardManager.ramDatabasePath)
        XCTAssertEqual(second.getCount(isTop: false), 1)

        second.clearAll()
    }

    // MARK: - Timer Integration Tests

    func testEnableHistoryClipboardDisabled() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(false, forKey: "enableHistoryClipboard")
        testDefaults.set(true, forKey: "clipoardStroageLocal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        let result = manager.enableHistoryClipboard()

        XCTAssertFalse(result)
    }

    func testEnableHistoryClipboardEnabled() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(true, forKey: "enableHistoryClipboard")
        testDefaults.set(true, forKey: "clipoardStroageLocal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        let result = manager.enableHistoryClipboard()

        XCTAssertTrue(result)
        manager.stopHistoryClipboard()
    }

    /// Monitoring is driven by `enableHistoryClipboard` alone: RAM storage still
    /// watches the pasteboard (original enableHistoryClipboard has no storage test).
    func testEnableHistoryClipboardStorageLocalDisabled() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(true, forKey: "enableHistoryClipboard")
        testDefaults.set(false, forKey: "clipoardStroageLocal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        let result = manager.enableHistoryClipboard()

        XCTAssertTrue(result)
        manager.stopHistoryClipboard()
    }

    func testGetTopList() {
        let manager = createManager()

        manager.insertLocalHistoryClipboard(content: "History 1", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Top 1", isTop: true)
        manager.insertLocalHistoryClipboard(content: "History 2", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Top 2", isTop: true)

        let topList = manager.getTopList()

        XCTAssertEqual(topList.count, 2)
        XCTAssertEqual(topList[0].content, "Top 2".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(topList[1].content, "Top 1".data(using: .utf8)?.base64EncodedString())
        XCTAssertTrue(topList.allSatisfy { $0.isTop })
    }

    func testGetTopListEmpty() {
        let manager = createManager()

        let topList = manager.getTopList()

        XCTAssertEqual(topList.count, 0)
    }

    func testGetHistoryClipboardListFirstPage() {
        let manager = createManager()

        // Insert top entries
        manager.insertLocalHistoryClipboard(content: "Top 1", isTop: true)
        manager.insertLocalHistoryClipboard(content: "Top 2", isTop: true)

        // Insert history entries
        for i in 1...5 {
            manager.insertLocalHistoryClipboard(content: "History \(i)", isTop: false)
        }

        let list = manager.getHistoryClipboardList(firstPage: true)

        // Should have 2 top + 5 history = 7 entries (page size is 30, so all fit)
        XCTAssertEqual(list.count, 7)

        // First entries should be top entries (newest first)
        XCTAssertTrue(list[0].isTop)
        XCTAssertTrue(list[1].isTop)
        XCTAssertEqual(list[0].content, "Top 2".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(list[1].content, "Top 1".data(using: .utf8)?.base64EncodedString())

        // Remaining should be history entries (newest first)
        XCTAssertFalse(list[2].isTop)
        XCTAssertEqual(list[2].content, "History 5".data(using: .utf8)?.base64EncodedString())
    }

    func testGetHistoryClipboardListPagination() {
        let manager = createManager()

        // Insert 35 history entries (more than one page)
        for i in 1...35 {
            manager.insertLocalHistoryClipboard(content: "History \(i)", isTop: false)
        }

        // First page
        let page1 = manager.getHistoryClipboardList(firstPage: true)
        XCTAssertEqual(page1.count, 30) // pageSize = 30

        // Next page
        let page2 = manager.nextPage(currentHistoryCount: page1.count)
        XCTAssertEqual(page2.count, 5) // Remaining 5 entries
    }

    func testNextPage() {
        let manager = createManager()

        for i in 1...50 {
            manager.insertLocalHistoryClipboard(content: "Item \(i)", isTop: false)
        }

        // Get first page
        _ = manager.getHistoryClipboardList(firstPage: true)

        // Get second page
        let page2 = manager.nextPage(currentHistoryCount: 30)
        XCTAssertEqual(page2.count, 20)

        // Get third page (should be empty)
        let page3 = manager.nextPage(currentHistoryCount: 50)
        XCTAssertEqual(page3.count, 0)
    }

    func testAddTop() {
        let manager = createManager()

        let entry = manager.addTop(content: "Pinned Content")

        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isTop ?? false)
        XCTAssertEqual(entry?.content, "Pinned Content".data(using: .utf8)?.base64EncodedString())
    }

    func testAddTopEnforcesLimit() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(true, forKey: "enableLimitTop")
        testDefaults.set(2, forKey: "limitTop")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        // Add 3 top entries (limit is 2)
        manager.addTop(content: "Top 1")
        manager.addTop(content: "Top 2")
        manager.addTop(content: "Top 3")

        let topList = manager.getTopList()

        // Should only have 2 entries (oldest removed)
        XCTAssertEqual(topList.count, 2)
        XCTAssertEqual(topList[0].content, "Top 3".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(topList[1].content, "Top 2".data(using: .utf8)?.base64EncodedString())
    }

    func testRemoveTop() {
        let manager = createManager()

        manager.addTop(content: "Top 1")
        manager.addTop(content: "Top 2")
        manager.addTop(content: "Top 3")

        var topList = manager.getTopList()
        XCTAssertEqual(topList.count, 3)

        // Remove middle entry (index 1 = "Top 2")
        manager.removeTop(at: 1)

        topList = manager.getTopList()
        XCTAssertEqual(topList.count, 2)
        XCTAssertEqual(topList[0].content, "Top 3".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(topList[1].content, "Top 1".data(using: .utf8)?.base64EncodedString())
    }

    func testRemoveTopInvalidIndex() {
        let manager = createManager()

        manager.addTop(content: "Top 1")

        // Should not crash
        manager.removeTop(at: 5)
        manager.removeTop(at: -1)

        let topList = manager.getTopList()
        XCTAssertEqual(topList.count, 1)
    }

    func testDeleteExpiredEnforcesTotalLimit() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(true, forKey: "clipoardStroageLocal")
        testDefaults.set(true, forKey: "enableLimitTotal")
        testDefaults.set(3, forKey: "limitTotal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        // Insert 5 history entries
        for i in 1...5 {
            manager.insertLocalHistoryClipboard(content: "History \(i)", isTop: false)
        }

        manager.deleteExpired()

        // Should only have 3 entries (oldest 2 removed)
        XCTAssertEqual(manager.getCount(isTop: false), 3)
        let entries = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)
        XCTAssertEqual(entries[0].content, "History 5".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(entries[1].content, "History 4".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(entries[2].content, "History 3".data(using: .utf8)?.base64EncodedString())
    }

    /// RAM storage skips the total-count trim (original: deleteExpired's
    /// total/day branches sit inside `if (STROAGE_LOCAL)`).
    func testDeleteExpiredSkipsTotalLimitInRamStorage() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(false, forKey: "clipoardStroageLocal")
        testDefaults.set(true, forKey: "enableLimitTotal")
        testDefaults.set(3, forKey: "limitTotal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)
        for i in 1...5 {
            manager.insertLocalHistoryClipboard(content: "History \(i)", isTop: false)
        }

        manager.deleteExpired()

        XCTAssertEqual(manager.getCount(isTop: false), 5)
    }

    func testDeleteExpiredEnforcesTopLimit() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(true, forKey: "enableLimitTop")
        testDefaults.set(2, forKey: "limitTop")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        // Insert 4 top entries
        for i in 1...4 {
            manager.insertLocalHistoryClipboard(content: "Top \(i)", isTop: true)
        }

        manager.deleteExpired()

        // Should only have 2 entries
        XCTAssertEqual(manager.getCount(isTop: true), 2)
        let entries = manager.selectLocalHistoryClipoardIsTop(isTop: true, start: 0, end: 10)
        XCTAssertEqual(entries[0].content, "Top 4".data(using: .utf8)?.base64EncodedString())
        XCTAssertEqual(entries[1].content, "Top 3".data(using: .utf8)?.base64EncodedString())
    }

    func testDeleteExpiredEnforcesDaysLimit() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(true, forKey: "clipoardStroageLocal")
        testDefaults.set(true, forKey: "enableLimitSaveDays")
        testDefaults.set(1, forKey: "limitSaveDays")

        let dbPath = getTestDatabasePath()
        let manager = HistoryClipboardManager(databasePath: dbPath, userDefaults: testDefaults)

        // Insert entries with old timestamps using a direct connection
        let oldTime = Date().timeIntervalSince1970 - (2 * 24 * 60 * 60) // 2 days ago
        let recentTime = Date().timeIntervalSince1970

        do {
            let directDb = try Connection(dbPath)
            let table = Table("local_history_clipoard")
            let contentCol = Expression<String>("content")
            let isTopCol = Expression<Int64>("is_top")
            let createTimeCol = Expression<Double>("create_time")
            let modifyTimeCol = Expression<Double>("modify_time")

            try directDb.run(table.insert(
                contentCol <- "Old Entry".data(using: .utf8)!.base64EncodedString(),
                isTopCol <- 0,
                createTimeCol <- oldTime,
                modifyTimeCol <- oldTime
            ))
            try directDb.run(table.insert(
                contentCol <- "Recent Entry".data(using: .utf8)!.base64EncodedString(),
                isTopCol <- 0,
                createTimeCol <- recentTime,
                modifyTimeCol <- recentTime
            ))
        } catch {
            XCTFail("Failed to insert test data: \(error)")
        }

        manager.deleteExpired()

        // Only recent entry should remain
        XCTAssertEqual(manager.getCount(isTop: false), 1)
        let entries = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)
        XCTAssertEqual(entries[0].content, "Recent Entry".data(using: .utf8)?.base64EncodedString())
    }

    func testDeinitInvalidatesTimer() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(true, forKey: "enableHistoryClipboard")
        testDefaults.set(true, forKey: "clipoardStroageLocal")

        var manager: HistoryClipboardManager? = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)
        _ = manager?.enableHistoryClipboard()
        manager?.stopHistoryClipboard()

        // Deinit should not crash
        manager = nil

        // If we reach here without crash, timer was properly invalidated
        XCTAssertTrue(true)
    }

    func testStopHistoryClipboard() {
        let testDefaults = isolatedDefaults()
        testDefaults.set(true, forKey: "enableHistoryClipboard")
        testDefaults.set(true, forKey: "clipoardStroageLocal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        let result = manager.enableHistoryClipboard()
        XCTAssertTrue(result)

        // Stop should not crash
        manager.stopHistoryClipboard()
        XCTAssertTrue(true)
    }

    // MARK: - Image entries

    /// A valid 1×1 PNG: the storage layer only ever copies these bytes around.
    private func pngData() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    }

    /// 每个用例独立的库目录：图片 payload 落在库旁边的 clipboard_images，
    /// 断言目录为空时不能被其他用例的文件干扰。
    private func imageManager() -> HistoryClipboardManager {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "clipoardStroageLocal")
        let dir = "\(NSTemporaryDirectory())history_clipboard_test_\(UUID().uuidString)"
        return HistoryClipboardManager(databasePath: "\(dir)/clip.db", userDefaults: defaults)
    }

    func testInsertLocalImageStoresPngFileAndKind() {
        let manager = imageManager()

        let entry = manager.insertLocalImage(data: pngData())

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.kind, .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry?.content ?? ""))
        XCTAssertEqual((entry?.content ?? "").hasSuffix(".png"), true)

        let loaded = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].kind, .image)
        XCTAssertNotNil(manager.imageData(for: loaded[0]))
    }

    func testImagePayloadIsNotDecodedAsText() {
        let manager = imageManager()
        let entry = manager.insertLocalImage(data: pngData())

        // Image rows store a path, so the text decoder must hand it back as-is.
        XCTAssertEqual(manager.textContent(for: entry!), entry?.content)
        XCTAssertNil(manager.imageData(for: manager.insertLocalHistoryClipboard(content: "plain", isTop: false)!))
    }

    func testAddTopImageCopiesPayloadFile() {
        let manager = imageManager()
        let history = manager.insertLocalImage(data: pngData())!
        let pinned = manager.addTopImage(for: history)

        XCTAssertNotNil(pinned)
        XCTAssertEqual(pinned?.kind, .image)
        XCTAssertEqual(pinned?.isTop, true)
        XCTAssertNotEqual(pinned?.content, history.content, "pin must copy the payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.content))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned?.content ?? ""))
    }

    func testRemoveTopUnlinksOnlyThePinnedPayload() {
        let manager = imageManager()
        let history = manager.insertLocalImage(data: pngData())!
        let pinned = manager.addTopImage(for: history)!

        manager.removeTop(at: 0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pinned.content))
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.content))
        XCTAssertEqual(manager.getCount(isTop: false), 1)
    }

    func testClearHistoryListAndClearAllUnlinkImagePayloads() {
        let manager = imageManager()
        let directory = ((manager.insertLocalImage(data: pngData())?.content ?? "") as NSString)
            .deletingLastPathComponent

        manager.clearHistoryList()
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: directory), [],
                       "history clear must unlink image files")

        _ = manager.insertLocalImage(data: pngData())
        _ = manager.insertLocalHistoryClipboard(content: "text", isTop: true)
        manager.clearAll()
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: directory), [])
    }

    func testExpiredImageEntryUnlinksPayload() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "clipoardStroageLocal")
        defaults.set(true, forKey: "enableLimitSaveDays")
        defaults.set(0, forKey: "limitSaveDays")
        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: defaults)
        let entry = manager.insertLocalImage(data: pngData())!

        manager.deleteExpired()

        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.content))
        XCTAssertEqual(manager.getCount(isTop: false), 0)
    }

    func testPasteboardImageDataAcceptsPngTiffAndImageFiles() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacStrokeTests.image.\(UUID().uuidString)"))

        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)
        XCTAssertNotNil(HistoryClipboardManager.pasteboardImageData(from: pasteboard))

        pasteboard.clearContents()
        pasteboard.setData(NSBitmapImageRep(data: pngData())!.representation(using: .tiff, properties: [:])!,
                           forType: .tiff)
        XCTAssertNotNil(HistoryClipboardManager.pasteboardImageData(from: pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        XCTAssertNil(HistoryClipboardManager.pasteboardImageData(from: pasteboard))
    }

    func testPasteboardImageDataIgnoresNonImageFileURLs() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacStrokeTests.file.\(UUID().uuidString)"))
        let textFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("note-\(UUID().uuidString).txt")
        try "hello".write(to: textFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: textFile) }

        pasteboard.clearContents()
        pasteboard.writeObjects([textFile as NSURL])
        XCTAssertNil(HistoryClipboardManager.pasteboardImageData(from: pasteboard))
    }

    func testLegacyDatabaseWithoutTypeColumnMigratesToText() throws {
        let path = getTestDatabasePath()
        let db = try Connection(path)
        // The pre-image schema written by earlier builds.
        try db.run("""
            CREATE TABLE local_history_clipoard (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT,
                is_top INTEGER,
                create_time REAL,
                modify_time REAL
            )
            """)
        let now = Date().timeIntervalSince1970
        try db.run("INSERT INTO local_history_clipoard (content, is_top, create_time, modify_time) VALUES (?, ?, ?, ?)",
                   "legacy".data(using: .utf8)!.base64EncodedString(), 0, now, now)

        let manager = HistoryClipboardManager(databasePath: path)
        let entries = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .text)
        XCTAssertEqual(entries[0].content, "legacy".data(using: .utf8)?.base64EncodedString())
        // New image rows still work after the migration.
        XCTAssertNotNil(manager.insertLocalImage(data: pngData()))
    }

    // MARK: - File entries

    private func makeTempFile(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip_file_\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url.path
    }

    func testInsertLocalFilesStoresPathListAndKind() throws {
        let manager = imageManager()
        let a = try makeTempFile("report.pdf")
        let b = try makeTempFile("数据.csv")

        let entry = manager.insertLocalFiles(paths: [a, b])

        XCTAssertEqual(entry?.kind, .file)
        XCTAssertEqual(entry?.content, "\(a)\n\(b)", "paths are stored verbatim, not base64")
        let loaded = manager.selectLocalHistoryClipoardIsTop(isTop: false, start: 0, end: 10)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(manager.filePaths(for: loaded[0]), [a, b], "pasteboard order is kept")
        XCTAssertEqual(manager.textContent(for: loaded[0]), loaded[0].content)
    }

    func testFileEntryWritesNoPayloadFiles() throws {
        let manager = imageManager()
        let path = try makeTempFile("note.txt")
        let entry = try XCTUnwrap(manager.insertLocalFiles(paths: [path]))

        // File rows reference the user's files; nothing is copied next to the database.
        XCTAssertNil(manager.imageData(for: entry))
        XCTAssertEqual(manager.filePaths(for: entry), [path])
    }

    func testAddTopFilePinsTheSamePathList() throws {
        let manager = imageManager()
        let a = try makeTempFile("budget.xlsx")
        let history = manager.insertLocalFiles(paths: [a])!

        let pinned = manager.addTopFile(for: history)

        XCTAssertEqual(pinned?.kind, .file)
        XCTAssertEqual(pinned?.isTop, true)
        XCTAssertEqual(manager.filePaths(for: pinned!), [a])
        XCTAssertEqual(manager.getTopList().count, 1)
        XCTAssertNil(manager.addTopFile(for: manager.insertLocalHistoryClipboard(content: "text", isTop: false)!),
                     "only file rows may be pinned as file rows")
    }

    func testClearingHistoryNeverDeletesReferencedFiles() throws {
        let manager = imageManager()
        let a = try makeTempFile("keepme.txt")
        _ = manager.insertLocalFiles(paths: [a])
        _ = manager.addTopFile(for: manager.getHistoryClipboardList(firstPage: true)[0])

        manager.clearHistoryList()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))

        manager.clearTop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a),
                      "file rows only reference the user's files")

        _ = manager.insertLocalFiles(paths: [a])
        manager.clearAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
    }

    func testPasteboardFileURLsKeepsExistingFilesOnly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = dir.appendingPathComponent("present.pdf")
        try Data("x".utf8).write(to: existing)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacStrokeTests.urls.\(UUID().uuidString)"))

        pasteboard.clearContents()
        pasteboard.writeObjects([existing as NSURL,
                                 dir.appendingPathComponent("gone.txt") as NSURL] as [NSURL])
        XCTAssertEqual(HistoryClipboardManager.pasteboardFileURLs(from: pasteboard), [existing.path])

        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)
        XCTAssertEqual(HistoryClipboardManager.pasteboardFileURLs(from: pasteboard), [],
                       "a screenshot copy is not a file copy")
    }
}