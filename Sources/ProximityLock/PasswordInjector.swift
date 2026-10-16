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
    /// 试几轮。第一轮可能是屏保还没退出、或显示器刚唤醒还没把密码框画出来。
    public let maxAttempts: Int
    /// 提交用的键。`kVK_Return = 0x24`；BLEUnlock 那边写的是 52，
    /// 而 52 在 HIToolbox 里并不是 Return（kVK_Delete=0x33、kVK_Escape=0x35，中间那格没定义），
    /// 所以这里用 36，真机上如果「密码进去了但不提交」再拿 52 做对照实验。
    public let submitKeyCode: CGKeyCode
    /// 屏保把登录面板挡住时用来唤出它。
    public let escapeKeyCode: CGKeyCode = 0x35

    private let screen: ScreenLock
    private let poster: (CGEvent) -> Void
    private let sleeper: (TimeInterval) -> Void
    private let log: (String) -> Void

    public init(screen: ScreenLock = .shared,
                chunkSize: Int = 20,
                maxAttempts: Int = 3,
                submitKeyCode: CGKeyCode = 0x24,
                settleDelay: TimeInterval = 0.4,
                poster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
                sleeper: @escaping (TimeInterval) -> Void = { if $0 > 0 { usleep(UInt32($0 * 1_000_000)) } },
                log: @escaping (String) -> Void = { NSLog("%@", "[ProximityLock] " + $0) }) {
        self.screen = screen
        self.chunkSize = max(1, chunkSize)
        self.maxAttempts = max(1, maxAttempts)
        self.submitKeyCode = submitKeyCode
        self.settleDelay = settleDelay
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
            guard typePassword(password) else {
                log("第 \(attempt) 轮打到一半守卫翻脸，中止")
                return .abortedGuardTripped
            }
            postKey(submitKeyCode)
            sleeper(settleDelay)
            if !screen.isLocked {
                log("第 \(attempt) 轮解锁成功")
                return .submitted
            }
            log("第 \(attempt) 轮之后屏幕仍锁着")
        }
        return .exhaustedAttempts
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
