//
//  ShortcutMonitor.swift
//  MacStroke
//
//  Global shortcut monitoring using CGEvent tap.
//  Monitors for a specific keyboard shortcut and invokes a callback when matched.
//

import Foundation
import AppKit

/// Monitors for a global keyboard shortcut using CGEvent tap.
public final class ShortcutMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitoring = false

    /// Whether the monitor is currently active.
    public var isMonitoring: Bool { monitoring }

    /// The key code to match (0 = match any)
    public var keyCode: UInt16 = 0

    /// The modifier flags to match (0 = match any)
    public var flags: UInt = 0

    /// Callback when the shortcut is detected
    public var onShortcutDetected: (() -> Void)?

    public init() {}

    deinit {
        stop()
    }

    /// Start monitoring for the shortcut.
    /// - Returns: true if started successfully
    @discardableResult
    public func start() -> Bool {
        guard !monitoring else { return true }
        guard keyCode != 0 || flags != 0 else {
            NSLog("%@", "[ShortcutMonitor] No shortcut configured")
            return false
        }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let selfPtr = Unmanaged<ShortcutMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return selfPtr.handleEvent(type: type, event: event)
        }

        // Create event tap for key down events only
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            NSLog("%@", "[ShortcutMonitor] Failed to create event tap")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        monitoring = true
        NSLog("%@", "[ShortcutMonitor] Started monitoring keyCode=\(keyCode) flags=\(flags)")
        return true
    }

    /// Stop monitoring.
    public func stop() {
        guard monitoring else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        monitoring = false
        NSLog("%@", "[ShortcutMonitor] Stopped")
    }

    /// Update the shortcut to monitor.
    /// - Parameters:
    ///   - keyCode: The key code to match
    ///   - flags: The modifier flags to match
    public func setShortcut(keyCode: UInt16, flags: UInt) {
        let wasMonitoring = monitoring
        if wasMonitoring { stop() }
        self.keyCode = keyCode
        self.flags = flags
        if wasMonitoring { _ = start() }
    }

    /// Parse shortcut string "keyCode=X, flags=Y" into keyCode and flags.
    /// - Parameter shortcutString: String in format "keyCode=123, flags=456"
    /// - Returns: Tuple of (keyCode, flags) or nil if invalid
    public static func parseShortcut(_ shortcutString: String) -> (UInt16, UInt)? {
        let cleaned = shortcutString.trimmingCharacters(in: .whitespaces)
        let pattern = #"keyCode=(\d+),\s*flags=(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let keyCodeRange = Range(match.range(at: 1), in: cleaned),
              let flagsRange = Range(match.range(at: 2), in: cleaned),
              let keyCodeInt = Int(String(cleaned[keyCodeRange])),
              let flagsInt = Int(String(cleaned[flagsRange]))
        else { return nil }
        return (UInt16(keyCodeInt), UInt(flagsInt))
    }

    /// Standard keyboard modifier bits (shift/control/option/command), used to
    /// compare flags while ignoring device-dependent low bits.
    private static let modifierMask: UInt = 0x1E_0000

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap after timeouts / user action; without
        // re-arming it the shortcut silently stops working. On these
        // notifications the `event` argument is a synthetic pseudo-event that
        // must not be returned — releasing it at the end of the runloop callout
        // over-releases and crashes. Return NULL, like the original.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            NSLog("%@", "[ShortcutMonitor] Tap disabled by system, re-armed")
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = UInt(event.flags.rawValue)

        // Check if key code matches (if keyCode is set)
        if keyCode != 0 && eventKeyCode != keyCode {
            return Unmanaged.passRetained(event)
        }

        // Check if modifier flags match, ignoring device-dependent bits
        if (eventFlags & Self.modifierMask) != (flags & Self.modifierMask) {
            return Unmanaged.passRetained(event)
        }

        // Shortcut matched!
        NSLog("%@", "[ShortcutMonitor] Matched keyCode=\(eventKeyCode) flags=\(eventFlags)")
        DispatchQueue.main.async { [weak self] in
            self?.onShortcutDetected?()
        }

        // Allow the event to propagate normally (don't consume it)
        return Unmanaged.passRetained(event)
    }
}