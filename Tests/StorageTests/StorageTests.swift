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
        XCTAssertTrue(defaults.bool(forKey: "showGestureNote"))
        XCTAssertTrue(defaults.bool(forKey: "enableLimitTop"))
        XCTAssertEqual(defaults.integer(forKey: "limitTop"), 15)
        XCTAssertEqual(defaults.integer(forKey: "limitSaveDays"), 7)
        XCTAssertEqual(defaults.double(forKey: "minScore"), 85.0)
        XCTAssertEqual(defaults.string(forKey: "userTerminal"), "Terminal")
        XCTAssertEqual(defaults.string(forKey: "historyCilpboardListShortcut"), "keyCode=9, flags=1572864")
    }

    /// The default clipboard shortcut parses to ⌘⌥V (original SRShortcut:
    /// keyCode 9, modifierFlags 1572864).
    func testDefaultClipboardShortcutParses() {
        let parsed = ShortcutMonitor.parseShortcut(StorageDefaults.historyCilpboardListShortcut)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.0, 9)      // kVK_ANSI_V
        XCTAssertEqual(parsed?.1, 1572864) // command (0x100000) + option (0x80000)
    }

}