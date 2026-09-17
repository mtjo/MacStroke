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
        case .applescript(let script):
            Task { @MainActor in
                do {
                    _ = try appleScriptRunner.execute(script)
                } catch {
                    print("[ActionExecutor] AppleScript failed: \(error)")
                }
            }
        case .keyPress(let key):
            pressKey(key)
        case .mouseClick(let x, let y):
            clickMouse(x: x, y: y)
        case .copyToClipboard(let text):
            copyToClipboard(text)
        case .none:
            break
        }
    }

    private func pressKey(_ key: String) {
        // Map common key names to key codes.
        let keyCode: UInt16? = keyCodeForName(key)
        guard let keyCode else {
            print("[ActionExecutor] Unknown key: \(key)")
            return
        }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
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

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func keyCodeForName(_ name: String) -> UInt16? {
        switch name.lowercased() {
        case "space": return 0x31
        case "return", "enter": return 0x24
        case "delete": return 0x33
        case "tab": return 0x30
        case "escape": return 0x35
        case "left", "leftarrow": return 0x25
        case "right", "rightarrow": return 0x27
        case "up", "keyup": return 0x2E
        case "down", "keydown": return 0x28
        case "pageup", "pageupkey": return 0x21
        case "pagedown", "pagedownkey": return 0x22
        case "[", "leftbracket": return 0x2A
        case "]", "rightbracket": return 0x2D
        case "a": return 0x00
        case "b": return 0x01
        case "c": return 0x02
        case "d": return 0x03
        case "e": return 0x04
        case "f": return 0x05
        case "g": return 0x06
        case "h": return 0x07
        case "i": return 0x08
        case "j": return 0x09
        case "k": return 0x0B
        case "l": return 0x0C
        case "m": return 0x0D
        case "n": return 0x0E
        case "o": return 0x0F
        case "p": return 0x11
        case "q": return 0x12
        case "r": return 0x13
        case "s": return 0x14
        case "t": return 0x15
        case "u": return 0x16
        case "v": return 0x17
        case "w": return 0x18
        case "x": return 0x19
        case "y": return 0x1A
        case "z": return 0x1B
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x16
        case "6": return 0x17
        case "7": return 0x18
        case "8": return 0x19
        case "9": return 0x1A
        case "0": return 0x1D
        default: return nil
        }
    }
}