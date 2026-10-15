//
//  ScreenshotPreferencesTests.swift
//
//  截图页（移植版新增页）的偏好侧取证：侧栏位置、几个开关和放大镜倍率的默认值与写库时机。
//  判据一律取「另一份 UserPreferences 从同一个库里读回来」，不读页面自己的状态 ——
//  截图侧读的是库，页面状态和库不一致时用户看到的和实际落盘的两回事。
//

import XCTest
import Storage
@testable import Preferences

final class ScreenshotPreferencesTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.ScreenshotPrefs"

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

    private func makePrefs() -> UserPreferences {
        UserPreferences(storage: PreferencesStorage(defaults: isolatedSuite()))
    }

    // MARK: - 侧栏位置

    func testScreenshotSitsBetweenRemoteControlAndAbout() {
        let tabs = PreferencesTab.allCases
        guard let remote = tabs.firstIndex(of: .remoteControl),
              let screenshot = tabs.firstIndex(of: .screenshot),
              let about = tabs.firstIndex(of: .about) else {
            return XCTFail("侧栏缺少远程控制/截图/关于其中一项")
        }
        XCTAssertEqual(screenshot, remote + 1, "截图页要紧跟在远程控制后面")
        XCTAssertEqual(about, screenshot + 1, "新增页都排在关于之前：关于永远是最后一页")
    }

    // MARK: - 默认值

    func testFreshInstallSavesNothingAndSnaps() {
        let prefs = makePrefs()
        XCTAssertFalse(prefs.screenshotAutoSave, "默认不能往硬盘写：静默生成文件是打扰")
        XCTAssertTrue(prefs.screenshotSnapToWindows, "吸附是遮罩一直以来的行为")
        XCTAssertTrue(prefs.screenshotMagnifier, "放大镜默认开：Retina 上不数像素格根本卡不准边")
        XCTAssertEqual(prefs.screenshotMagnification, 8, "默认 8 倍：4 倍太糊、16 倍只能看到指甲盖大一块")
        XCTAssertTrue(prefs.screenshotSaveDirectory.isEmpty)
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.screenshotSaveDirectory.rawValue),
                     "没动过这一页就不该往库里写路径")
    }

    /// 快捷键走的是「读不到就用默认」这条路，而不是启动时先写一遍库：老用户的域里
    /// 没这个键，写一遍会把「没用过」变成「已选 ⌘⇧A」，App 层的变更监听还会白挂一次。
    func testShortcutReadsTheDefaultButWritesNothingUntilTouched() {
        let prefs = makePrefs()
        XCTAssertEqual(prefs.screenshotShortcut, StorageDefaults.screenshotShortcut)
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.screenshotShortcut.rawValue),
                     "没改过就不该往库里写快捷键")

        prefs.screenshotShortcut = "keyCode=5, flags=786432"
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.screenshotShortcut.rawValue),
                       "keyCode=5, flags=786432", "App 层听的是库，页面状态不落库等于没设")
        XCTAssertEqual(makePrefs().screenshotShortcut, "keyCode=5, flags=786432")
    }

    // MARK: - 写库

    func testEverySettingReachesTheStoreForTheScreenshotModule() {
        let prefs = makePrefs()
        let directory = NSTemporaryDirectory()
        prefs.screenshotAutoSave = true
        prefs.screenshotSaveDirectory = directory
        prefs.screenshotSnapToWindows = false
        prefs.screenshotMagnifier = false
        prefs.screenshotMagnification = 16

        // 截图侧每次会话现取快照，所以「读回来」等价于「下一张图的行为」。
        let reloaded = makePrefs()
        XCTAssertTrue(reloaded.screenshotAutoSave)
        XCTAssertEqual(reloaded.screenshotSaveDirectory, directory)
        XCTAssertFalse(reloaded.screenshotSnapToWindows)
        XCTAssertFalse(reloaded.screenshotMagnifier)
        XCTAssertEqual(reloaded.screenshotMagnification, 16)
        XCTAssertEqual(isolatedSuite().integer(forKey: StorageKey.screenshotMagnification.rawValue), 16,
                       "下拉框选完就得写进库，否则放大镜下次还是默认档")
    }

    /// 配置备份（issue #69）导出的是整个 domain 的键值，路径为空串也得照样写进去：
    /// 「没选过」和「选了桌面」是两个状态，合并成空串会丢用户选的位置。
    func testChoosingAndClearingTheLocationAreBothPersisted() {
        let prefs = makePrefs()
        prefs.screenshotSaveDirectory = NSTemporaryDirectory()
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.screenshotSaveDirectory.rawValue),
                       NSTemporaryDirectory())

        prefs.screenshotSaveDirectory = ""
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.screenshotSaveDirectory.rawValue), "",
                       "清空白要真的写成空串，而不是留着一个已经选过的位置")
    }
}
