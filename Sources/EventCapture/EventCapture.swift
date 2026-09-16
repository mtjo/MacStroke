//
//  EventCapture.swift
//  MacStroke
//
//  Global mouse event capture using CGEventTap.
//  Captures mouse move, button down/up events and converts them
//  to GesturePoint values for the GestureEngine to consume.
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
    func eventCapture(_ capture: EventCapture, didReceive event: MouseEvent)
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
/// Requires the "Monitor Input" accessibility permission.
public class EventCapture: NSObject {
    public weak var delegate: EventCaptureDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false

    /// The CGEventMask for mouse events we care about.
    private let mouseEventMask: CGEventMask = {
        let moveMask = (1 << CGEventType.mouseMoved.rawValue)
        let leftDownMask = (1 << CGEventType.leftMouseDown.rawValue)
        let leftUpMask = (1 << CGEventType.leftMouseUp.rawValue)
        let rightDownMask = (1 << CGEventType.rightMouseDown.rawValue)
        let rightUpMask = (1 << CGEventType.rightMouseUp.rawValue)
        return CGEventMask(moveMask | leftDownMask | leftUpMask | rightDownMask | rightUpMask)
    }()

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

        // Create the event tap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mouseEventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("[EventCapture] Failed to create event tap")
            return false
        }

        // Create a run loop source and add it to the current run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isRunning = true
        print("[EventCapture] Started")
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
        print("[EventCapture] Stopped")
    }

    /// Whether the event capture is currently running.
    public var running: Bool { isRunning }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Get the mouse location in screen coordinates
        let location = event.location

        // Convert to GesturePoint
        let gesturePoint = GesturePoint(x: location.x, y: location.y)

        // Determine button and phase
        let button: MouseButton
        switch type {
        case .leftMouseDown, .leftMouseUp:
            button = .left
        case .rightMouseDown, .rightMouseUp:
            button = .right
        default:
            button = .other
        }

        let phase: MousePhase
        switch type {
        case .leftMouseDown, .rightMouseDown:
            phase = .down
        case .leftMouseUp, .rightMouseUp:
            phase = .up
        default:
            phase = .moved
        }

        let mouseEvent = MouseEvent(point: gesturePoint, button: button, phase: phase)
        delegate?.eventCapture(self, didReceive: mouseEvent)

        // Return the event so it continues to propagate normally
        return Unmanaged.passRetained(event)
    }

    deinit {
        stop()
    }
}
