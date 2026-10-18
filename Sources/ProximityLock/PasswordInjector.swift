//
//  PasswordInjector.swift
//  MacStroke
//
//  把存好的登录密码打进锁屏密码框。这是「自动解锁」唯一的实现路径 ——
//  macOS 没有任何免密解锁接口（连 Apple Watch 的原生自动解锁也要求 Apple Silicon 或 T2）。
//
//  安全约束（比 BLEUnlock 严格，因为它踩过坑）：
//   · 每一块字符之前都重新确认「屏幕还锁着」且「安全输入进程是 loginwindow」，
//     一旦翻脸立刻整轮中止。BLEUnlock 只在打字前 0.5 秒查一次，中途解锁/切用户就会
//     把密码打进当时有焦点的任意输入框（issue #182）。
//   · 最多试 maxAttempts 轮，试不出来就停手，不无限重试。
//   · 事件一律发在 HID 层。会话层（.cgSessionEventTap）在锁屏状态下会被丢掉 ——
//     这是本仓库录屏那条线实测过的（当时日志里 CGSSessionScreenIsLocked=1、
//     secure input 属于 loginwindow，注入的 keyDown 一个都没落地）。
//

import CoreGraphics
import Foundation

public final class PasswordInjector {
    public enum Result: Equatable {
        /// 密码打完并回车，且屏幕确实解开了。
        case submitted
        /// 中途守卫翻脸（屏幕已解、或安全输入换人了）→ 立刻停手，绝不把剩下的字符打出去。
        case abortedGuardTripped
        /// 试满轮数仍未解锁（密码错、或者锁屏根本没在等输入）。
        case exhaustedAttempts
        case emptyPassword
        /// 一开始就不满足注入条件（没锁屏 / 密码框不在前台），一个字都没打。
        case notAcceptingPassword
    }

    /// 一个 CGEvent 最多带多少字符。20 是 BLEUnlock 实测的上限，超了会被截断。
    public let chunkSize: Int
    /// 试几轮。
    public let maxAttempts: Int
    /// 提交用的键：`kVK_Return = 0x24`。
    /// 这个数是本机真机钉下来的，不是猜的 —— 2026-10-18 16:52:48 那一次「人已回来 → 屏已点亮 →
    /// 补注入」的日志写着「第 1 轮解锁成功（提交键 0x24）」。在此之前一轮试过 0x24、
    /// 一轮试过 BLEUnlock 那个 HIToolbox 里查不到名字的 52（`0x34`）、一轮试过小键盘 Enter
    /// （`0x4C`），赢的是第一个，也就是最普通那个 Return。
    public let submitKeyCode: CGKeyCode
    /// 每轮开打前先把密码框清干净要按几下退格。上一轮留在框里的字符会把这一轮的密码接歪，
    /// 那样连「提交键对了」也照样解不开。真机成功那一发是带着清框跑的，所以这条留着。
    /// 40 是拍的：比常见密码长得多，而空框里按退格什么都不做。日志只记轮数不记这个数，
    /// 所以它不会泄露密码有几个字符。
    public let clearFieldBackspaces: Int
    /// 清框用的键：`kVK_Delete = 0x33`。
    public let deleteKeyCode: CGKeyCode = 0x33
    /// 屏保把登录面板挡住时用来唤出它。
    public let escapeKeyCode: CGKeyCode = 0x35
    /// 提交之后多久算「这一轮解开了」：轮询的步长与上限。
    ///
    /// 为什么要轮询而不是发完回车读一次：macOS 27 上解开锁的那一瞬间，会话字典里
    /// `CGSSessionScreenIsLocked` 这个键**直接消失**（本机实测：没锁的时候字典里压根没这个键），
    /// 于是 `ScreenLock.isLocked` 只能回落到达通知缓存 —— 而通知要等主线程空出来才送得进来。
    /// 读早了会把「已经解开」误判成「这一轮没解」，接着开第二轮，
    /// 那一轮会往正在打开的桌面里再打一遍密码。
    ///
    /// 前提：注入必须跑在非主线程（见 ProximityLockController.runInjection）。
    /// 挂在主线程上轮询是白轮 —— 我们等的那条通知正是因为主线程被占住才到不了。
    /// 「轮询窗口要多大」这台机器上还没有实测数（1.2 秒是拍的），下一轮真机要把它钉下来。
    public let unlockPollInterval: TimeInterval
    public let unlockTimeout: TimeInterval

    private let screen: ScreenLock
    private let poster: (CGEvent) -> Void
    private let sleeper: (TimeInterval) -> Void
    private let log: (String) -> Void

    public init(screen: ScreenLock = .shared,
                chunkSize: Int = 20,
                maxAttempts: Int = 3,
                submitKeyCode: CGKeyCode = 0x24,
                clearFieldBackspaces: Int = 40,
                settleDelay: TimeInterval = 0.4,
                unlockPollInterval: TimeInterval = 0.1,
                unlockTimeout: TimeInterval = 1.2,
                poster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
                sleeper: @escaping (TimeInterval) -> Void = { if $0 > 0 { usleep(UInt32($0 * 1_000_000)) } },
                log: @escaping (String) -> Void = { NSLog("%@", "[ProximityLock] " + $0) }) {
        self.screen = screen
        self.chunkSize = max(1, chunkSize)
        self.maxAttempts = max(1, maxAttempts)
        self.submitKeyCode = submitKeyCode
        self.clearFieldBackspaces = max(0, clearFieldBackspaces)
        self.settleDelay = settleDelay
        self.unlockPollInterval = max(0.01, unlockPollInterval)
        self.unlockTimeout = max(unlockPollInterval, unlockTimeout)
        self.poster = poster
        self.sleeper = sleeper
        self.log = log
    }

    private let settleDelay: TimeInterval

    /// 打一次密码。返回 `.submitted` 才代表屏幕真的解开了。
    @discardableResult
    public func inject(_ password: String) -> Result {
        guard !password.isEmpty else { return .emptyPassword }

        // 屏保状态：先发一个 Esc 把登录面板叫出来（BLEUnlock 也是这么做的）。
        // 只在「锁着但没人占安全输入」时发 —— 安全输入属于别的进程时（终端的 ssh 提示、
        // 密码管理器），焦点在人家那儿，一个按键都不该发。
        if !screen.isAcceptingPassword {
            guard screen.isLocked else {
                log("屏幕没锁，跳过注入")
                return .notAcceptingPassword
            }
            guard screen.secureInputPID == nil else {
                log("安全输入属于 pid \(screen.secureInputPID.map { String($0) } ?? "?") 而不是登录窗，一个字都不发")
                return .notAcceptingPassword
            }
            log("锁着但密码框没在前台，先发 Esc 唤出登录面板")
            postKey(escapeKeyCode)
            sleeper(settleDelay)
            guard screen.isAcceptingPassword else {
                log("Esc 之后仍然不在等输入，一个字都没打")
                return .notAcceptingPassword
            }
        }

        for attempt in 1 ... maxAttempts {
            guard screen.isAcceptingPassword else {
                log("第 \(attempt) 轮开始前守卫已翻脸，中止")
                return attempt == 1 ? .notAcceptingPassword : .abortedGuardTripped
            }
            clearField()
            guard typePassword(password) else {
                log("第 \(attempt) 轮打到一半守卫翻脸，中止")
                return .abortedGuardTripped
            }
            postKey(submitKeyCode)
            if waitUntilUnlocked() {
                log("第 \(attempt) 轮解锁成功")
                return .submitted
            }
            log("第 \(attempt) 轮之后屏幕仍锁着")
        }
        return .exhaustedAttempts
    }

    /// 把上一轮可能留在密码框里的字符退干净。每一下都重新确认守卫：
    /// 中途屏幕解开的话，剩下的退格绝不能喷进刚打开的桌面。
    private func clearField() {
        for _ in 0 ..< clearFieldBackspaces {
            guard screen.isAcceptingPassword else { return }
            postKey(deleteKeyCode)
        }
    }

    /// 提交之后等屏幕真的解开：轮询到 `unlockTimeout` 为止。
    /// 步进按算术累加而不是真实时钟，所以 `sleeper` 换成假的那条路（单测）也能自己走完。
    private func waitUntilUnlocked() -> Bool {
        var waited: TimeInterval = 0
        while waited < unlockTimeout {
            sleeper(unlockPollInterval)
            waited += unlockPollInterval
            if !screen.isLocked { return true }
        }
        return false
    }

    /// 逐块打字符。任何一块之前守卫翻脸就返回 false，剩下的字符一个都不发。
    private func typePassword(_ password: String) -> Bool {
        let units = Array(password.utf16)
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        var index = units.startIndex
        while index < units.endIndex {
            guard screen.isAcceptingPassword else { return false }
            let end = units.index(index, offsetBy: chunkSize, limitedBy: units.endIndex) ?? units.endIndex
            let chunk = Array(units[index..<end])
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false) else { return false }
            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count,
                                                 unicodeString: UnsafeMutablePointer(mutating: buffer.baseAddress))
            }
            poster(keyDown)
            poster(keyUp)
            index = end
        }
        return true
    }

    private func postKey(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return }
            poster(event)
        }
    }
}
