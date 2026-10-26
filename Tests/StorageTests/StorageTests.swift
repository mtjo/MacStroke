//
//  StorageTests
//  MacStroke
//

import XCTest
import Foundation
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

    /// issue #22（手势打到光标下的窗口）那两条。键名和默认值一起钉：
    /// 键名写错 = 偏好页读不到、老用户导入的 plist 里也没这一档；默认值写反 =
    /// 全量用户的「动作落到哪家」当场改掉，而这条语义是所有老规则都依赖的。
    func testStrokeTargetKeysAndDefaults() {
        registerUserDefaultsDefaults()

        let defaults = UserDefaults.standard
        XCTAssertFalse(defaults.bool(forKey: "strokeTargetsCursorWindow"),
                       "总开关默认必须关：关着才等于原版行为（动作打进抬手那一刻的前台）")
        XCTAssertTrue(defaults.bool(forKey: "strokeTargetRestoresFocus"),
                      "默认还焦：不还的话画一次手势等价于点一下那个窗口")
        XCTAssertEqual(StorageKey.strokeTargetsCursorWindow.rawValue, "strokeTargetsCursorWindow")
        XCTAssertEqual(StorageKey.strokeTargetRestoresFocus.rawValue, "strokeTargetRestoresFocus")
        XCTAssertNotEqual(StorageKey.strokeTargetsCursorWindow.rawValue,
                          StorageKey.strokeTargetRestoresFocus.rawValue,
                          "两行共用一个键：拨一个另一个跟着变，其中一行的配置会被另一行覆盖掉")
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