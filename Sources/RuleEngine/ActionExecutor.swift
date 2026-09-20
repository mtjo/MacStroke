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
        case .none:
            break
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
        // Map common key names to key codes.
        let keyCode: UInt16? = keyCodeForName(key)
        guard let keyCode else {
            print("[ActionExecutor] Unknown key: \(key)")
            return
        }
        pressKey(keyCode: keyCode, flags: 0)
    }

    private func pressKey(keyCode: UInt16, flags: UInt) {
        let flagMask: CGEventFlags = CGEventFlags(rawValue: UInt64(flags))
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.flags = flagMask
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = flagMask
            up.post(tap: .cghidEventTap)
        }
    }

    private func clickMouse(x: Int, y: Int) {
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
        if let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            downEvent.post(tap: .cghidEventTap)
        }
        if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            upEvent.post(tap: .cghidEventTap)
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
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: length, unicodeString: &chars)
            up.post(tap: .cghidEventTap)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Map a key name to its ANSI virtual key code (HIToolbox/Events.h values).
    private func keyCodeForName(_ name: String) -> UInt16? {
        switch name.lowercased() {
        case "space": return 0x31
        case "return", "enter": return 0x24
        case "delete": return 0x33
        case "tab": return 0x30
        case "escape": return 0x35
        case "left", "leftarrow": return 0x7B
        case "right", "rightarrow": return 0x7C
        case "down", "downarrow": return 0x7D
        case "up", "uparrow": return 0x7E
        case "pageup", "pageupkey": return 0x74
        case "pagedown", "pagedownkey": return 0x79
        case "[", "leftbracket": return 0x21
        case "]", "rightbracket": return 0x1E
        case "a": return 0x00
        case "s": return 0x01
        case "d": return 0x02
        case "f": return 0x03
        case "h": return 0x04
        case "g": return 0x05
        case "z": return 0x06
        case "x": return 0x07
        case "c": return 0x08
        case "v": return 0x09
        case "b": return 0x0B
        case "q": return 0x0C
        case "w": return 0x0D
        case "e": return 0x0E
        case "r": return 0x0F
        case "y": return 0x10
        case "t": return 0x11
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19
        case "0": return 0x1D
        case "o": return 0x1F
        case "u": return 0x20
        case "i": return 0x22
        case "p": return 0x23
        case "l": return 0x25
        case "j": return 0x26
        case "k": return 0x28
        case "n": return 0x2D
        case "m": return 0x2E
        case ",": return 0x2B
        case ".": return 0x2F
        case "/": return 0x2C
        case ";": return 0x29
        case "'": return 0x27
        case "\\": return 0x2A
        case "-": return 0x1B
        case "=": return 0x18
        case "`": return 0x32
        default: return nil
        }
    }
}