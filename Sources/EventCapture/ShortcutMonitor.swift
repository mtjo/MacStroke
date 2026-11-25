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
    private var healthTimer: Timer?
    private var monitoring = false

    /// Whether the monitor is currently active.
    public var isMonitoring: Bool { monitoring }

    /// The key code to match, or nil to match any key (a modifiers-only
    /// shortcut). 0 is a real key code — ⌘⇧A is `keyCode=0` — so it cannot
    /// double as the «unspecified» sentinel.
    public var keyCode: UInt16?

    /// The modifier flags to match (0 = match any)
    public var flags: UInt = 0

    /// Drop the matched key press instead of letting it reach the frontmost app.
    /// Off for the clipboard shortcut, which the original lets through; a
    /// screenshot hotkey must not, or ⌘⇧A would also run whatever the focused
    /// app binds to it.
    public var consumesMatchedEvent = false

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
        guard keyCode != nil || flags != 0 else {
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
        startHealthTimer()
        NSLog("%@", "[ShortcutMonitor] Started monitoring keyCode=\(keyCode.map(String.init) ?? "any") flags=\(flags)")
        return true
    }

    /// Stop monitoring.
    public func stop() {
        guard monitoring else { return }

        healthTimer?.invalidate()
        healthTimer = nil

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

    // MARK: - 健康巡检

    private static let healthInterval: TimeInterval = 2

    /// 系统停用 tap 时只在回调里发一个伪事件，靠它在当场重新上膛。主线程正忙的那
    /// 一下伪事件可能排不上队，tap 就停在「isMonitoring 还是 true、但一个键都收不到」
    /// 的状态里，而 `start()` 见到 monitoring 就不会重建 —— 用户只能重启 App。
    /// 这里按固定节拍查一次：关着的打开，端口废了的整只重建。
    private func startHealthTimer() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    /// 巡检结论：健康 / 只是被系统关掉（打开就行）/ 端口已废（整只重建）。
    enum HealthAction: Equatable {
        case ok
        case reEnable
        case rebuild
    }

    /// 判定单独拿出来：拔掉真 tap 也能把整张表逐格打完。
    static func healthAction(hasTap: Bool, portIsValid: Bool, tapIsEnabled: Bool) -> HealthAction {
        guard hasTap, portIsValid else { return .rebuild }
        return tapIsEnabled ? .ok : .reEnable
    }

    /// 用例直接调这一条，不必等计时器。
    func checkHealth() {
        guard monitoring else { return }
        let label = keyCode.map(String.init) ?? "any"
        let tap = eventTap
        let action = Self.healthAction(
            hasTap: tap != nil,
            portIsValid: tap.map(CFMachPortIsValid) ?? false,
            tapIsEnabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        )
        switch action {
        case .ok:
            return
        case .reEnable:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            NSLog("%@", "[ShortcutMonitor] Health: tap was disabled keyCode=\(label), re-enabled")
        case .rebuild:
            NSLog("%@", "[ShortcutMonitor] Health: tap missing or port invalid keyCode=\(label), rebuilding")
            stop()
            _ = start()
        }
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
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            NSLog("%@", "[ShortcutMonitor] Tap disabled by system (\(reason)), re-armed keyCode=\(keyCode.map(String.init) ?? "any")")
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = UInt(event.flags.rawValue)

        // Check if key code matches (a nil keyCode matches any key)
        if let expectedKeyCode = keyCode, eventKeyCode != expectedKeyCode {
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

        return consumesMatchedEvent ? nil : Unmanaged.passRetained(event)
    }
}