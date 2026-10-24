// 靠近锁屏页（移植版新增页）的行为取证：侧栏位置、默认关且没选设备就不算武装、
// 每个开关都要通知控制器重新 apply、两个 RSSI 阈值必须保持滞回、选设备要 id+名字一起落库。
// 判据一律取「写进库里的值」和「通知来过几次」，不去问页面自己声明的状态。
import XCTest
import AppKit
import SwiftUI
import Storage
import ProximityLock
@testable import Preferences

final class ProximityLockPreferencesTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.ProximityLock"

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

    /// 数一段时间内 `.macStrokeProximityLockDidChange` 来了几次：App 侧就靠这条通知
    /// 重新 apply，漏发了等于「界面上改了，功能没变」。
    private func countChanges(_ body: () -> Void) -> Int {
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .macStrokeProximityLockDidChange, object: nil, queue: nil
        ) { _ in notifications += 1 }
        body()
        NotificationCenter.default.removeObserver(observer)
        return notifications
    }

    // MARK: - 侧栏位置

    func testProximityLockSitsBetweenScreenshotAndAbout() {
        let tabs = PreferencesTab.allCases
        guard let screenshot = tabs.firstIndex(of: .screenshot),
              let proximity = tabs.firstIndex(of: .proximityLock),
              let about = tabs.firstIndex(of: .about) else {
            return XCTFail("侧栏缺少截图/靠近锁屏/关于其中一项")
        }
        XCTAssertEqual(proximity, screenshot + 1, "靠近锁屏要紧跟在截图页后面")
        // 「关于排在最后」只认下标，不写成 `proximity + 1`：往后每移植一个功能就往中间插一页，
        // 那条相邻断言每插一次都要来改这里，而它想守的其实只是「关于不能跑到中间去」。
        XCTAssertEqual(about, tabs.count - 1, "关于页始终排在最后")
        XCTAssertEqual(PreferencesTab.proximityLock.rawValue, "proximityLock",
                       "状态栏菜单只传 rawValue，键名一改入口就断")
    }

    // MARK: - 默认状态

    func testOffByDefaultAndNotArmed() {
        let prefs = makePrefs()
        XCTAssertFalse(prefs.enableProximityLock, "默认必须关着：原版没有这个功能")
        XCTAssertTrue(prefs.proximityDeviceID.isEmpty)
        XCTAssertTrue(prefs.proximityDeviceName.isEmpty)
        XCTAssertFalse(prefs.proximityAutoUnlock, "自动解锁要存明文密码，默认绝不能开")
        XCTAssertEqual(prefs.proximityUnlockRSSI, StorageDefaults.proximityUnlockRSSI)
        XCTAssertEqual(prefs.proximityLockRSSI, StorageDefaults.proximityLockRSSI)
        XCTAssertFalse(ProximityLockSettings.current(from: makeStorage()).isArmed,
                       "没选设备时即使打开开关也不算武装")
    }

    /// 打开总开关：落库 + 发通知。
    func testSwitchingOnPersistsAndNotifies() {
        let prefs = makePrefs()
        let notifications = countChanges { prefs.enableProximityLock = true }
        XCTAssertTrue(isolatedSuite().bool(forKey: StorageKey.enableProximityLock.rawValue))
        XCTAssertEqual(notifications, 1)
    }

    // MARK: - 选设备

    func testSelectingADeviceStoresIDAndNameTogether() {
        let prefs = makePrefs()
        prefs.enableProximityLock = true
        let notifications = countChanges {
            prefs.selectProximityDevice(id: "  ABC-123  ", name: "  我的手表  ")
        }
        XCTAssertEqual(prefs.proximityDeviceID, "ABC-123", "id 两头空白要削掉：它要拿去和广播里的 UUID 比")
        XCTAssertEqual(prefs.proximityDeviceName, "我的手表")
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.proximityDeviceID.rawValue), "ABC-123")
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.proximityDeviceName.rawValue), "我的手表")
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(ProximityLockSettings.current(from: makeStorage()).isArmed,
                      "开关已开 + 选了设备才算武装")
    }

    /// 选完必须有地方撤。没有「移除设备」这颗按钮时，想停掉判定只能去关总开关，
    /// 而总开关一关，下次要用还得重新扫一遍。
    func testForgettingTheDeviceClearsIDAndNameAndDisarms() {
        let prefs = makePrefs()
        prefs.enableProximityLock = true
        prefs.selectProximityDevice(id: "ABC-123", name: "我的手表")

        let notifications = countChanges { prefs.forgetProximityDevice() }
        XCTAssertTrue(prefs.proximityDeviceID.isEmpty)
        XCTAssertTrue(prefs.proximityDeviceName.isEmpty)
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.proximityDeviceID.rawValue), "")
        XCTAssertEqual(isolatedSuite().string(forKey: StorageKey.proximityDeviceName.rawValue), "")
        XCTAssertEqual(notifications, 1, "移除必须发通知：App 侧靠它重新 apply → stop")
        XCTAssertFalse(ProximityLockSettings.current(from: makeStorage()).isArmed,
                       "设备一清，即使总开关还开着也必须立刻解除武装")
    }

    /// 本来就没选设备时不该白发通知 —— 每条通知都会让控制器重新 apply 一次。
    func testForgettingWithNoDeviceSelectedDoesNothing() {
        let prefs = makePrefs()
        XCTAssertEqual(countChanges({ prefs.forgetProximityDevice() }), 0)
    }

    // MARK: - 两个阈值的滞回

    /// 「走开阈值比回来阈值还高」这种反过来的组合，人回来了永远判不出来，必须拒。
    /// 回滚走的是 didSet 里赋回 oldValue，所以还会再来一次写库+通知 —— 这没关系：
    /// 写回去的就是原来那个值，控制器 apply 时看到设置没变不会重启扫描。
    /// 判据取「库里最终是什么」，而不是「通知来过几次」。
    func testThresholdsThatWouldReverseThePairAreRejected() {
        let prefs = makePrefs()
        countChanges { prefs.proximityLockRSSI = -50 }
        XCTAssertEqual(prefs.proximityLockRSSI, StorageDefaults.proximityLockRSSI)
        XCTAssertEqual(isolatedSuite().integer(forKey: StorageKey.proximityLockRSSI.rawValue),
                       StorageDefaults.proximityLockRSSI,
                       "拒掉的值不该留在库里，最后落盘的仍是原来那个")

        // 反过来挪解锁阈值同理：先把解锁阈值挪到 -75（和 -80 差 5dB，刚好卡在最小滞回上），
        // 再把走开阈值挪到 -30（比解锁阈值还高）—— 这一步必须回滚。
        countChanges { prefs.proximityUnlockRSSI = -75 }
        XCTAssertEqual(prefs.proximityUnlockRSSI, -75, "-75/-80 是合法的一对，不该被连坐拒掉")
        countChanges { prefs.proximityLockRSSI = -30 }
        XCTAssertEqual(prefs.proximityLockRSSI, StorageDefaults.proximityLockRSSI, "越过解锁阈值要回滚")
    }

    func testThresholdsWithoutHysteresisAreRejected() {
        let prefs = makePrefs()
        // 挨在一起（差 0dB）时 RSSI 本身的抖动就会来回锁解。
        countChanges { prefs.proximityUnlockRSSI = -70 }
        XCTAssertEqual(prefs.proximityUnlockRSSI, -70, "-70 比默认的 -80 高 10dB，这一步本身合法")
        countChanges { prefs.proximityLockRSSI = -70 }
        XCTAssertEqual(prefs.proximityLockRSSI, StorageDefaults.proximityLockRSSI, "滞回不够要回滚")
        XCTAssertEqual(prefs.proximityUnlockRSSI, -70, "回滚只动被拒的那一个，别把已经合法的值也带走")
    }

    func testOutOfRangeThresholdsAreRejected() {
        let prefs = makePrefs()
        countChanges { prefs.proximityUnlockRSSI = -10 }
        XCTAssertEqual(prefs.proximityUnlockRSSI, StorageDefaults.proximityUnlockRSSI,
                       "BLE 广播实测最低也就 -100 左右，-10 只可能是写坏了")
        countChanges { prefs.proximityLockRSSI = -140 }
        XCTAssertEqual(prefs.proximityLockRSSI, StorageDefaults.proximityLockRSSI)
    }

    func testExactMinimumHysteresisIsAccepted() {
        let prefs = makePrefs()
        countChanges { prefs.proximityUnlockRSSI = -75 }
        countChanges { prefs.proximityLockRSSI = -80 }
        XCTAssertEqual(prefs.proximityUnlockRSSI, -75)
        XCTAssertEqual(prefs.proximityLockRSSI, -80)
        let settings = ProximityLockSettings.current(from: makeStorage())
        XCTAssertEqual(settings.unlockRSSI, -75, "写进去的和读出来的必须是同一对")
        XCTAssertEqual(settings.lockRSSI, -80)
    }

    // MARK: - 时间参数

    func testTimingsPersistAndNotify() {
        let prefs = makePrefs()
        let notifications = countChanges {
            prefs.proximityLockDelay = 30
            prefs.proximitySignalTimeout = 120
        }
        XCTAssertEqual(isolatedSuite().integer(forKey: StorageKey.proximityLockDelay.rawValue), 30)
        XCTAssertEqual(isolatedSuite().integer(forKey: StorageKey.proximitySignalTimeout.rawValue), 120)
        XCTAssertEqual(notifications, 2)
        let settings = ProximityLockSettings.current(from: makeStorage())
        XCTAssertEqual(settings.lockDelay, 30, accuracy: 0.001)
        XCTAssertEqual(settings.signalTimeout, 120, accuracy: 0.001)
    }

    func testAutoUnlockSwitchPersistsAndNotifies() {
        let prefs = makePrefs()
        let notifications = countChanges { prefs.proximityAutoUnlock = true }
        XCTAssertTrue(isolatedSuite().bool(forKey: StorageKey.proximityAutoUnlock.rawValue))
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(ProximityLockSettings.current(from: makeStorage()).autoUnlock)
    }

    // MARK: - 存量脏值

    /// 导入过别人的偏好 plist 的人可能带着一对反过来的阈值进来：读的时候必须整对退回默认，
    /// 否则界面显示一个用不上的数，功能却按另一套跑。
    func testGarbageInStoredDefaultsIsSanitisedOnRead() {
        isolatedSuite().set(true, forKey: StorageKey.enableProximityLock.rawValue)
        isolatedSuite().set("DEVICE", forKey: StorageKey.proximityDeviceID.rawValue)
        isolatedSuite().set(-95, forKey: StorageKey.proximityUnlockRSSI.rawValue)
        isolatedSuite().set(-40, forKey: StorageKey.proximityLockRSSI.rawValue)

        let prefs = makePrefs()
        XCTAssertEqual(prefs.proximityUnlockRSSI, StorageDefaults.proximityUnlockRSSI)
        XCTAssertEqual(prefs.proximityLockRSSI, StorageDefaults.proximityLockRSSI)
        XCTAssertTrue(prefs.enableProximityLock, "开关本身没坏，不该被连坐")
        XCTAssertEqual(prefs.proximityDeviceID, "DEVICE")
    }

    // MARK: - 页面渲染

    /// 新页面必须能真渲染出来（侧栏高亮、三段卡片、扫描按钮都在），
    /// 判据是渲染出来的位图里有像素，不是页面自己说「我画好了」。
    func testPageRendersOffscreen() throws {
        // 内存实现：页面 onAppear 会读钥匙串，而文件钥匙串的 ACL 弹窗在无头测试里没人点，
        // 进程会直接挂在那一行（本机实测过）。
        let host = NSHostingView(rootView: ProximityLockTabView(viewModel: makePrefs(),
                                                               passwords: InMemoryPasswordStore()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var drawn = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.01 { drawn += 1 }
            }
        }
        XCTAssertGreaterThan(drawn, 100, "靠近锁屏页几乎是空的，渲染没成功")
    }

    private func makeStorage() -> PreferencesStorage {
        PreferencesStorage(defaults: isolatedSuite())
    }
}
