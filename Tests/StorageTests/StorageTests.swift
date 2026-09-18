//
//  StorageTests
//  MacStroke
//

import XCTest
@testable import Storage
import EventCapture

final class StorageTests: XCTestCase {

    func getTestDatabasePath() -> String {
        // Create a unique temporary database path for each test
        let tempDir = NSTemporaryDirectory()
        let uuid = UUID().uuidString
        return "\(tempDir)clipboard_test_\(uuid).db"
    }

    /// Regression: raw UserDefaults readers (HistoryClipboardManager) must see
    /// the registered defaults on a fresh install, otherwise the clipboard
    /// monitor never starts (enableHistoryClipboard / clipoardStroageLocal
    /// read as false).
    func testRegisterUserDefaultsDefaults() {
        registerUserDefaultsDefaults()

        let defaults = UserDefaults.standard
        XCTAssertTrue(defaults.bool(forKey: "enableHistoryClipboard"))
        XCTAssertTrue(defaults.bool(forKey: "clipoardStroageLocal"))
        XCTAssertTrue(defaults.bool(forKey: "isEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "showGestureNote"))
        XCTAssertTrue(defaults.bool(forKey: "enableLimitTop"))
        XCTAssertEqual(defaults.integer(forKey: "limitTop"), 15)
        XCTAssertEqual(defaults.integer(forKey: "limitSaveDays"), 7)
        XCTAssertEqual(defaults.double(forKey: "minScore"), 85.0)
        XCTAssertEqual(defaults.string(forKey: "userTerminal"), "Terminal")
        XCTAssertEqual(defaults.string(forKey: "historyCilpboardListShortcut"), "keyCode=9, flags=393216")
    }

    /// The default clipboard shortcut parses to ^⇧V.
    func testDefaultClipboardShortcutParses() {
        let parsed = ShortcutMonitor.parseShortcut(StorageDefaults.historyCilpboardListShortcut)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.0, 9)      // kVK_ANSI_V
        XCTAssertEqual(parsed?.1, 393216) // control (0x40000) + shift (0x20000)
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