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
//   · 解锁只在「屏幕锁着 + 安全输入属于 loginwindow」时注入密码。
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
    private var activity: NSObjectProtocol?
    private let screen: ScreenLock
    private let passwords: UnlockPasswordStoring
    /// 注入这一步抽成闭包而不是直接持有 PasswordInjector：单测要能确认「该注入时才注入、
    /// 不该注入时一个字都没打」，而真注入会往 HID 层发按键，测试里绝不能碰。
    private let inject: (String) -> PasswordInjector.Result
    private let now: () -> TimeInterval
    private let log: (String) -> Void

    public init(sourceFactory: @escaping () -> ProximitySignalSource = { BluetoothProximityScanner() },
                screen: ScreenLock = .shared,
                passwords: UnlockPasswordStoring? = nil,
                inject: ((String) -> PasswordInjector.Result)? = nil,
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
        self.inject = inject ?? { liveInjector.inject($0) }
    }

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
            break
        case .lock:
            performLock()
        case .unlock:
            performUnlock()
        }
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
        let result = inject(password)
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
