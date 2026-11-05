// 「重置到预设」从不可撤销的批量覆盖改成「先确认、再留 10 秒撤销」之后的账：
// 快照要按重置写的那张表逐键取原值，撤销要逐键写回 —— 而不是按类型重新推导
// 一份默认值（那样用户自己的颜色、快捷键、阈值全会丢）。
import XCTest
import Foundation
import Storage
@testable import Preferences

final class PreferencesResetUndoTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.ResetUndo"

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func makePrefs() -> UserPreferences {
        UserPreferences(storage: PreferencesStorage(defaults: UserDefaults(suiteName: Self.suiteName)!))
    }

    func testResetWritesTheDefaultsItClaimsAndUndoBringsTheOriginalsBack() {
        let prefs = makePrefs()
        prefs.showIconInStatusBar = false
        prefs.minSimilarityScore = 77.5
        prefs.gestureTriggerButton = 3
        prefs.noteBackgroundAlpha = 0.2
        prefs.historyCilpboardListShortcut = "keyCode=8, flags=1048576"

        let snapshot = prefs.defaultsUndoSnapshot()
        XCTAssertEqual(snapshot.count, UserPreferences.resettableDefaultKeys.count,
                       "快照没覆盖整张可重置表：撤销时会有键留在默认值上")

        prefs.resetToDefaults()
        XCTAssertTrue(prefs.showIconInStatusBar)
        XCTAssertEqual(prefs.minSimilarityScore, StorageDefaults.minSimilarityScore, accuracy: 0.0001)
        XCTAssertEqual(prefs.gestureTriggerButton, StorageDefaults.gestureTriggerButton)
        XCTAssertEqual(prefs.noteBackgroundAlpha, StorageDefaults.noteBackgroundAlpha, accuracy: 0.0001)
        XCTAssertEqual(prefs.historyCilpboardListShortcut, StorageDefaults.historyCilpboardListShortcut)

        prefs.restoreDefaults(snapshot)
        XCTAssertFalse(prefs.showIconInStatusBar, "撤销没把开关写回用户原来的值")
        XCTAssertEqual(prefs.minSimilarityScore, 77.5, accuracy: 0.0001,
                       "撤销把阈值写成了默认值或别的数 —— 快照取的不是原值")
        XCTAssertEqual(prefs.gestureTriggerButton, 3, "撤销没写回用户录的起手键")
        XCTAssertEqual(prefs.noteBackgroundAlpha, 0.2, accuracy: 0.0001)
        XCTAssertEqual(prefs.historyCilpboardListShortcut, "keyCode=8, flags=1048576")
    }

    func testResetLeavesTheKeysOutsideItsTableAlone() {
        let prefs = makePrefs()
        // 语言和过滤名单原版重来不碰；更新检查那一组也不在 DefaultPreferences 里。
        prefs.whiteList = "com.example.one"
        prefs.autoCheckUpdates = false

        prefs.resetToDefaults()

        XCTAssertEqual(prefs.whiteList, "com.example.one", "重置顺手清掉了不在重置表里的键")
        XCTAssertFalse(prefs.autoCheckUpdates, "重置顺手改了更新检查开关")
    }

    func testTheResettableTableIsTheOnlySourceOfSnapshotKeys() {
        let keys = UserPreferences.resettableDefaultKeys
        XCTAssertEqual(Set(keys).count, keys.count, "同一把键在重置表里出现两次")
        XCTAssertTrue(keys.contains(.lineColorHex))
        XCTAssertTrue(keys.contains(.gestureTriggerButton))
        XCTAssertFalse(keys.contains(.language))
        XCTAssertFalse(keys.contains(.whiteList))
        XCTAssertFalse(keys.contains(.autoCheckUpdates))
        XCTAssertFalse(keys.contains(.screenshotSaveDirectory))
    }

    func testUndoAlsoRestoresAKeyThatHadNoExplicitValueBefore() {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        let storage = PreferencesStorage(defaults: defaults)
        // 前提：这一键此刻没有显式值（这个 suite 是新开的；WindowManagerTests
        // 这一套不调 register(defaults:)，注册表里也就没有它）。
        let key = StorageKey.userTerminal
        XCTAssertNil(storage.object(forKey: key),
                     "\(key.rawValue) 一开始就有值，这条判据的前提不成立")

        let prefs = makePrefs()
        let snapshot = prefs.defaultsUndoSnapshot()
        prefs.resetToDefaults()
        XCTAssertEqual(storage.object(forKey: key) as? String, StorageDefaults.userTerminal,
                       "重置没写这一键")

        prefs.restoreDefaults(snapshot)
        XCTAssertNil(storage.object(forKey: key),
                     "撤销把「原本没有显式值」的键留成了默认值：下次改默认值它就跟着变")
    }
}
