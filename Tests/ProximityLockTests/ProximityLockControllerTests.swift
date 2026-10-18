//
//  ProximityLockControllerTests.swift
//  ProximityLockTests
//
//  整条链路的离线取证：假信号源喂帧 → 真判定状态机 → 假锁屏/假注入记账。
//  最重要的两条是「没开功能时连蓝牙都不碰」和「走开只锁一次」。
//

import XCTest
import Storage
@testable import ProximityLock

final class ProximityLockControllerTests: XCTestCase {
    private final class Clock {
        var time: TimeInterval = 0
    }

    private var session: FakeSession!
    private var source: FakeSource!
    private var sourceFactoryCalls = 0
    private var clock: Clock!
    private var injectedPasswords: [String] = []
    private var injectResult: PasswordInjector.Result = .submitted
    /// apply() 不带参数时会去读真的 UserDefaults，测试里必须喂回注入的那份。
    private var currentSettings: ProximityLockSettings!

    override func setUp() {
        super.setUp()
        session = FakeSession()
        source = FakeSource()
        sourceFactoryCalls = 0
        clock = Clock()
        injectedPasswords = []
        injectResult = .submitted
        currentSettings = nil
    }

    private func makeSettings(enabled: Bool = true,
                              deviceID: String = "WATCH-UUID",
                              autoUnlock: Bool = false,
                              lockDelay: TimeInterval = 3,
                              signalTimeout: TimeInterval = 60) -> ProximityLockSettings {
        ProximityLockSettings(enabled: enabled, deviceID: deviceID, deviceName: "测试手表",
                              unlockRSSI: -60, lockRSSI: -80,
                              lockDelay: lockDelay, signalTimeout: signalTimeout,
                              autoUnlock: autoUnlock)
    }

    private func makeController(settings: ProximityLockSettings,
                                passwords: UnlockPasswordStoring = InMemoryPasswordStore()) -> ProximityLockController {
        currentSettings = settings
        return ProximityLockController(sourceFactory: { [weak self] in
                                    self?.sourceFactoryCalls += 1
                                    return self?.source ?? FakeSource()
                                },
                                screen: session.screenLock(),
                                passwords: passwords,
                                runInjection: { [weak self] password, completion in
                                    self?.injectedPasswords.append(password)
                                    completion(self?.injectResult ?? .submitted)
                                },
                                settings: settings,
                                now: { [weak self] in self?.clock.time ?? 0 },
                                log: { _ in })
    }

    /// 喂一帧目标设备的广播，然后把时钟推到那一秒并判定一次。
    private func step(_ controller: ProximityLockController, rssi: Int, at time: TimeInterval) {
        clock.time = time
        source.report(rssi: rssi, at: time)
        controller.tick(timestamp: time)
    }

    /// 走完整条时间线到「已锁屏」，返回锁屏那一刻的时间。
    @discardableResult
    private func driveToLock(_ controller: ProximityLockController, lockDelay: TimeInterval = 3) -> TimeInterval {
        step(controller, rssi: -50, at: 0)
        XCTAssertEqual(controller.presence, .present)
        var time: TimeInterval = 0
        while time < 200 {
            time += 1
            step(controller, rssi: -95, at: time)
            if session.lockCalls > 0 { return time }
        }
        XCTFail("两秒钟的时间线里居然没锁屏")
        return time
    }

    // MARK: - 不该动的时候一次都别动

    /// 功能关着就连信号源都不构造。CBCentralManager 一构造系统就弹蓝牙授权框 ——
    /// 无人值守的机器上弹一个没人点的框，等于把进程挂在那儿。
    func testDisabledFeatureNeverTouchesBluetooth() {
        let controller = makeController(settings: makeSettings(enabled: false))
        controller.apply(currentSettings)
        XCTAssertEqual(sourceFactoryCalls, 0)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(source.startCount, 0)
    }

    /// 开了但没选设备，同样不许碰蓝牙。
    func testEnabledWithoutDeviceNeverTouchesBluetooth() {
        let controller = makeController(settings: makeSettings(deviceID: ""))
        controller.apply(currentSettings)
        XCTAssertEqual(sourceFactoryCalls, 0)
        XCTAssertFalse(controller.isRunning)
    }

    /// 冷启动时设备不在旁边不算「走开」：一次都不该锁。
    func testColdStartWithAbsentDeviceNeverLocks() {
        let controller = makeController(settings: makeSettings())
        controller.apply(currentSettings)
        for second in 0 ... 200 {
            step(controller, rssi: -95, at: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, 0)
        XCTAssertEqual(controller.presence, .unknown)
    }

    /// 压根没收到广播（蓝牙关了 / 设备没电）也不能锁。
    func testColdStartWithoutAdvertisementsNeverLocks() {
        let controller = makeController(settings: makeSettings())
        controller.apply(currentSettings)
        for second in stride(from: 0, through: 300, by: 5) {
            clock.time = TimeInterval(second)
            controller.tick(timestamp: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, 0)
    }

    // MARK: - 锁屏

    func testDepartureLocksExactlyOnce() {
        let controller = makeController(settings: makeSettings(lockDelay: 3))
        controller.apply(currentSettings)
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(source.targetDeviceID, "WATCH-UUID", "过滤要在源上做，否则每帧都要过主线程")

        let lockedAt = driveToLock(controller)
        XCTAssertEqual(session.lockCalls, 1)
        XCTAssertEqual(controller.presence, .absent)
        XCTAssertEqual(controller.lastOutcome, .locked)

        // 人一直不在，也不该一秒锁一次。
        for offset in 1 ... 60 {
            step(controller, rssi: -95, at: lockedAt + TimeInterval(offset))
        }
        XCTAssertEqual(session.lockCalls, 1)
    }

    /// 锁屏延时是真的延时：早一秒都不能锁。
    func testLockWaitsOutTheDelay() {
        let controller = makeController(settings: makeSettings(lockDelay: 3))
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)
        // t=1 均值跌破阈值开始计时，t=3 才满 3 秒。
        step(controller, rssi: -95, at: 1)
        XCTAssertEqual(session.lockCalls, 0)
        step(controller, rssi: -95, at: 2)
        XCTAssertEqual(session.lockCalls, 0)
        step(controller, rssi: -95, at: 3)
        XCTAssertEqual(session.lockCalls, 0, "t=1 起算，t=3 才弱了 2 秒")
        step(controller, rssi: -95, at: 4)
        XCTAssertEqual(session.lockCalls, 1, "弱满 3 秒就该锁")
    }

    /// 走开途中回来了，计时必须作废。
    func testComingBackCancelsThePendingLock() {
        let controller = makeController(settings: makeSettings(lockDelay: 3))
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)
        step(controller, rssi: -95, at: 1)
        step(controller, rssi: -95, at: 2)
        step(controller, rssi: -50, at: 3)
        for second in 4 ... 20 {
            step(controller, rssi: -50, at: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, 0)
        XCTAssertEqual(controller.presence, .present)
    }

    /// 屏幕已经锁着（用户自己按了 ⌃⌘Q）就别再提交一次：
    /// 兜底那条 ⌃⌘Q 会把按键打进前台 App。
    func testDoesNotLockTwiceWhenScreenIsAlreadyLocked() {
        let controller = makeController(settings: makeSettings(lockDelay: 3))
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)
        session.isLocked = true
        for second in 1 ... 5 {
            step(controller, rssi: -95, at: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, 0)
        XCTAssertEqual(controller.lastOutcome, .alreadyLocked)
        XCTAssertEqual(controller.presence, .absent, "状态机该记「人走了」，只是不用再锁一次")
    }

    /// 锁屏接口失败要如实说出来，不能假装锁上了。
    func testLockFailureIsReported() {
        session.lockResult = false
        let controller = makeController(settings: makeSettings(lockDelay: 3))
        controller.apply(currentSettings)
        driveToLock(controller)
        XCTAssertEqual(controller.lastOutcome, .lockFailed)
    }

    // MARK: - 解锁

    /// 只锁不解是完全可用的组合，而且是默认组合：没开自动解锁时一个字都不能打。
    func testReturnWithoutAutoUnlockDoesNotInject() {
        let controller = makeController(settings: makeSettings(autoUnlock: false),
                                        passwords: InMemoryPasswordStore(password: "hunter2"))
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = true
        session.secureInputPID = 181
        clock.time = 500
        source.report(rssi: -50, at: 500)
        controller.tick(timestamp: 500)
        XCTAssertEqual(injectedPasswords, [])
        XCTAssertEqual(controller.lastOutcome, .returnedNoAutoUnlock)
        XCTAssertEqual(controller.presence, .present)
    }

    func testReturnWithAutoUnlockInjectsTheStoredPassword() {
        let controller = makeController(settings: makeSettings(autoUnlock: true),
                                        passwords: InMemoryPasswordStore(password: "hunter2"))
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = true
        session.secureInputPID = 181
        clock.time = 500
        source.report(rssi: -50, at: 500)
        controller.tick(timestamp: 500)
        XCTAssertEqual(injectedPasswords, ["hunter2"])
        XCTAssertEqual(controller.lastOutcome, .unlocked)
    }

    /// 密码框不在前台（屏保没退、安全输入属于别的进程）→ 不注入。
    /// 这条挡住的就是「密码被打进聊天窗」那种事故。
    func testAutoUnlockRefusesWhenThePasswordFieldIsNotUp() {
        let controller = makeController(settings: makeSettings(autoUnlock: true),
                                        passwords: InMemoryPasswordStore(password: "hunter2"))
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = true
        session.secureInputPID = nil
        clock.time = 500
        source.report(rssi: -50, at: 500)
        controller.tick(timestamp: 500)
        XCTAssertEqual(injectedPasswords, [])
        XCTAssertEqual(controller.lastOutcome, .fieldNotAcceptingPassword)
    }

    func testAutoUnlockWithoutAStoredPasswordSaysSo() {
        let controller = makeController(settings: makeSettings(autoUnlock: true),
                                        passwords: InMemoryPasswordStore())
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = true
        session.secureInputPID = 181
        clock.time = 500
        source.report(rssi: -50, at: 500)
        controller.tick(timestamp: 500)
        XCTAssertEqual(injectedPasswords, [])
        XCTAssertEqual(controller.lastOutcome, .noStoredPassword)
    }

    func testInjectionFailureIsReportedWithoutRetryingForever() {
        injectResult = .exhaustedAttempts
        let controller = makeController(settings: makeSettings(autoUnlock: true),
                                        passwords: InMemoryPasswordStore(password: "wrong"))
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = true
        session.secureInputPID = 181
        clock.time = 500
        source.report(rssi: -50, at: 500)
        controller.tick(timestamp: 500)
        XCTAssertEqual(injectedPasswords.count, 1, "一次回来只试一轮，重试在注入器内部封顶")
        XCTAssertEqual(controller.lastOutcome, .injectionFailed)
    }

    /// 用户自己按键盘解开了锁：状态要纠正回 present，但一个字都不能注入。
    func testManualUnlockResyncsWithoutInjecting() {
        let controller = makeController(settings: makeSettings(autoUnlock: true),
                                        passwords: InMemoryPasswordStore(password: "hunter2"))
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = false   // 用户自己解开的
        clock.time = 500
        source.report(rssi: -50, at: 500)
        controller.tick(timestamp: 500)
        XCTAssertEqual(injectedPasswords, [])
        XCTAssertEqual(controller.presence, .present)
    }

    // MARK: - 屏幕熄着的时候一个字都不打

    /// 本机 macOS 27 实测的坏情况：01:33:26 锁屏 → 01:33:31 屏熄 → 01:33:55 那三轮注入
    /// 全打在黑屏上，一次都没解开（应用日志的时间戳落在 pmset 的 off/on 区间里）。
    /// 熄屏时 `isAcceptingPassword` 仍然是真，拦不住 —— 只能另外问一句屏亮不亮。
    func testReturnWhileDisplayIsAsleepInjectsNothing() {
        let controller = makeController(settings: makeSettings(autoUnlock: true),
                                        passwords: InMemoryPasswordStore(password: "hunter2"))
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = true
        session.secureInputPID = 181
        session.isDisplayAsleep = true
        step(controller, rssi: -50, at: 500)
        XCTAssertEqual(injectedPasswords, [], "屏熄着时绝不能打密码：打了也进不去，还白烧一轮")
        XCTAssertEqual(controller.lastOutcome, .waitingForDisplayWake)
        XCTAssertEqual(controller.presence, .present, "判定要知道人已经回来了，欠的解锁才有着落")
    }

    /// 熄屏那一次没打成不算完：屏一亮就补，而且一次唤醒只补一轮。
    func testPendingUnlockIsRetriedOnceWhenTheDisplayWakes() {
        let controller = makeController(settings: makeSettings(autoUnlock: true),
                                        passwords: InMemoryPasswordStore(password: "hunter2"))
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = true
        session.secureInputPID = 181
        session.isDisplayAsleep = true
        step(controller, rssi: -50, at: 500)
        XCTAssertEqual(injectedPasswords, [])
        // 亮起来之前这些 tick 一个字都不能打（真机上他可能十几分钟后才碰一下触控板）。
        for second in 501 ... 504 {
            step(controller, rssi: -50, at: TimeInterval(second))
        }
        XCTAssertEqual(injectedPasswords, [])

        session.isDisplayAsleep = false
        step(controller, rssi: -50, at: 505)
        XCTAssertEqual(injectedPasswords, ["hunter2"], "屏亮了就把那一次补上，不能等下一次「回来」跳变")
        XCTAssertEqual(controller.lastOutcome, .unlocked)
        for second in 506 ... 515 {
            step(controller, rssi: -50, at: TimeInterval(second))
        }
        XCTAssertEqual(injectedPasswords.count, 1, "一次唤醒只补一轮：解不该一秒重打一遍密码")
    }

    /// 他自己把锁解了：欠账要销掉，屏再亮也不能凭空打一遍。
    func testPendingUnlockIsCancelledByAManualUnlock() {
        let controller = makeController(settings: makeSettings(autoUnlock: true),
                                        passwords: InMemoryPasswordStore(password: "hunter2"))
        controller.apply(currentSettings)
        driveToLock(controller)
        session.isLocked = true
        session.secureInputPID = 181
        session.isDisplayAsleep = true
        step(controller, rssi: -50, at: 500)
        XCTAssertEqual(controller.lastOutcome, .waitingForDisplayWake)

        session.isLocked = false          // 他自己按键盘解开的
        session.isDisplayAsleep = false
        step(controller, rssi: -50, at: 501)
        XCTAssertEqual(injectedPasswords, [], "锁已经开了还补注入，等于把密码打进当时的任意输入框")
        XCTAssertEqual(controller.lastOutcome, .unlockCancelledByHand,
                       "界面那句话必须跟着改口，不然会一直挂着「等亮起来再解锁」而屏幕早就开了")

        // 再走开一次、再回来一次：注入照常只有一轮，欠账没留成后门。
        // 回来这段要连喂五帧 —— 判定看的是 5 帧滑窗均值，一帧强信号翻不了状态。
        session.isLocked = true
        for second in 502 ... 510 {
            step(controller, rssi: -95, at: TimeInterval(second))
        }
        for second in 511 ... 518 {
            step(controller, rssi: -50, at: TimeInterval(second))
        }
        XCTAssertEqual(injectedPasswords.count, 1)
    }

    /// 等亮起来这段时间人又走开了：欠账作废。下次屏亮时不该打密码 —— 那时候人不在。
    func testPendingUnlockIsCancelledWhenThePersonLeavesAgain() {
        let controller = makeController(settings: makeSettings(autoUnlock: true, lockDelay: 3),
                                        passwords: InMemoryPasswordStore(password: "hunter2"))
        controller.apply(currentSettings)
        driveToLock(controller, lockDelay: 3)
        session.isLocked = true
        session.secureInputPID = 181
        session.isDisplayAsleep = true
        step(controller, rssi: -50, at: 500)
        XCTAssertEqual(controller.lastOutcome, .waitingForDisplayWake)

        for second in 501 ... 508 {
            step(controller, rssi: -95, at: TimeInterval(second))
        }
        XCTAssertEqual(controller.presence, .absent)
        session.isDisplayAsleep = false
        step(controller, rssi: -95, at: 509)
        XCTAssertEqual(injectedPasswords, [])
        XCTAssertEqual(controller.lastOutcome, .unlockCancelledPersonLeft,
                       "欠账作废这件事也要在界面上说清楚，不能留着「等亮起来再解锁」")
    }

    // MARK: - 挂起

    /// 挂起期间（远程控制接管、录屏中）不锁屏，而且恢复那一刻不会突然锁 ——
    /// 计时是从零重新起的。
    func testPauseBlocksLockingAndRestartsTheDelay() {
        let controller = makeController(settings: makeSettings(lockDelay: 3))
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)

        clock.time = 1
        controller.pause(for: 10, reason: "远程控制接管")
        XCTAssertTrue(controller.isPaused)
        for second in 1 ... 10 {
            step(controller, rssi: -95, at: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, 0, "挂起期内不能锁屏")

        // 挂起到 t=11 结束，t=12 才重新开始计时 → t=15 满 3 秒。
        for second in 12 ... 14 {
            step(controller, rssi: -95, at: TimeInterval(second))
            XCTAssertEqual(session.lockCalls, 0, "第 \(second) 秒：计时是从挂起结束才起的")
        }
        step(controller, rssi: -95, at: 15)
        XCTAssertEqual(session.lockCalls, 1)
    }

    /// App 层挂进来的「这台机器正被人用着」（远程控制接管、截图遮罩摊开）和挂起期同效：
    /// 不锁屏，而且忙完之后走开计时从零起算 —— 手表搁在桌上信号一晃，不该把正在进行的
    /// 那场远程操作锁断。
    func testExternallyBusyBlocksLockingAndRestartsTheDelay() {
        let controller = makeController(settings: makeSettings(lockDelay: 3))
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)

        var busy = true
        controller.isExternallyBusy = { busy }
        for second in 1 ... 6 {
            step(controller, rssi: -95, at: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, 0, "有人在用这台机器时不能锁屏")

        busy = false
        // t=7 才重新开始计时 → t=10 满 3 秒。
        for second in 7 ... 9 {
            step(controller, rssi: -95, at: TimeInterval(second))
            XCTAssertEqual(session.lockCalls, 0, "第 \(second) 秒：计时是从不忙了才起的")
        }
        step(controller, rssi: -95, at: 10)
        XCTAssertEqual(session.lockCalls, 1)
    }

    /// 忙的时候 dBm 读数仍然刷新（窗口在 ingest 时就更新），但 presence 故意停在原状态：
    /// 走开的那次跳变要留给不忙之后的 tick，否则 `.lock` 会被白吃掉一次。
    func testExternallyBusyKeepsTheReadoutButNotThePresence() {
        let controller = makeController(settings: makeSettings())
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)
        XCTAssertEqual(controller.presence, .present)

        controller.isExternallyBusy = { true }
        for second in 1 ... 6 {
            step(controller, rssi: -95, at: TimeInterval(second))
        }
        XCTAssertEqual(controller.smoothedRSSI, -95, "读数该跟着最新五帧走")
        XCTAssertEqual(controller.presence, .present, "判定停摆期间不该翻状态")
        XCTAssertEqual(session.lockCalls, 0)
    }

    // MARK: - 设备候选表（偏好页用）

    /// 点「扫描设备」会构造信号源并开始扫描，但不武装判定 —— 一帧都不许导致锁屏。
    func testDiscoveryScansWithoutArming() {
        let controller = makeController(settings: makeSettings(enabled: false))
        controller.apply(currentSettings)
        XCTAssertEqual(sourceFactoryCalls, 0)

        controller.beginDiscovery()
        XCTAssertEqual(sourceFactoryCalls, 1)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(source.targetDeviceID)

        for second in 0 ... 60 {
            clock.time = TimeInterval(second)
            source.report(rssi: -95, at: TimeInterval(second), deviceID: "ANY")
            controller.tick(timestamp: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, 0)

        controller.endDiscovery()
        XCTAssertEqual(source.stopCount, 1)
    }

    /// 功能正在跑的时候关掉偏好页，不能把扫描一起停掉。
    func testEndDiscoveryKeepsScanningWhenArmed() {
        let controller = makeController(settings: makeSettings())
        controller.apply(currentSettings)
        controller.beginDiscovery()
        controller.endDiscovery()
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(source.stopCount, 0)
    }

    func testCandidateListIsPublished() {
        let controller = makeController(settings: makeSettings(enabled: false))
        controller.beginDiscovery()
        source.report(devices: [ProximityDevice(id: "A", name: "Apple Watch", rssi: -55, lastSeen: 0),
                                ProximityDevice(id: "B", name: "", rssi: -70, lastSeen: 0)])
        XCTAssertEqual(controller.devices.count, 2)
        XCTAssertEqual(controller.devices.first?.id, "A")
    }

    func testBluetoothStatusIsPublished() {
        let controller = makeController(settings: makeSettings())
        controller.apply(currentSettings)
        source.report(status: .unauthorized)
        XCTAssertEqual(controller.status, .unauthorized)
        source.report(status: .scanning)
        XCTAssertEqual(controller.status, .scanning)
    }

    // MARK: - 开关切换

    func testTurningTheFeatureOffStopsEverything() {
        let armed = makeSettings()
        let controller = makeController(settings: armed)
        controller.apply(currentSettings)
        driveToLock(controller)
        XCTAssertTrue(controller.isRunning)

        controller.apply(makeSettings(enabled: false))
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertNil(source.targetDeviceID)
        XCTAssertEqual(controller.presence, .unknown)

        // 停了之后再来帧也不该有任何动作。
        let calls = session.lockCalls
        for second in 300 ... 360 {
            step(controller, rssi: -95, at: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, calls)
    }

    /// 设置没变就别重启：重启会把 presence 打回 unknown，用户改个无关的偏好就得重新等一次。
    func testReapplyingIdenticalSettingsKeepsTheObservedPresence() {
        let controller = makeController(settings: makeSettings())
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)
        XCTAssertEqual(controller.presence, .present)
        XCTAssertEqual(source.startCount, 1)

        controller.apply(currentSettings)
        XCTAssertEqual(controller.presence, .present)
        XCTAssertEqual(source.startCount, 1, "设置没变时不该重启扫描")
    }

    /// 换了设备必须重新起算：旧设备的「present」对新设备没有任何意义。
    func testSwitchingDeviceResetsThePresence() {
        let controller = makeController(settings: makeSettings())
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)
        XCTAssertEqual(controller.presence, .present)

        controller.apply(makeSettings(deviceID: "OTHER-UUID"))
        XCTAssertEqual(controller.presence, .unknown)
        XCTAssertEqual(source.targetDeviceID, "OTHER-UUID")

        // 旧设备的帧不再算数。
        for second in 1 ... 30 {
            source.report(rssi: -50, at: TimeInterval(second), deviceID: "WATCH-UUID")
            clock.time = TimeInterval(second)
            controller.tick(timestamp: TimeInterval(second))
        }
        XCTAssertEqual(controller.presence, .unknown)
    }

    func testOnlyTargetDeviceSamplesAreIngested() {
        let controller = makeController(settings: makeSettings(lockDelay: 2))
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)
        // 别人家的设备再强也不算数。
        for second in 1 ... 20 {
            clock.time = TimeInterval(second)
            source.report(rssi: -40, at: TimeInterval(second), deviceID: "NEIGHBOUR")
            controller.tick(timestamp: TimeInterval(second))
        }
        // 目标设备一帧没来 → 信号超时后照样算走开。
        XCTAssertEqual(controller.presence, .present, "60 秒信号超时还没到")
        XCTAssertEqual(session.lockCalls, 0)
    }

    func testSignalTimeoutAloneTriggersTheLock() {
        let controller = makeController(settings: makeSettings(lockDelay: 3, signalTimeout: 30))
        controller.apply(currentSettings)
        step(controller, rssi: -50, at: 0)
        // 之后一帧都没有：手表没电 / 蓝牙断了 / 人直接走了。
        for second in 1 ... 32 {
            clock.time = TimeInterval(second)
            controller.tick(timestamp: TimeInterval(second))
        }
        XCTAssertEqual(session.lockCalls, 0, "还在信号超时窗口内")
        clock.time = 34
        controller.tick(timestamp: 34)
        XCTAssertEqual(session.lockCalls, 1, "超时 + 延时之后就该锁")
    }
}
