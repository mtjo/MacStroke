//
//  ProximityLockController.swift
//  MacStroke
//
//  把「信号 → 判定 → 锁屏/解锁」串起来的调度器。生命周期照 RemoteControlServer 的写法：
//  偏好页改完发 `.macStrokeProximityLockDidChange`，App 侧 `apply()` 一次。
//
//  几条硬约束（都是为了「不该锁的时候一次都别锁」）：
//   · 默认关，而且没选设备就等于没开；
//   · 冷启动状态是 unknown，**从 unknown 不会锁屏** —— 程序刚起来时手表不在旁边不算「走开」；
//   · 只在 present → absent 这个跳变上锁一次，之后不再重复提交；
//   · 挂起期（远程控制接管、录屏中）计时清零，恢复那一刻不会突然锁屏；
//   · 解锁只在「屏幕锁着 + 安全输入属于 loginwindow + 屏是亮的」时注入密码。
//

import AppKit
import Foundation
import Storage

public final class ProximityLockController: ObservableObject {
    public static let shared = ProximityLockController()

    /// 判定频率。1 秒足够：lockDelay 本身就是秒级，再密只是白烧 CPU。
    public let tickInterval: TimeInterval = 1

    /// 一次判定实际做了什么的枚举。界面上每一种都配一句话，日志里另有一份中文描述。
    public enum Outcome: Equatable {
        case locked
        case lockFailed
        case alreadyLocked
        /// 人回来了，但自动解锁没开 —— 这不是错误，只是要说清楚为什么没解。
        case returnedNoAutoUnlock
        case unlocked
        /// 锁屏密码框不在前台（锁着但安全输入不属于 loginwindow），一个字都没打。
        case fieldNotAcceptingPassword
        /// 人回来了，但屏幕是熄的。锁屏后约 5 秒系统就把屏关了，而判定只在「回来」那次跳变
        /// 上给一个 `.unlock`，错过就没了 —— 所以这里挂着账，等屏幕点亮再补注入。
        case waitingForDisplayWake
        /// 「等屏幕点亮补注入」这笔账销掉了，但屏幕不是我们解的 —— 他自己按键/Touch ID 解开了。
        /// 不报这一条的话，界面上会一直挂着「等亮起来再解锁」，而屏幕早就开了 ——
        /// 用户报过一次这个（2026-10-18 本机：08:14:40 挂账，08:14:46 他手解，文案没动）。
        case unlockCancelledByHand
        /// 等屏幕点亮这段时间人又走开了，这笔账取消。
        case unlockCancelledPersonLeft
        case noStoredPassword
        case storedPasswordEmpty
        /// 打到一半屏幕状态变了（解锁了 / 安全输入换了主人），当场中止。
        case injectionAborted
        case injectionFailed
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var isDiscovering = false
    @Published public private(set) var status: ProximitySignalStatus = .idle
    @Published public private(set) var presence: ProximityDecision.Presence = .unknown
    /// 滑动窗口均值（dBm），界面回显用。nil = 还没收到广播。
    @Published public private(set) var smoothedRSSI: Int?
    @Published public private(set) var devices: [ProximityDevice] = []
    /// 最近一次真做了什么事，界面上给用户一个交代（「已锁屏」/「密码框不在前台，未注入」）。
    /// 存枚举不存文案：文案要跟着偏好页的语言走（L()），而单测需要一个不会被
    /// 本地化改写的稳定判据 —— 让测试去比 L(key) 等于让被测对象自己出题自己判卷。
    @Published public private(set) var lastOutcome: Outcome?

    public private(set) var settings: ProximityLockSettings

    /// App 层挂进来的「这台机器正被人用着」判定，一秒问一次。为真时和挂起期一样：
    /// 走开计时清零，不锁屏。远程控制接管、截图遮罩摊开这类场合用它 —— 手表就在桌上
    /// 信号不稳的时候锁屏，会把正在进行的这场操作打断。
    /// 抽成闭包而不是让本模块去 import RemoteControl/Screenshot：判定状态机不该知道
    /// 谁在忙，单测也才能离线把这条分支拉直。
    public var isExternallyBusy: (() -> Bool)?

    private let sourceFactory: () -> ProximitySignalSource
    private var source: ProximitySignalSource?
    private var decision: ProximityDecision?
    private var timer: Timer?
    private var pauseUntil: TimeInterval = 0
    /// 「人回来了但屏是熄的」这笔欠账。每次唤醒只补一轮注入：解不开就是解不开，
    /// 不该一秒重打一遍密码。
    private var unlockWaitingForDisplayWake = false
    private var activity: NSObjectProtocol?
    private let screen: ScreenLock
    private let passwords: UnlockPasswordStoring
    /// 注入这一步抽成闭包而不是直接持有 PasswordInjector：单测要能确认「该注入时才注入、
    /// 不该注入时一个字都没打」，而真注入会往 HID 层发按键，测试里绝不能碰。
    ///
    /// 形态是「派活 + 回调结果」而不是「同步返回结果」，这点是被真机逼出来的：
    /// `tick()` 挂在 `RunLoop.main` 上，同步打密码最长要占住主线程 3.6 秒
    /// （`unlockTimeout` × `maxAttempts`）。那期间 `com.apple.screenIsUnlocked` 发不进来，
    /// 而 macOS 27 上解开的瞬间会话字典里那个键就没了 —— `isLocked` 只能回落到达通知缓存，
    /// 于是「等它解开」永远等不到，一次**成功**的注入也会被读成失败，接着往正打开的桌面里
    /// 再打一遍。所以注入必须在别的线程上跑，让主线程把通知收进来。
    private let runInjection: (_ password: String,
                               _ completion: @escaping (PasswordInjector.Result) -> Void) -> Void
    private let now: () -> TimeInterval
    private let log: (String) -> Void

    public init(sourceFactory: @escaping () -> ProximitySignalSource = { BluetoothProximityScanner() },
                screen: ScreenLock = .shared,
                passwords: UnlockPasswordStoring? = nil,
                runInjection: ((String, @escaping (PasswordInjector.Result) -> Void) -> Void)? = nil,
                settings: ProximityLockSettings? = nil,
                now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
                log: @escaping (String) -> Void = { NSLog("%@", "[ProximityLock] " + $0) }) {
        self.sourceFactory = sourceFactory
        self.screen = screen
        self.now = now
        self.log = log
        self.settings = settings ?? ProximityLockSettings.current()
        let store = passwords ?? KeychainPasswordStore()
        self.passwords = store
        let liveInjector = PasswordInjector(screen: screen)
        self.runInjection = runInjection ?? { password, completion in
            ProximityLockController.injectionQueue.async {
                let result = liveInjector.inject(password)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// 串行：两轮密码同时往 HID 层喷是绝不能发生的。
    private static let injectionQueue = DispatchQueue(label: "net.mtjo.MacStroke.proximity.unlock",
                                                      qos: .userInitiated)

    public var isPaused: Bool { now() < pauseUntil }

    // MARK: - 生命周期

    @discardableResult
    public func apply(_ newSettings: ProximityLockSettings? = nil) -> ProximityLockSettings {
        let next = newSettings ?? .current()
        let previous = settings
        settings = next

        guard next.isArmed else {
            stop()
            return next
        }
        // 设置没变就别重启：重启会把 presence 打回 unknown，用户改个无关的偏好就得重新等一次。
        if isRunning, next == previous { return next }
        start(with: next)
        return next
    }

    private func start(with settings: ProximityLockSettings) {
        ensureSource()
        source?.targetDeviceID = settings.deviceID
        decision = ProximityDecision(unlockRSSI: settings.unlockRSSI,
                                     lockRSSI: settings.lockRSSI,
                                     lockDelay: settings.lockDelay,
                                     signalTimeout: settings.signalTimeout)
        presence = .unknown
        smoothedRSSI = nil
        unlockWaitingForDisplayWake = false
        source?.start()
        isRunning = true
        beginActivity()
        startTimer()
        log("已启动：盯「\(settings.deviceName.isEmpty ? settings.deviceID : settings.deviceName)」"
            + " 回来≥\(settings.unlockRSSI)dBm 走开≤\(settings.lockRSSI)dBm"
            + " 延时\(Int(settings.lockDelay))s 信号超时\(Int(settings.signalTimeout))s"
            + " 自动解锁=\(settings.autoUnlock ? "开" : "关")")
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        endActivity()
        decision = nil
        isRunning = false
        presence = .unknown
        smoothedRSSI = nil
        unlockWaitingForDisplayWake = false
        if !isDiscovering {
            source?.targetDeviceID = nil
            source?.stop()
        }
    }

    /// 偏好页点「扫描设备」时调用：只列候选，不武装判定。
    /// 第一次调用会构造 CBCentralManager，也就是**系统蓝牙授权框在这时候弹**。
    public func beginDiscovery() {
        ensureSource()
        if !isRunning { source?.targetDeviceID = nil }
        isDiscovering = true
        source?.start()
    }

    public func endDiscovery() {
        isDiscovering = false
        guard !isRunning else { return }
        source?.stop()
        devices = []
    }

    /// 挂起一段时间：远程控制接管、录屏、长截图这类「人不在旁边但机器正在干活」的场合。
    /// 走开计时会被清零，所以恢复的那一刻不会突然锁屏。
    public func pause(for seconds: TimeInterval, reason: String) {
        let until = now() + max(0, seconds)
        guard until > pauseUntil else { return }
        pauseUntil = until
        log("挂起 \(Int(seconds)) 秒（\(reason)）")
    }

    private func ensureSource() {
        guard source == nil else { return }
        let made = sourceFactory()
        made.onSample = { [weak self] sample in self?.handle(sample: sample) }
        made.onDevices = { [weak self] list in self?.devices = list }
        made.onStatusChange = { [weak self] status in self?.status = status }
        source = made
    }

    private func beginActivity() {
        guard activity == nil else { return }
        // 不拦住 App Nap 的话，1 秒的定时器会被节流到几十秒一次，锁屏就会迟到很久。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "蓝牙靠近锁屏需要按秒判定信号")
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common：偏好窗口开着（modal panel tracking mode）时定时器也要照跑。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - 判定

    private func handle(sample: ProximitySample) {
        guard isRunning, sample.deviceID == settings.deviceID else { return }
        decision?.ingest(rssi: sample.rssi, at: sample.time)
    }

    /// 一秒一次。`timestamp` 可以手工给 —— 单测靠它把整条时间线拉直，不用真等一分钟。
    public func tick(timestamp: TimeInterval? = nil) {
        guard isRunning, var decision else { return }
        let time = timestamp ?? now()
        if time < pauseUntil || isExternallyBusy?() == true {
            decision.cancelPendingLock()
            self.decision = decision
            // 判定停摆但 dBm 读数照旧刷新（窗口在 ingest 时就更新了）：界面不该冻住，
            // 否则用户以为扫描断了。presence 故意不跟着变 —— 走开的那次跳变必须留给
            // 不忙之后的 tick 去做，否则 .lock 这个动作会被白吃掉一次，人就再也锁不上了。
            smoothedRSSI = decision.smoothedRSSI.map { Int($0.rounded()) }
            return
        }
        let action = decision.tick(now: time, screenLocked: screen.isLocked)
        self.decision = decision
        presence = decision.presence
        smoothedRSSI = decision.smoothedRSSI.map { Int($0.rounded()) }
        switch action {
        case .none:
            retryUnlockWhenDisplayWakes()
        case .lock:
            performLock()
        case .unlock:
            performUnlock()
        }
    }

    /// 熄屏那次没打成的解锁，屏幕一亮就补上。
    /// 挂在 `.none` 分支而不是另起定时器：一秒一次的判定已经够用。
    private func retryUnlockWhenDisplayWakes() {
        guard unlockWaitingForDisplayWake else { return }
        guard screen.isLocked else {
            // 他自己按键盘解开了（或别的途径解的），这笔账自然销掉 ——
            // 但界面那句话必须跟着改口，不然它一直在说「等亮起来再解锁」，而屏幕早就开了。
            unlockWaitingForDisplayWake = false
            report(.unlockCancelledByHand, "屏幕已经解开，补注入取消")
            return
        }
        guard presence == .present else {
            unlockWaitingForDisplayWake = false
            report(.unlockCancelledPersonLeft, "等屏幕点亮这段时间人又走开了，取消补注入")
            return
        }
        guard !screen.isDisplayAsleep else { return }
        unlockWaitingForDisplayWake = false
        log("屏幕已点亮，补那一次没打成的解锁")
        performUnlock()
    }

    private func performLock() {
        guard !screen.isLocked else {
            report(.alreadyLocked, "屏幕已经锁着")
            return
        }
        let ok = screen.lock()
        report(ok ? .locked : .lockFailed, ok ? "人已走开，屏幕已锁" : "锁屏失败")
    }

    private func report(_ outcome: Outcome, _ description: String) {
        lastOutcome = outcome
        log(description)
    }

    private func performUnlock() {
        guard settings.autoUnlock else {
            report(.returnedNoAutoUnlock, "人已回来（未开自动解锁）")
            return
        }
        // 熄屏时注入是白打（见 ScreenLock.isDisplayAsleep），而 `.unlock` 只在回来那次跳变上
        // 给一次，错过就没了 —— 所以欠一笔，等亮起来补。
        guard !screen.isDisplayAsleep else {
            unlockWaitingForDisplayWake = true
            report(.waitingForDisplayWake, "人已回来，但屏幕是熄的，等亮起来再补注入")
            return
        }
        // 两道门都过了才允许打字。isAcceptingPassword = 锁着 + 安全输入进程是 loginwindow。
        guard screen.isAcceptingPassword else {
            report(.fieldNotAcceptingPassword, "锁屏密码框不在前台，未注入密码")
            log("（锁屏=\(screen.isLocked)"
                + " 安全输入=\(screen.secureInputPID.map { String($0) } ?? "无")）")
            return
        }
        let stored = passwords.readPassword()
        guard let password = stored, !password.isEmpty else {
            report(stored == nil ? .noStoredPassword : .storedPasswordEmpty,
                   stored == nil ? "钥匙串里没有登录密码" : "存的密码是空的")
            return
        }
        // 串行队列 + PasswordInjector 每轮开头的入口守卫，保证「就算排了两轮，
        // 屏幕已经解开的那一轮一个字都不会打进桌面」，所以这里不再另设在途标志。
        runInjection(password) { [weak self] result in
            guard let self, self.isRunning else { return }
            self.reportInjection(result)
        }
    }

    private func reportInjection(_ result: PasswordInjector.Result) {
        switch result {
        case .submitted:
            report(.unlocked, "已自动解锁")
        case .abortedGuardTripped:
            report(.injectionAborted, "注入中途屏幕状态变了，已中止")
        case .exhaustedAttempts:
            report(.injectionFailed, "解锁失败（密码不对或密码框没接受输入）")
        case .emptyPassword:
            report(.storedPasswordEmpty, "存的密码是空的")
        case .notAcceptingPassword:
            report(.fieldNotAcceptingPassword, "密码框不在前台，未注入密码")
        }
        // 只记结果，绝不记内容或长度。
        log("注入结果：\(result)")
    }
}
