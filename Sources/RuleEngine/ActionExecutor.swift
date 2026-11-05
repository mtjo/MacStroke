//
//  ActionExecutor.swift
//  MacStroke
//
//  Executes actions from matched rules (AppleScript, key press, mouse click, clipboard).
//

import Foundation
import AppKit
import GestureEngine
import AppleScriptRunner

/// Executes rule actions.
public final class ActionExecutor {
    private let appleScriptRunner: AppleScriptRunner

    /// 截图动作的执行入口，由 App 层挂上（Screenshot 模块在这一层之上，
    /// RuleEngine 自己够不到）。没挂上时保持沉默，不假装执行成功。
    public var onScreenshotRequested: (() -> Void)?

    /// 音量动作的执行接缝。默认 `SystemVolume.step(by:)`；桩件换成计数器就能钉住
    /// 「+1 档传正数、−1 档传负数、档位大小与滚轮页同一格」。
    public var volumeStepper: ((Double) -> Bool)?

    public init(appleScriptRunner: AppleScriptRunner = AppleScriptRunner()) {
        self.appleScriptRunner = appleScriptRunner
    }

    /// Execute the given action.
    /// - Parameters:
    ///   - action: The action to execute
    ///   - rule: The rule that triggered the action (for logging)
    public func execute(_ action: RuleAction, for rule: Rule? = nil) {
        switch action {
        case .applescript(let reference):
            // Original: rules reference a stored script by id (apple_script_id);
            // fall back to treating the value as inline source. Execution is
            // synchronous and errors surface as a system notification.
            let source = Self.resolveAppleScriptSource(reference)
            do {
                _ = try appleScriptRunner.execute(source)
            } catch {
                postAppleScriptErrorNotification(message: error.localizedDescription)
            }
        case .keyPress(let key):
            pressKey(key)
        case .mouseClick(let x, let y):
            clickMouse(x: x, y: y)
        case .copyToClipboard(let text):
            copyToClipboard(text)
        case .shortcut(let keyCode, let flags):
            pressKey(keyCode: keyCode, flags: flags)
        case .text(let text):
            typeText(text)
        case .password(let password):
            typeText(password)
        case .screenshot:
            onScreenshotRequested?()
        case .volumeUp:
            stepVolume(SystemVolume.volumeStep)
        case .volumeDown:
            stepVolume(-SystemVolume.volumeStep)
        case .none:
            break
        }
    }

    /// 档位大小只认 `SystemVolume.volumeStep` 这一个数（3.2.3 及以前滚轮音量档也是它）。
    /// 读不到默认输出设备（没插扬声器）时留一行日志，动作本身是 fire-and-forget，
    /// 没有「交回事件」这条退路可走。
    private func stepVolume(_ delta: Double) {
        let didStep = volumeStepper?(delta) ?? SystemVolume.step(by: delta)
        if !didStep {
            NSLog("%@", "[ActionExecutor] 音量 \(delta > 0 ? "+" : "")\(delta) 没落地（没有默认输出设备？）")
        }
    }

    /// Resolve a rule's AppleScript reference: a stored script id
    /// (original `apple_script_id`) wins; anything else is inline source.
    public static func resolveAppleScriptSource(_ reference: String) -> String {
        if let uuid = UUID(uuidString: reference),
           let item = AppleScriptsList.sharedAppleScriptsList.getScriptById(id: uuid) {
            return item.source
        }
        return reference
    }

    /// Original: NSUserNotification "MacStroke AppleScript Error" on failure.
    private func postAppleScriptErrorNotification(message: String) {
        let notification = NSUserNotification()
        notification.title = "MacStroke AppleScript Error"
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func pressKey(_ key: String) {
        // 名→键码用 GestureEngine 那一份共享表（手填快捷键框用的是同一张）。
        let keyCode: UInt16? = KeyboardKeys.keyCode(for: key)
        guard let keyCode else {
            NSLog("%@", "[ActionExecutor] Unknown key: \(key)")
            return
        }
        pressKey(keyCode: keyCode, flags: 0)
    }

    // 注入一律走 session 层（原版 RulesList.m:203/436 也是 kCGSessionEventTap）。
    // 若投到 .cghidEventTap，事件要先穿过我们自己那只 head-insert HID tap，而回调此刻还
    // 没返回（后面仍有读偏好与提示气泡）—— 实测回调多忙 120ms，动作就晚 120ms 落地。
    private func pressKey(keyCode: UInt16, flags: UInt) {
        let flagMask: CGEventFlags = CGEventFlags(rawValue: UInt64(flags))
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.flags = flagMask
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = flagMask
            up.post(tap: .cgSessionEventTap)
        }
    }

    private func clickMouse(x: Int, y: Int) {
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
        if let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            downEvent.post(tap: .cgSessionEventTap)
        }
        if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            upEvent.post(tap: .cgSessionEventTap)
        }
    }

    /// Type the given text by posting a unicode keyboard event, mirroring the
    /// original's `typeSting()` (RulesList.m) — works in any focused text field.
    private func typeText(_ text: String) {
        var chars = Array(text.utf16)
        guard !chars.isEmpty else { return }
        let length = chars.count

        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: length, unicodeString: &chars)
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: length, unicodeString: &chars)
            up.post(tap: .cgSessionEventTap)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}