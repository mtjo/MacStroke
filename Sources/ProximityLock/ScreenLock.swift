//
//  ScreenLock.swift
//  MacStroke
//
//  锁屏与「锁屏状态」两件事。
//
//  macOS 没有公开的锁屏 API（NSWorkspace 里没有 lockScreen），能用的只有三条：
//   ① login.framework 的私有函数 `SACLockScreenImmediate`（dlsym 取），无需 TCC，
//      后台 LSUIElement 也能调，macOS 13～26 一直在（本机 dyld_info 实测有导出）；
//   ② 合成 ⌃⌘Q —— 只需要已有的辅助功能权限，但会被前台 App 抢走、被安全输入挡住、
//      被用户改键改掉，所以只当兜底；
//   ③ 起屏保 + 「立即要求密码」—— Ventura 起屏保安全层拦掉所有 CGEvent，走不通。
//

import AppKit
import CoreGraphics
import Darwin
import Foundation

public final class ScreenLock {
    public static let shared = ScreenLock()

    public typealias SessionReader = () -> [String: Any]?
    public typealias ProcessNameReader = (Int32) -> String?
    public typealias DisplayAsleepReader = () -> Bool

    private let readSession: SessionReader
    private let processName: ProcessNameReader
    private let lockNow: () -> Bool
    private let displayAsleep: DisplayAsleepReader
    private let log: (String) -> Void

    /// 分布式通知兜底：macOS 26 上 `CGSessionCopyCurrentDictionary` 里的
    /// `CGSSessionScreenIsLocked` 被报告已经移除（BLEUnlock PR #190），
    /// 那时唯一还能知道锁没锁的就是 loginwindow 广播的这两条通知。
    private var notificationLocked: Bool?
    private var observers: [NSObjectProtocol] = []
    /// 通知在主线程写，注入那条路在后台线程读（见 ProximityLockController.runInjection）。
    private let stateLock = NSLock()

    /// 三个 nil 参数各有真机默认值。不写成默认参数是因为默认值里引用不到 internal 静态方法。
    public init(sessionReader: SessionReader? = nil,
                processName: ProcessNameReader? = nil,
                lockNow: (() -> Bool)? = nil,
                displayAsleep: DisplayAsleepReader? = nil,
                log: ((String) -> Void)? = nil,
                observeNotifications: Bool = true) {
        self.readSession = sessionReader ?? { CGSessionCopyCurrentDictionary() as? [String: Any] }
        self.processName = processName ?? { ScreenLock.processName(of: $0) }
        self.lockNow = lockNow ?? { ScreenLock.callPrivateLock() }
        self.displayAsleep = displayAsleep ?? { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
        self.log = log ?? { NSLog("%@", "[ProximityLock] " + $0) }
        if observeNotifications { startObservingLockNotifications() }
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    // MARK: - 状态

    public var sessionDictionary: [String: Any]? { readSession() }

    public var isLocked: Bool {
        if let flag = sessionValue("CGSSessionScreenIsLocked") { return flag != 0 }
        stateLock.lock()
        defer { stateLock.unlock() }
        return notificationLocked ?? false
    }

    /// 占着安全输入的那个进程。锁屏时应该是 loginwindow。
    public var secureInputPID: Int32? {
        guard let raw = sessionValue("kCGSSessionSecureInputPID"), raw > 0 else { return nil }
        return Int32(raw)
    }

    /// 主屏是不是处于熄屏状态。本机 macOS 27 实测：锁屏后约 5 秒系统自己把屏关了，
    /// 而熄屏期间 `isAcceptingPassword` 依然为真，光靠它拦不住「打给黑屏」的注入 ——
    /// 那三轮按键没有一次解开锁（pmset -g log 的 Display is turned off/on 夹着注入时刻）。
    public var isDisplayAsleep: Bool { displayAsleep() }

    /// 锁屏密码框现在是不是真的在前台等输入。**只有这一条为真才允许注入密码**：
    /// 光是「锁着」还不够 —— 屏保还没退、或者别的安全输入进程占着字段时，
    /// 打进去的字符会落进当时有焦点的任意输入框（BLEUnlock issue #182 就是这么把密码
    /// 打进聊天窗的）。
    public var isAcceptingPassword: Bool {
        guard isLocked else { return false }
        guard let pid = secureInputPID else { return false }
        return processName(pid) == "loginwindow"
    }

    private func sessionValue(_ key: String) -> Int? {
        guard let value = readSession()?[key] else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let bool = value as? Bool { return bool ? 1 : 0 }
        return nil
    }

    private func startObservingLockNotifications() {
        let center = DistributedNotificationCenter.default()
        let names = ["com.apple.screenIsLocked": true, "com.apple.screenIsUnlocked": false]
        for (name, locked) in names {
            let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                self?.noteLockState(locked, source: name)
            }
            observers.append(token)
        }
    }

    /// 通知回调单独抽出来，是为了能离线测「会话字典里没有那个键时靠通知兜底」这条路 ——
    /// 单测里发不了真的分布式通知。
    func noteLockState(_ locked: Bool, source: String) {
        stateLock.lock()
        notificationLocked = locked
        stateLock.unlock()
        log("锁屏状态 ← \(source)：\(locked)")
    }

    // MARK: - 锁屏

    /// 已经锁着就不重复提交：一是没必要，二是 ⌃⌘Q 兜底那条路会把按键打进前台 App。
    @discardableResult
    public func lock() -> Bool {
        guard !isLocked else { return true }
        let ok = lockNow()
        log(ok ? "已提交锁屏" : "锁屏失败（私有接口返回非 0）")
        return ok
    }

    static func callPrivateLock() -> Bool {
        if let fn = privateLockFunction { return fn() == 0 }
        return sendLockKeystroke()
    }

    private typealias LockFunction = @convention(c) () -> Int32

    /// dlsym 只做一次，句柄故意不 dlclose：函数指针要活到进程结束。
    private static let privateLockFunction: LockFunction? = {
        let paths = [
            "/System/Library/PrivateFrameworks/login.framework/login",
            "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_NOW),
                  let symbol = dlsym(handle, "SACLockScreenImmediate") else { continue }
            return unsafeBitCast(symbol, to: LockFunction.self)
        }
        return nil
    }()

    /// 兜底：合成 ⌃⌘Q。发在 HID 层（比会话层更靠上，锁屏状态下也还能落地）。
    static func sendLockKeystroke() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let keycode: CGKeyCode = 0x0C // kVK_ANSI_Q
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: keyDown) else {
                return false
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    static func processName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
