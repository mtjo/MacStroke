// issue #75 那五行控件背后落盘的东西：「按住起手键 + 滚轮」的总开关、上下两档动作、
// 两条自定义快捷键。这一页的默认值必须是「关掉」—— 原版没这功能，装了新版的人不该
// 突然发现自己的滚轮被接管。
//
// 取证口径与手势页那两份一样：写一遍 → 换个 `UserPreferences` 实例读回来，判据取
// UserDefaults 里真正落盘的键，而不是内存里那个 @Published。App 层（CanvasManager 的
// 那三条闭包）每事件现读 `getIntOptional` / `getStringOptional`，取不到才走
// `StorageDefaults` —— 所以「没落盘」和「落成默认值」两边必须答一样，否则症状是
// 偏好页显示关着、运行时却按另一个数走。
import XCTest
import Foundation
import Storage
@testable import Preferences
@testable import RuleEngine

final class WheelGestureRowsTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.WheelGestureRows"

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

    private func preferences() -> UserPreferences {
        UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
    }

    // MARK: - 默认值：关掉，且上下两档是「切上/下一个标签页」

    func testWheelGestureDefaultsAreOffWithTabPresets() {
        let prefs = preferences()
        XCTAssertFalse(prefs.wheelGestureEnabled, "默认关 = 原版行为：不接管任何滚轮")
        XCTAssertEqual(prefs.wheelGestureUpAction, 1)
        XCTAssertEqual(prefs.wheelGestureDownAction, 2)
        XCTAssertTrue(prefs.wheelGestureUpShortcut.isEmpty, "空串 = 这一格没录键")
        XCTAssertTrue(prefs.wheelGestureDownShortcut.isEmpty)
    }

    /// 默认整数与查表枚举之间的那道契约：1/2 必须是「上一个/下一个标签页」。
    /// 给 `WheelGestureActionKind` 插入或重排 case 而不动这里，老用户存过的数会全体跑位
    /// （上滚变成调音量就是这类改动的症状）。
    func testDefaultIntegersMapToTheExpectedActionKinds() {
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: StorageDefaults.wheelGestureUpAction), .tabPrevious)
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: StorageDefaults.wheelGestureDownAction), .tabNext)
    }

    // MARK: - 往返：写进去的要能读回来

    func testAllFiveValuesRoundTripThroughDisk() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))

        prefs.wheelGestureEnabled = true
        prefs.wheelGestureUpAction = 3
        prefs.wheelGestureDownAction = 4
        prefs.wheelGestureUpShortcut = "keyCode=5, flags=262144"
        prefs.wheelGestureDownShortcut = "keyCode=6, flags=262144"
        prefs.save()

        let reread = UserPreferences(storage: PreferencesStorage(defaults: suite))
        XCTAssertTrue(reread.wheelGestureEnabled)
        XCTAssertEqual(reread.wheelGestureUpAction, 3, "3 = 音量 +1 档")
        XCTAssertEqual(reread.wheelGestureDownAction, 4, "4 = 音量 −1 档")
        XCTAssertEqual(reread.wheelGestureUpShortcut, "keyCode=5, flags=262144")
        XCTAssertEqual(reread.wheelGestureDownShortcut, "keyCode=6, flags=262144")
    }

    /// 快捷键那一格「清除」后落的是空串，而 App 层把空串当没配（不投键、也不吞事件）。
    /// 这里钉的是「清得掉、且清完读回空」—— 若 setString 把空串省掉，读回来的是旧键。
    func testClearedShortcutPersistsAsEmpty() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))
        prefs.wheelGestureUpShortcut = "keyCode=5, flags=262144"
        prefs.save()

        prefs.wheelGestureUpShortcut = ""
        prefs.save()

        XCTAssertEqual(UserPreferences(storage: PreferencesStorage(defaults: suite)).wheelGestureUpShortcut, "",
                       "清除必须真的覆盖掉旧值")
    }

    // MARK: - 全新装：键从没落过盘

    /// 构造阶段不许把这些键提前写进去（写了就再也分不清「用户真调过」和「没用过」）。
    func testFreshInstallReadsDefaultsWithoutWritingTheKeys() {
        let prefs = preferences()
        XCTAssertFalse(prefs.wheelGestureEnabled)
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.wheelGestureEnabled.rawValue))
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.wheelGestureUpAction.rawValue))
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.wheelGestureUpShortcut.rawValue),
                     "读默认值不该顺手落盘")
    }

    // MARK: - 恢复默认

    func testResetToDefaultsWritesAllFiveBackToDisk() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))
        prefs.wheelGestureEnabled = true
        prefs.wheelGestureUpAction = 5
        prefs.wheelGestureDownAction = 3
        prefs.wheelGestureUpShortcut = "keyCode=5, flags=262144"
        prefs.wheelGestureDownShortcut = "keyCode=6, flags=262144"
        prefs.save()

        prefs.resetToDefaults()

        XCTAssertEqual(prefs.wheelGestureEnabled, StorageDefaults.wheelGestureEnabled)
        XCTAssertEqual(prefs.wheelGestureUpAction, StorageDefaults.wheelGestureUpAction)
        XCTAssertEqual(prefs.wheelGestureDownAction, StorageDefaults.wheelGestureDownAction)
        XCTAssertTrue(prefs.wheelGestureUpShortcut.isEmpty)
        XCTAssertTrue(prefs.wheelGestureDownShortcut.isEmpty)
        // 落盘的键也要一起写回默认：重置只改内存的话，重启后又变回来。
        XCTAssertTrue(suite.bool(forKey: StorageKey.wheelGestureEnabled.rawValue) == false)
        XCTAssertEqual(suite.integer(forKey: StorageKey.wheelGestureUpAction.rawValue),
                       StorageDefaults.wheelGestureUpAction)
        XCTAssertEqual(suite.string(forKey: StorageKey.wheelGestureUpShortcut.rawValue),
                       StorageDefaults.wheelGestureUpShortcut)
    }

    /// 「恢复默认」之后新建的实例必须读到同一套值（页面重开不是靠内存里的旧对象）。
    func testReloadedPreferencesSeeTheReset() {
        let prefs = preferences()
        prefs.wheelGestureEnabled = true
        prefs.wheelGestureUpAction = 5
        prefs.save()
        prefs.resetToDefaults()

        let reread = UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
        XCTAssertFalse(reread.wheelGestureEnabled)
        XCTAssertEqual(reread.wheelGestureUpAction, StorageDefaults.wheelGestureUpAction)
    }
}
