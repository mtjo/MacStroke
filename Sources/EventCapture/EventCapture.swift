//
//  EventCapture.swift
//  MacStroke
//
//  Global mouse event capture using CGEventTap.
//  Captures the gesture trigger button (right, plus any enabled middle/extra
//  button) in its down/dragged/up phases and left-mouse-down, converting the
//  points into GesturePoint values for the GestureEngine to consume.
//
//  Mirrors the original MacStroke behavior:
//  - Right-button drags start gestures; the left button is observed but passed
//    through. The original had no other trigger; the port additionally listens
//    for middle/extra buttons and lets CanvasManager decide (issue #53).
//  - Every event carries the modifier keys held with it, so CanvasManager can
//    let a modified drag through untouched (issue #59). The original never
//    looked at flags, so nothing is suppressed until the user opts in.
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
    /// The modifier keys held when the event was captured.
    public let modifiers: Set<GestureModifier>

    public init(point: GesturePoint, button: MouseButton, phase: MousePhase, modifiers: Set<GestureModifier> = []) {
        self.point = point
        self.button = button
        self.phase = phase
        self.modifiers = modifiers
    }
}

/// A modifier key, named by the token stored in the `gestureSuppressedModifiers`
/// preference so the capture layer and the preferences share one vocabulary.
public enum GestureModifier: String, CaseIterable {
    case command = "cmd"
    case control = "ctrl"
    case shift = "shift"
    case option = "opt"
    case function = "fn"

    var cgFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .control: return .maskControl
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .function: return .maskSecondaryFn
        }
    }

    /// The flags held by a captured event, in the enum's declaration order.
    static func all(in flags: CGEventFlags) -> Set<GestureModifier> {
        Set(allCases.filter { flags.contains($0.cgFlag) })
    }
}

extension Set where Element == GestureModifier {
    /// Preference form: the chosen tokens joined by commas, in `allCases` order
    /// so the stored string stays stable across get/set round-trips.
    public init(tokenList: String) {
        let tokens = Set<String>(tokenList.split(separator: ",").map(String.init))
        self = Set<GestureModifier>(GestureModifier.allCases.filter { tokens.contains($0.rawValue) })
    }

    public var tokenList: String {
        GestureModifier.allCases.filter { contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

public enum MouseButton: Equatable {
    case left
    case right
    case middle
    /// An extra button on a multi-button mouse. CoreGraphics numbers them from
    /// 3 up (3 = back, 4 = forward); the number is what re-synthesizing the
    /// click needs, so it travels with the case.
    case extra(Int)

    /// CoreGraphics button number (`CGEvent`'s `mouseEventButtonNumber`).
    public var cgNumber: Int {
        switch self {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        case .extra(let number): return number
        }
    }
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

    /// The CGEventMask for mouse events we care about — the original's right
    /// button set plus `otherMouse*`, which is how middle/extra button
    /// gestures reach CanvasManager. Events for a disabled trigger button are
    /// simply passed through, so toggling the preference needs no tap rebuild.
    private let mouseEventMask: CGEventMask = {
        var mask: CGEventMask = 0
        for type in [
            CGEventType.rightMouseDown, .rightMouseDragged, .rightMouseUp,
            .leftMouseDown,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        ] {
            mask |= CGEventMask(1 << type.rawValue)
        }
        return mask
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

        // `otherMouse*` covers every button outside left/right, so the button
        // number in the event payload is what separates the middle button (2)
        // from the side/extra ones (3, 4, …).
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))

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
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            button = buttonNumber == 2 ? .middle : .extra(max(buttonNumber, 3))
            phase = type == .otherMouseDown ? .down : (type == .otherMouseUp ? .up : .moved)
        default:
            return Unmanaged.passRetained(event)
        }

        let mouseEvent = MouseEvent(
            point: gesturePoint,
            button: button,
            phase: phase,
            modifiers: GestureModifier.all(in: event.flags)
        )
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
