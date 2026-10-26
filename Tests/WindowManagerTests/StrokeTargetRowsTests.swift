// issue #22 那两行控件背后落盘的东西：「手势打到光标下的窗口」总开关 + 「投完把焦点还回去」。
// 这一组的默认值必须是「关掉」：它改的是「动作落到哪家」这条所有老规则都依赖的语义，
// 还会让人看见焦点跳一下 —— 装了新版的人不该莫名其妙换一种手势手感（原版没这功能）。
//
// 取证口径与滚轮那两份一样：写一遍 → 换个 `UserPreferences` 实例读回来，判据取 UserDefaults
// 里真正落盘的键，而不是内存里那个 @Published。App 层（main.swift 的 `strokeTargetSettings`）
// 每笔手势现读 `getBoolOptional(...) ?? StorageDefaults` —— 所以「键从没落过盘」和
// 「落成默认值」两边必须答一样，否则症状是偏好页显示关着、运行时却按另一个数走。
//
// 还有一条这里独有的坑：`restore` 的默认是 **true**，而没注册的 `UserDefaults.bool` 对从没写过的
// 键返回 false。于是「重置只改内存没落盘」这一种坏，光比 `bool(...)` 是抓不住的（没写过也是 false，
// 写没写都会红/绿得不对味）—— 下面用 `object(forKey:) != nil` 单独钉一次「真的落盘了」。
import XCTest
import Foundation
import Storage
@testable import Preferences
@testable import RuleEngine

final class StrokeTargetRowsTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.StrokeTargetRows"

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

    /// App 层那一读的写法（`main.swift` 的 `strokeTargetSettings`）。用它当判据而不是比
    /// `UserPreferences` 的属性：偏好页与运行时各读各的，两边算出的档位不一样就是
    /// 「页面显示关着，手势却按开着走」。
    private func appLayerSettings() -> StrokeTargetSettings {
        let storage = PreferencesStorage(defaults: isolatedSuite())
        return StrokeTargetSettings(
            enabled: storage.getBoolOptional(forKey: .strokeTargetsCursorWindow)
                ?? StorageDefaults.strokeTargetsCursorWindow,
            restoresFocus: storage.getBoolOptional(forKey: .strokeTargetRestoresFocus)
                ?? StorageDefaults.strokeTargetRestoresFocus
        )
    }

    // MARK: - 默认值：总开关关，还焦开

    func testStrokeTargetDefaultsAreOffWithRestoreOn() {
        let prefs = preferences()
        XCTAssertFalse(prefs.strokeTargetsCursorWindow, "默认关 = 原版行为：动作照旧打进抬手那一刻的前台")
        XCTAssertTrue(prefs.strokeTargetRestoresFocus,
                      "开着却不还焦 = 画一个手势等价于点一下那个窗口，用户接下来的打字会打进被跳过去的 App")
    }

    /// 全新装（键从没落过盘）时，App 层那一读必须和偏好页读到同一套值。
    /// 这里顺手把「为什么必须用 `getBoolOptional`」钉住：`getBool` 对没落盘的 `restore` 键返回
    /// false，跟默认值 true 相反 —— 谁哪天把它换成 `getBool`，这条就红。
    func testFreshInstallReadsDefaultsWithoutWritingTheKeys() {
        let prefs = preferences()
        XCTAssertFalse(prefs.strokeTargetsCursorWindow)
        XCTAssertTrue(prefs.strokeTargetRestoresFocus)
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.strokeTargetsCursorWindow.rawValue))
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.strokeTargetRestoresFocus.rawValue),
                     "读默认值不该顺手落盘")
        // App 层那一读（现读库 + 缺键回默认）与偏好页必须一致。
        let app = appLayerSettings()
        XCTAssertFalse(app.enabled)
        XCTAssertTrue(app.restoresFocus)
        // 反面：这就是那根不能碰的线。
        XCTAssertFalse(PreferencesStorage(defaults: isolatedSuite())
                        .getBool(forKey: .strokeTargetRestoresFocus),
                       "没落盘的键在 getBool 下是 false，与默认值相反 —— App 层用错读法就会跳到这一档")
    }

    // MARK: - 往返：写进去的要能读回来

    func testBothValuesRoundTripThroughDisk() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))

        prefs.strokeTargetsCursorWindow = true
        prefs.strokeTargetRestoresFocus = false
        prefs.save()

        let reread = UserPreferences(storage: PreferencesStorage(defaults: suite))
        XCTAssertTrue(reread.strokeTargetsCursorWindow)
        XCTAssertFalse(reread.strokeTargetRestoresFocus)
        // App 层那一读也要看到同样的值（它不经过 UserPreferences）。
        XCTAssertTrue(appLayerSettings().enabled)
        XCTAssertFalse(appLayerSettings().restoresFocus)
    }

    /// 两条各存各的：关掉总开关不许把「还焦」那一档一起清掉 —— 页面上它是**灰**掉的（只灰不藏），
    /// 用户重新开开关时应该回到自己上次配的那一档，而不是被悄悄改回默认。
    func testTurningTheMasterOffKeepsTheRestoreChoice() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))
        prefs.strokeTargetsCursorWindow = true
        prefs.strokeTargetRestoresFocus = false
        prefs.save()

        prefs.strokeTargetsCursorWindow = false
        prefs.save()

        XCTAssertTrue(suite.object(forKey: StorageKey.strokeTargetRestoresFocus.rawValue) != nil)
        XCTAssertFalse(UserPreferences(storage: PreferencesStorage(defaults: suite)).strokeTargetRestoresFocus,
                       "关总开关把还焦那档一起清了：再开时用户的配置没了")
    }

    // MARK: - 恢复默认

    func testResetToDefaultsWritesBothBackToDisk() {
        let suite = isolatedSuite()
        let prefs = UserPreferences(storage: PreferencesStorage(defaults: suite))
        prefs.strokeTargetsCursorWindow = true
        prefs.strokeTargetRestoresFocus = false
        prefs.save()

        prefs.resetToDefaults()

        XCTAssertFalse(prefs.strokeTargetsCursorWindow)
        XCTAssertTrue(prefs.strokeTargetRestoresFocus)
        // 落盘的键也要一起写回默认：重置只改内存的话，重启后又变回来。
        XCTAssertNotNil(suite.object(forKey: StorageKey.strokeTargetsCursorWindow.rawValue))
        XCTAssertNotNil(suite.object(forKey: StorageKey.strokeTargetRestoresFocus.rawValue),
                        "还焦的默认是 true，而没写过键的 bool() 也是 false —— 不钉「真的落盘」就分不清")
        XCTAssertFalse(suite.bool(forKey: StorageKey.strokeTargetsCursorWindow.rawValue))
        XCTAssertTrue(suite.bool(forKey: StorageKey.strokeTargetRestoresFocus.rawValue))
        XCTAssertTrue(appLayerSettings().restoresFocus)
    }

    /// 「恢复默认」之后新建的实例必须读到同一套值（页面重开不是靠内存里的旧对象）。
    func testReloadedPreferencesSeeTheReset() {
        let prefs = preferences()
        prefs.strokeTargetsCursorWindow = true
        prefs.strokeTargetRestoresFocus = false
        prefs.save()
        prefs.resetToDefaults()

        let reread = UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
        XCTAssertFalse(reread.strokeTargetsCursorWindow)
        XCTAssertTrue(reread.strokeTargetRestoresFocus)
    }

    // MARK: - 跨层契约

    /// `StorageDefaults` 与 `StrokeTargetSettings` 的默认必须一字不差地对上：RuleEngine 那边
    /// 用无参 `StrokeTargetSettings()` 当兜底（桩件、单测、以及将来别处的调用点），
    /// 一旦这里漂了，症状是「离线用例验的是另一套默认值」，装机上根本不成立。
    func testRuleEngineFallbackDefaultsMatchStorageDefaults() {
        XCTAssertEqual(StrokeTargetSettings.defaults.enabled, StorageDefaults.strokeTargetsCursorWindow)
        XCTAssertEqual(StrokeTargetSettings.defaults.restoresFocus, StorageDefaults.strokeTargetRestoresFocus)
        XCTAssertEqual(StrokeTargetSettings().enabled, StorageDefaults.strokeTargetsCursorWindow)
        XCTAssertEqual(StrokeTargetSettings().restoresFocus, StorageDefaults.strokeTargetRestoresFocus)
    }
}
