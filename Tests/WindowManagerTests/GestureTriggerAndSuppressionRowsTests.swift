// 手势页合并后的两行控件（issue #53 起手键 + issue #59 修饰键让位）的行为取证：
// 起手键收成单个按键录制框、默认右键；修饰键收成「一个开关 + 一个只录修饰键的
// 快捷键框」，录到的组合与存储的 token 串必须双向对得上，且只认建模的五个键位。
import XCTest
import AppKit
import SwiftUI
import Storage
@testable import Preferences

final class GestureTriggerAndSuppressionRowsTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.GestureTriggerRows"

    override func setUp() {
        super.setUp()
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func isolatedSuite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    // MARK: - 起手键（issue #53）

    func testTriggerButtonDefaultsToRightAndPersists() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))
        XCTAssertEqual(prefs.gestureTriggerButton, 1, "默认右键起手 = 原版行为")

        prefs.gestureTriggerButton = 2
        prefs.save()
        XCTAssertEqual(UserPreferences(storage: PreferencesStorage(defaults: suite)).gestureTriggerButton, 2)
    }

    func testResetToDefaultsBringsTheTriggerButtonBackToRight() {
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
        prefs.gestureTriggerButton = 4
        prefs.enableGestureSuppression = true
        prefs.gestureSuppressedModifiers = "cmd,shift"

        prefs.resetToDefaults()

        XCTAssertEqual(prefs.gestureTriggerButton, StorageDefaults.gestureTriggerButton)
        XCTAssertFalse(prefs.enableGestureSuppression)
        XCTAssertEqual(prefs.gestureSuppressedModifiers, "")
    }

    // MARK: - 修饰键录制框（issue #59）

    func testModifiersOnlyCommitsWhenLastModifierReleased() {
        let view = ShortcutRecorderView()
        view.modifiersOnly = true
        var committed: (UInt16, UInt)?
        view.onShortcutChanged = { committed = ($0, $1) }

        view.startRecording()
        view.flagsChanged(with: modifierEvent([.command, .shift]))
        XCTAssertNil(committed, "还按着修饰键时不该结算")
        view.flagsChanged(with: modifierEvent([]))

        XCTAssertEqual(committed?.0, 0, "只录修饰键时 key code 恒为 0")
        XCTAssertEqual(committed?.1, 0x100000 | 0x20000)
    }

    func testModifiersOnlyIgnoresCapsLockAndUnmodelledFlags() {
        let view = ShortcutRecorderView()
        view.modifiersOnly = true
        var committed: (UInt16, UInt)?
        view.onShortcutChanged = { committed = ($0, $1) }

        // 反向对照：只按 caps-lock（没建模的位）不该结算出任何东西。
        view.startRecording()
        view.flagsChanged(with: modifierEvent([.capsLock]))
        view.flagsChanged(with: modifierEvent([]))
        XCTAssertNil(committed, "caps-lock 不算修饰键组合")

        view.startRecording()
        view.flagsChanged(with: modifierEvent([.option]))
        view.flagsChanged(with: modifierEvent([.option, .capsLock]))
        view.flagsChanged(with: modifierEvent([]))
        XCTAssertEqual(committed?.1, 0x80000, "组合里只留 ⌥，caps-lock 被丢掉")
    }

    func testModifiersOnlySettlesOnKeyPress() throws {
        let view = ShortcutRecorderView()
        view.modifiersOnly = true
        var committed: (UInt16, UInt)?
        view.onShortcutChanged = { committed = ($0, $1) }

        view.startRecording()
        view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
                                                           location: .zero,
                                                           modifierFlags: [.command, .function],
                                                           timestamp: 0,
                                                           windowNumber: 0,
                                                           context: nil,
                                                           characters: "v",
                                                           charactersIgnoringModifiers: "v",
                                                           isARepeat: false,
                                                           keyCode: 9)))
        XCTAssertEqual(committed?.0, 0, "按下的 V 键不该记进去")
        XCTAssertEqual(committed?.1, 0x100000 | 0x800000)
    }

    func testDisplayStringForModifierOnlyValues() {
        let view = ShortcutRecorderView()
        view.keyCode = 0
        view.flags = 0x100000 | 0x80000 | 0x20000
        XCTAssertEqual(view.displayString, "⌘⌥⇧")
        view.flags = 0x800000
        XCTAssertEqual(view.displayString, "fn")
        view.flags = 0
        XCTAssertEqual(view.displayString, "")
        // 反向对照：普通快捷键仍然带 key code 的名字。
        view.keyCode = 9
        view.flags = 0x100000 | 0x80000
        XCTAssertEqual(view.displayString, "⌘⌥V")
    }

    /// 录制框讲「keyCode=…, flags=…」，存的是 token 串，两者必须对得上。
    func testSuppressedModifiersBindingRoundTrips() {
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
        let binding = prefs.suppressedModifiersBinding()

        prefs.gestureSuppressedModifiers = "cmd,opt"
        XCTAssertEqual(binding.wrappedValue, "keyCode=0, flags=\(0x100000 | 0x80000)")

        binding.wrappedValue = "keyCode=0, flags=\(0x20000 | 0x800000)"
        XCTAssertEqual(prefs.gestureSuppressedModifiers, "shift,fn")

        // 反向对照：没建模的位写不进去，录到的 key code 也进不了存储。
        binding.wrappedValue = "keyCode=9, flags=\(0x10000)"
        XCTAssertEqual(prefs.gestureSuppressedModifiers, "")
    }

    private func modifierEvent(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        // flagsChanged 属于按键类事件，只能用 keyEvent(…) 造出来。
        try! XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged,
                                        location: .zero,
                                        modifierFlags: flags,
                                        timestamp: 0,
                                        windowNumber: 0,
                                        context: nil,
                                        characters: "",
                                        charactersIgnoringModifiers: "",
                                        isARepeat: false,
                                        keyCode: 0))
    }
}
