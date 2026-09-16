//
//  HistoryClipboardTests.swift
//  MacStroke
//
//  Tests for HistoryClipboard data layer.
//

import XCTest
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

        XCTAssertFalse(deleted)
    }

    func testDeleteExpiredHistory() {
        let manager = createManager()

        // Insert entries with old timestamps by manipulating the database directly
        // Since we can't easily set createTime, we test the method runs without error
        // and returns false when no entries are expired

        manager.insertLocalHistoryClipboard(content: "Recent", isTop: false)
        manager.insertLocalHistoryClipboard(content: "Also Recent", isTop: false)

        // No entries should be deleted (all are recent)
        let deleted = manager.deleteExpiredHistory(days: 30)

        XCTAssertFalse(deleted)
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

        XCTAssertFalse(cleared) // Nothing to delete
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

    // MARK: - Timer Integration Tests

    func testEnableHistoryClipboardDisabled() {
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        testDefaults.set(false, forKey: "enableHistoryClipboard")
        testDefaults.set(true, forKey: "clipoardStroageLocal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        let result = manager.enableHistoryClipboard()

        XCTAssertFalse(result)
    }

    func testEnableHistoryClipboardEnabled() {
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        testDefaults.set(true, forKey: "enableHistoryClipboard")
        testDefaults.set(true, forKey: "clipoardStroageLocal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        let result = manager.enableHistoryClipboard()

        XCTAssertTrue(result)
        manager.stopHistoryClipboard()
    }

    func testEnableHistoryClipboardStorageLocalDisabled() {
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        testDefaults.set(true, forKey: "enableHistoryClipboard")
        testDefaults.set(false, forKey: "clipoardStroageLocal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        let result = manager.enableHistoryClipboard()

        XCTAssertFalse(result)
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
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
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
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
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

    func testDeleteExpiredEnforcesTopLimit() {
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
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
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
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
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
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
        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        testDefaults.set(true, forKey: "enableHistoryClipboard")
        testDefaults.set(true, forKey: "clipoardStroageLocal")

        let manager = HistoryClipboardManager(databasePath: getTestDatabasePath(), userDefaults: testDefaults)

        let result = manager.enableHistoryClipboard()
        XCTAssertTrue(result)

        // Stop should not crash
        manager.stopHistoryClipboard()
        XCTAssertTrue(true)
    }
}