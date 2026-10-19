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

    // MARK: - 不匹配时不弹右键菜单（issue #73）

    func testSwallowUnmatchedGestureDefaultsToOffAndPersists() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))
        XCTAssertFalse(prefs.swallowUnmatchedGesture, "默认关 = 原版行为：画错了还能弹出右键菜单")

        prefs.swallowUnmatchedGesture = true
        prefs.save()
        XCTAssertTrue(UserPreferences(storage: PreferencesStorage(defaults: suite)).swallowUnmatchedGesture)
    }

    func testResetToDefaultsTurnsSwallowingBackOff() {
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
        prefs.swallowUnmatchedGesture = true

        prefs.resetToDefaults()

        XCTAssertFalse(prefs.swallowUnmatchedGesture)
        XCTAssertFalse(isolatedSuite().bool(forKey: StorageKey.swallowUnmatchedGesture.rawValue),
                       "重置要把落盘的键也写回默认，不能只改内存")
    }

    func testSwallowingSwitchSurvivesAReloadWithoutTheKeyWritten() {
        // 全新装（键从没落过盘）时读出来必须是关，而不是「没键 = 不知道」：
        // CanvasManager 那侧每事件现读，取不到就走 StorageDefaults，两边得答一样。
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
        XCTAssertFalse(prefs.swallowUnmatchedGesture)
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.swallowUnmatchedGesture.rawValue),
                     "构造阶段不该把这个键提前写进去")
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

        // `currentlyHeld: 0`：录制框开始听键时会读一遍会话当前的修饰键状态（用户常常
        // 先按住 ⌘ 再点录制框，那一位算在内）。测试喂的是下面这几条合成事件，不该
        // 再让机器此刻按着什么来参与判据 —— 远程控制那个文件往会话里注入按键，一旦
        // 漏发一次放开，⌘ 就挂在会话里，这一格会「通过」得毫无道理。
        view.startRecording(currentlyHeld: 0)
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
        // `currentlyHeld: 0` 同上——此刻机器要真挂着 ⌘，这一格照样能「通过」，
        // 因为它算的是「位从 0 挪到哪」，跟会话里原本有什么无关。
        view.startRecording(currentlyHeld: 0)
        view.flagsChanged(with: modifierEvent([.capsLock]))
        view.flagsChanged(with: modifierEvent([]))
        XCTAssertNil(committed, "caps-lock 不算修饰键组合")

        view.startRecording(currentlyHeld: 0)
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

        view.startRecording(currentlyHeld: 0)
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

    /// 只读修饰键的那一行（修饰键让位）显示的是纯符号，不带键名 —— 靠的是
    /// `modifiersOnly` 这个开关，不是「keyCode 0 表示没键」：A 的键码就是 0，
    /// 截图的默认快捷键 ⌘⇧A 就长在 0 上，普通模式下的 0 必须显示成 A。
    func testDisplayStringForModifierOnlyValues() {
        let view = ShortcutRecorderView()
        view.modifiersOnly = true
        view.keyCode = 0
        view.flags = 0x100000 | 0x80000 | 0x20000
        XCTAssertEqual(view.displayString, "⌘⌥⇧")
        view.flags = 0x800000
        XCTAssertEqual(view.displayString, "fn")
        view.flags = 0
        XCTAssertEqual(view.displayString, "")
        // 反向对照：普通快捷键仍然带 key code 的名字。
        view.modifiersOnly = false
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
