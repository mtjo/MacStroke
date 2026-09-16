//
//  StorageTests
//  MacStroke
//

import XCTest
@testable import Storage

final class StorageTests: XCTestCase {

    func getTestDatabasePath() -> String {
        // Create a unique temporary database path for each test
        let tempDir = NSTemporaryDirectory()
        let uuid = UUID().uuidString
        return "\(tempDir)clipboard_test_\(uuid).db"
    }

    func testClipboardHistoryAddAndRetrieve() {
        let manager = ClipboardHistoryManager(maxEntries: 10, databasePath: getTestDatabasePath())

        manager.add("First entry")
        manager.add("Second entry")
        manager.add("Third entry")

        let entries = manager.recentEntries(limit: 10)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].text, "Third entry")
        XCTAssertEqual(entries[1].text, "Second entry")
        XCTAssertEqual(entries[2].text, "First entry")
    }

    func testClipboardHistoryPruning() {
        let manager = ClipboardHistoryManager(maxEntries: 3, databasePath: getTestDatabasePath())

        for i in 0..<5 {
            manager.add("Entry \(i)")
        }

        let entries = manager.recentEntries(limit: 10)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].text, "Entry 4")
        XCTAssertEqual(entries[1].text, "Entry 3")
        XCTAssertEqual(entries[2].text, "Entry 2")
    }

    func testClipboardHistoryClear() {
        let manager = ClipboardHistoryManager(maxEntries: 10, databasePath: getTestDatabasePath())

        manager.add("First entry")
        manager.add("Second entry")
        manager.clear()

        XCTAssertEqual(manager.entryCount, 0)
    }
}