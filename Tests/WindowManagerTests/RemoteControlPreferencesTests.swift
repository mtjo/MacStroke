// 远程控制页（移植版新增页）的行为取证：侧栏位置、开关默认关（关掉时行为等同原版）、
// 打开时自动备好配对码、非法端口回滚、改配对码要通知服务重启。
import XCTest
import AppKit
import SwiftUI
import Storage
import RemoteControl
@testable import Preferences

final class RemoteControlPreferencesTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.RemoteControl"

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

    func testRemoteControlSitsBetweenClipboardAndAbout() {
        let tabs = PreferencesTab.allCases
        guard let clipboard = tabs.firstIndex(of: .clipboard),
              let remote = tabs.firstIndex(of: .remoteControl),
              let about = tabs.firstIndex(of: .about) else {
            return XCTFail("侧栏缺少粘贴板/远程控制/关于其中一项")
        }
        XCTAssertEqual(remote, clipboard + 1, "远程控制要紧跟在粘贴板后面")
        XCTAssertEqual(about, remote + 1, "远程控制要在关于前面")
    }

    // MARK: - 开关与配对码

    func testServiceIsOffByDefaultAndListensOnNothing() {
        let prefs = makePrefs()
        XCTAssertFalse(prefs.enableRemoteControl, "默认必须关着：原版没有任何网络接口")
        XCTAssertTrue(prefs.remoteControlToken.isEmpty)
        XCTAssertNil(isolatedSuite().object(forKey: StorageKey.remoteControlToken.rawValue),
                     "没打开过就不该往库里写配对码")
    }

    func testSwitchingOnMintsAUsablePairingCode() {
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .macStrokeRemoteControlDidChange, object: nil, queue: nil
        ) { _ in notifications += 1 }

        let prefs = makePrefs()
        prefs.enableRemoteControl = true

        XCTAssertEqual(prefs.remoteControlToken.count, 6)
        XCTAssertTrue(prefs.remoteControlToken.allSatisfy {
            "ABCDEFGHJKMNPQRSTUVWXYZ23456789".contains($0)
        })
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.remoteControlToken.rawValue),
                       prefs.remoteControlToken,
                       "配对码要先落库，二维码才敢显示")
        XCTAssertGreaterThan(notifications, 0, "开关必须通知服务重启")
        NotificationCenter.default.removeObserver(observer)
    }

    func testSwitchingOffKeepsThePairingCode() {
        let prefs = makePrefs()
        prefs.enableRemoteControl = true
        let token = prefs.remoteControlToken

        prefs.enableRemoteControl = false

        XCTAssertEqual(prefs.remoteControlToken, token, "关掉服务不该顺手换码")
        XCTAssertEqual(makePrefs().remoteControlToken, token)
        XCTAssertFalse(makePrefs().enableRemoteControl)
    }

    func testRegeneratingTheTokenReplacesTheStoredOne() {
        let prefs = makePrefs()
        prefs.enableRemoteControl = true
        let old = prefs.remoteControlToken

        prefs.regenerateRemoteToken()

        XCTAssertNotEqual(prefs.remoteControlToken, old)
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.remoteControlToken.rawValue),
                       prefs.remoteControlToken)
    }

    // MARK: - 端口

    func testPortSurvivesAReload() {
        let prefs = makePrefs()
        prefs.enableRemoteControl = true
        prefs.remoteControlPort = 9527

        XCTAssertEqual(makePrefs().remoteControlPort, 9527)
    }

    /// 反向对照：微信 TCP 连不上黑名单端口，所以这类值既不能落库，也不能把界面留在
    /// 一个看似成功的数字上。
    func testForbiddenPortIsRejectedAndRolledBack() {
        let prefs = makePrefs()
        prefs.enableRemoteControl = true
        prefs.remoteControlPort = 9527

        prefs.remoteControlPort = 3306

        XCTAssertEqual(prefs.remoteControlPort, 9527, "黑名单端口要回滚")
        XCTAssertEqual(prefs.lastRejectedPort, 9527)
        XCTAssertEqual(isolatedSuite().integer(forKey: StorageKey.remoteControlPort.rawValue), 9527)

        prefs.remoteControlPort = 8080
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(8080), "8000-8100 整段都在黑名单里")

        prefs.remoteControlPort = 8848
        XCTAssertEqual(prefs.remoteControlPort, 8848)
        XCTAssertNil(prefs.lastRejectedPort)
    }

    func testLowPortIsRejectedToo() {
        let prefs = makePrefs()
        prefs.enableRemoteControl = true
        prefs.remoteControlPort = 8848

        prefs.remoteControlPort = 80

        XCTAssertEqual(prefs.remoteControlPort, 8848)
    }

    // MARK: - 设置与服务的对接

    func testSettingsSnapshotFallsBackWhenTheStoredPortIsForbidden() {
        let suite = isolatedSuite()
        suite.set(true, forKey: StorageKey.enableRemoteControl.rawValue)
        suite.set(6379, forKey: StorageKey.remoteControlPort.rawValue)
        suite.set("ABCDEF", forKey: StorageKey.remoteControlToken.rawValue)

        let settings = RemoteControlSettings.current(from: PreferencesStorage(defaults: suite))

        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.port, StorageDefaults.remoteControlPort,
                       "库里是黑名单端口时不能按原样去监听")
        XCTAssertEqual(settings.token, "ABCDEF")
    }
}
