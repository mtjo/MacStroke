//
//  EventCapture.swift
//  MacStroke
//
//  Global mouse event capture using CGEventTap.
//  Captures right-mouse gesture events (down/dragged/up) and left-mouse-down,
//  converting them to GesturePoint values for the GestureEngine to consume.
//
//  Mirrors the original MacStroke behavior:
//  - Only right-button drags start gestures (left button is observed but passed through)
//  - The delegate decides whether to consume (swallow) each event; consumed
//    events do not propagate to other applications (returns NULL from the tap)
//  - The tap is automatically re-enabled after a timeout disable
//  - Points are converted to AppKit-style bottom-left-origin coordinates,
//    matching the original's NSEvent.locationInWindow convention so that
//    gesture templates and live strokes share the same coordinate space.
//

import Foundation
import AppKit
import GestureEngine

/// A captured mouse event with timestamp and screen coordinates.
public struct MouseEvent {
    public let point: GesturePoint
    public let button: MouseButton
    public let phase: MousePhase

    public init(point: GesturePoint, button: MouseButton, phase: MousePhase) {
        self.point = point
        self.button = button
        self.phase = phase
    }
}

public enum MouseButton {
    case left
    case right
    case other
}

public enum MousePhase {
    case moved
    case down
    case up
}

/// Delegate for receiving captured mouse events.
public protocol EventCaptureDelegate: AnyObject {
    /// Handle a captured mouse event.
    /// - Returns: `true` to consume (swallow) the event so it does not
    ///   propagate to other applications; `false` to let it pass through.
    @discardableResult
    func eventCapture(_ capture: EventCapture, didReceive event: MouseEvent) -> Bool
}

/// Global mouse event capture using CGEventTap.
///
/// Usage:
/// ```swift
/// let capture = EventCapture()
/// capture.delegate = self
/// capture.start()
/// ```
///
/// Requires the Accessibility ("Monitor Input") permission.
public class EventCapture: NSObject {
    public weak var delegate: EventCaptureDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false

    /// Master enable switch (mirrors the original's static `isEnabled`).
    /// When false, all events pass through untouched.
    public var isEnabled = true

    /// The CGEventMask for mouse events we care about — the same set the
    /// original MacStroke listens for.
    private let mouseEventMask: CGEventMask = {
        let rightDownMask = (1 << CGEventType.rightMouseDown.rawValue)
        let rightDraggedMask = (1 << CGEventType.rightMouseDragged.rawValue)
        let rightUpMask = (1 << CGEventType.rightMouseUp.rawValue)
        let leftDownMask = (1 << CGEventType.leftMouseDown.rawValue)
        return CGEventMask(rightDownMask | rightDraggedMask | rightUpMask | leftDownMask)
    }()

    /// Height of the primary screen, used to convert CG (top-left origin)
    /// global coordinates to AppKit (bottom-left origin) global coordinates.
    private static var primaryScreenHeight: Double {
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Start capturing global mouse events.
    /// - Returns: true if the event tap was created successfully, false otherwise.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let capture = Unmanaged<EventCapture>.fromOpaque(refcon).takeUnretainedValue()
            return capture.handleEvent(type: type, event: event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mouseEventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            NSLog("%@", "[EventCapture] Failed to create event tap")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        isRunning = true
        NSLog("%@", "[EventCapture] Started")
        return true
    }

    /// Stop capturing global mouse events.
    public func stop() {
        guard isRunning else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isRunning = false
        NSLog("%@", "[EventCapture] Stopped")
    }

    /// Whether the event capture is currently running.
    public var running: Bool { isRunning }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the system disabled it due to a timeout or
        // user input, mirroring the original's kCGEventTapDisabledByTimeout
        // handling (which just re-enables and returns NULL).
        //
        // Important: on these disable notifications the `event` argument is a
        // synthetic pseudo-event we do NOT own. Returning it (retained) makes
        // CoreFoundation release it at the end of the runloop callout, causing
        // an objc_release over-release crash on real, fast gestures (the tap
        // times out under load). Return NULL instead, exactly like the original.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        guard isEnabled else {
            return Unmanaged.passRetained(event)
        }

        // Only the event types in our mask reach here; convert to AppKit
        // bottom-left-origin global coordinates like the original's
        // [NSEvent eventWithCGEvent:] + locationInWindow convention.
        let location = event.location
        let appKitY = Self.primaryScreenHeight - location.y
        let gesturePoint = GesturePoint(x: location.x, y: appKitY)

        let button: MouseButton
        let phase: MousePhase
        switch type {
        case .leftMouseDown:
            button = .left
            phase = .down
        case .rightMouseDown:
            button = .right
            phase = .down
        case .rightMouseUp:
            button = .right
            phase = .up
        case .rightMouseDragged:
            button = .right
            phase = .moved
        default:
            button = .other
            phase = .moved
        }

        let mouseEvent = MouseEvent(point: gesturePoint, button: button, phase: phase)
        let consume = delegate?.eventCapture(self, didReceive: mouseEvent) ?? false

        if consume {
            // Swallow the event (return NULL) so it does not reach other apps.
            return nil
        }
        return Unmanaged.passRetained(event)
    }

    deinit {
        stop()
    }
}
