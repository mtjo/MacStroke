//
//  AppleScriptRunner.swift
//  MacStroke
//
//  Executes AppleScript commands and manages preset gestures.
//

import Foundation
import AppKit
import ScriptingBridge

/// Errors from AppleScript execution.
public enum AppleScriptError: Error {
    case scriptNotFound(String)
    case executionFailed(String)
    case invalidScript(String)
}

extension AppleScriptError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .scriptNotFound(let name): return "AppleScript not found: \(name)"
        case .executionFailed(let message): return message
        case .invalidScript: return "Invalid AppleScript"
        }
    }
}

/// Executes AppleScript commands.
public final class AppleScriptRunner {
    public init() {}

    /// Execute an AppleScript string synchronously
    /// (original: `NSAppleScript executeAndReturnError:`).
    /// - Parameter script: The AppleScript to run
    /// - Returns: The script's output string, or nil if no output
    /// - Throws: AppleScriptError if execution fails
    public func execute(_ script: String) throws -> String? {
        guard let appleScript = NSAppleScript(source: script) else {
            throw AppleScriptError.invalidScript(script)
        }
        var errorInfo: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? errorInfo.description
            throw AppleScriptError.executionFailed(message)
        }
        return descriptor.stringValue
    }

    /// Execute a preset gesture action by name.
    /// - Parameter name: The preset name (e.g., "close-window", "minimize")
    /// - Returns: Whether the action was executed successfully
    public func executePreset(_ name: String) -> Bool {
        let script: String
        switch name {
        case "close-window": script = "tell application \"System Events\" to keystroke \"w\" using {command down}"
        case "minimize": script = "tell application \"System Events\" to keystroke \"m\" using {command down}"
        case "hide-app": script = "tell application \"System Events\" to keystroke \"h\" using {command down}"
        case "launch-safari": script = "tell application \"Safari\" to activate"
        case "launch-chrome": script = "tell application \"Google Chrome\" to activate"
        case "launch-terminal": script = "tell application \"Terminal\" to activate"
        default: return false
        }
        do {
            _ = try execute(script)
            return true
        } catch {
            return false
        }
    }

    /// Get available preset names.
    public static var availablePresets: [String] {
        [
            "close-window", "minimize", "hide-app",
            "launch-safari", "launch-chrome", "launch-terminal"
        ]
    }
}