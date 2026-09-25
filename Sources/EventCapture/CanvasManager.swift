//
//  CanvasManager.swift
//  MacStroke
//
//  Manages the gesture drawing canvas - collects mouse events into strokes,
//  decides whether a right-click should start a gesture (filters), replays
//  right-click events when no gesture matched, and forwards right-clicks to
//  apps that need their native context menu (RightClicksList).
//
//  This is the Swift counterpart of the original's
//  AppDelegate.mouseEventCallback + CanvasWindowController.
//

import Foundation
import AppKit
import GestureEngine

/// Delegate for CanvasManager to notify when a stroke is complete.
public protocol CanvasManagerDelegate: AnyObject {
    /// Called when a gesture stroke is completed and ready for recognition.
    /// - Parameters:
    ///   - manager: The canvas manager
    ///   - stroke: The completed stroke (ready for comparison)
    ///   - bundleID: The bundle ID of the frontmost application (for filtering)
    ///   - Returns: true if a rule matched and the action was handled
    ///             (the right-click is consumed); false if nothing matched
    ///             (the manager will replay the right-click).
    @discardableResult
    func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) -> Bool
}

/// Manages the gesture drawing canvas.
///
/// Event flow (mirrors the original, with the trigger button widened to
/// middle/side/extra buttons when the user enables them):
/// 1. Trigger-mouse-down → check the button is an allowed trigger and no
///    suppressing modifier is held, then the filters (black/white list, "show UI
///    in any app", app has a suited rule). If allowed, begin capture, show the
///    canvas.
/// 2. Same-button mouse-dragged → record points, draw on canvas.
/// 3. Same-button mouse-up → try rule matching via the delegate. If nothing
///    matched:
///    - Right button, app in RightClicksList, no drag: synthesize a
///      Ctrl+left-click so the app shows its native context menu.
///    - Otherwise replay that button's down/up events so the app sees the click.
public class CanvasManager: EventCaptureDelegate {

    public weak var delegate: CanvasManagerDelegate?

    /// App-layer filter deciding whether a gesture may start in the given app.
    /// Set by the application to combine BlackWhiteFilter, "show UI in any app"
    /// and "app has a suited rule" checks (mirrors the original's
    /// `!shouldHookMouseEventForApp(frontBundle) || !(showUIInWhateverApp || appSuitedRule)` gate).
    public var shouldCaptureGesture: ((String) -> Bool)?

    /// Whether the given app should get its native right-click menu forwarded
    /// when a click (no drag) doesn't match any gesture (RightClicksList check).
    public var needsRightClickMenu: ((String) -> Bool)?

    /// Whether a gesture may start from the given mouse button.
    ///
    /// The original only ever watched the right button; the port additionally
    /// takes middle / side / user-bound extra buttons (issue #53) and asks the
    /// app layer per event, so flipping a preferences toggle applies without
    /// restarting or rebuilding the event tap. Unset means right-button-only,
    /// i.e. exactly the original's behaviour.
    public var isTriggerButtonAllowed: ((MouseButton) -> Bool)?

    /// The modifier keys that must not start a gesture (issue #59). Asked per
    /// event, like the trigger-button check, so the preferences apply at once.
    /// Unset or empty means modifiers never interfere — the original's
    /// behaviour, since it never looked at the flags a click arrived with.
    public var suppressedModifiers: (() -> Set<GestureModifier>)?

    /// Ignore gesture starts for a moment, while preferences are waiting for
    /// the user to press the button they want to bind. Deliberately separate
    /// from `isEnabled`, which is the master switch the preferences own.
    public var isSuspended = false

    /// Master enable switch (mirrors the original's static `isEnabled`).
    public var isEnabled = true

    /// When true, the next completed gesture is recorded via
    /// `onGestureRecorded` instead of being matched against rules
    /// (the "Draw Gesture" rule-editing flow).
    public var isRecordingGesture = false

    /// Called with the recorded gesture points when `isRecordingGesture`
    /// completes. The receiver stores them into the pending rule.
    public var onGestureRecorded: (([GesturePoint]) -> Void)?

    /// Points below this count are treated as a simple click, not a gesture
    /// (the original's DTW comparison requires at least 10 points).
    private let minimumPointsForGesture = 10

    // MARK: - Gesture state

    private var currentPoints: [GesturePoint] = []
    /// Previous drag point, used for the Synergy teleport check.
    private var lastDragPoint: GesturePoint?
    private var isCapturing = false
    private var hasDragged = false
    /// The button that started the current gesture; drags and the matching up
    /// are only accepted for this one.
    private var activeTrigger: MouseButton?
    /// The location (AppKit global coords) where the current gesture started.
    private var downLocation: GesturePoint?
    /// Whether the front app passed the capture filter for the current gesture.
    private var shouldShow = false

    // MARK: - Canvas windows

    /// The canvas overlay window shown during gesture drawing.
    /// Keyed by screen identifier for multi-screen support.
    private var canvasWindows: [String: CanvasWindow] = [:]

    /// Create a new canvas manager.
    public init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Update canvas window frames when screen layout changes (e.g. display added/removed/resized).
    @objc private func screenParametersDidChange() {
        for (_, window) in canvasWindows {
            let newFrame = window.screen?.frame ?? NSScreen.main?.frame ?? .zero
            if window.frame != newFrame {
                window.setFrame(newFrame, display: false)
                window.canvasView.resize(to: newFrame)
            }
        }
    }

    // MARK: - EventCaptureDelegate

    /// Handle a mouse event from EventCapture.
    /// - Returns: true to consume (swallow) the event; false to pass it through.
    @discardableResult
    public func eventCapture(_ capture: EventCapture, didReceive event: MouseEvent) -> Bool {
        switch event.phase {
        case .down:
            switch event.button {
            case .left:
                // Original AppDelegate.m:431-438 — while a gesture is in
                // progress, left clicks are swallowed to avoid mis-fires.
                return shouldShow && isCapturing
            case .right:
                return handleTriggerMouseDown(event)
            default:
                guard isTriggerAllowed(event.button) else { return false }
                return handleTriggerMouseDown(event)
            }

        case .moved:
            guard shouldShow, isCapturing, event.button == activeTrigger else { return false }
            // Original AppDelegate.m:332-357 — Synergy hands the pointer to
            // another machine: the point teleports from a screen edge to the
            // screen center. Treat that as gesture cancellation.
            if isSynergyJump(from: lastDragPoint, to: event.point) {
                resetGestureState()
                return true
            }
            hasDragged = true
            lastDragPoint = event.point
            currentPoints.append(event.point)
            addPointToCanvas(event.point)
            return true

        case .up:
            guard shouldShow, isCapturing, event.button == activeTrigger else { return false }
            return handleTriggerMouseUp(event)
        }
    }

    /// Whether the given button may start a gesture. The right button is always
    /// allowed (that is the original's only trigger); everything else goes
    /// through the app-layer preference check.
    private func isTriggerAllowed(_ button: MouseButton) -> Bool {
        if button == .right { return true }
        return isTriggerButtonAllowed?(button) ?? false
    }

    /// Whether any modifier that must suppress gestures is currently held.
    /// Holding one of several configured modifiers is enough — the request was
    /// for "certain modifiers, or combinations of them", and a combination
    /// always includes at least one single modifier.
    private func isSuppressedByModifiers(_ modifiers: Set<GestureModifier>) -> Bool {
        guard let suppressed = suppressedModifiers else { return false }
        return !suppressed().isDisjoint(with: modifiers)
    }

    // MARK: - Gesture trigger handling

    private func handleTriggerMouseDown(_ event: MouseEvent) -> Bool {
        guard isEnabled, !isSuspended else {
            shouldShow = false
            return false
        }

        // A suppressed modifier held at mouse-down hands the whole click-drag
        // back to the front app untouched (issue #59). Only the down phase is
        // checked: pressing a modifier mid-stroke stays as it always was.
        if isSuppressedByModifiers(event.modifiers) {
            shouldShow = false
            return false
        }

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        // Filter gate: black/white list + "show UI in whatever app" / suited rule.
        if let shouldCapture = shouldCaptureGesture, !shouldCapture(frontBundle) {
            shouldShow = false
            return false
        }

        shouldShow = true

        // If a previous gesture was interrupted (down without up, e.g. the tap
        // was disabled by timeout), finish it off so the app sees its click.
        if isCapturing {
            finishInterruptedGesture()
        }

        currentPoints = [event.point]
        lastDragPoint = event.point
        downLocation = event.point
        hasDragged = false
        isCapturing = true
        activeTrigger = event.button

        showCanvasWindow(for: event.point)
        addPointToCanvas(event.point)

        return true
    }

    private func handleTriggerMouseUp(_ event: MouseEvent) -> Bool {
        currentPoints.append(event.point)
        addPointToCanvas(event.point)

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let consumed: Bool

        // Rule-recording mode ("Draw Gesture" from preferences).
        if isRecordingGesture {
            isRecordingGesture = false
            onGestureRecorded?(currentPoints)
            consumed = true
        } else if currentPoints.count >= minimumPointsForGesture,
                  let stroke = completedStroke(),
                  let delegate = delegate,
                  delegate.canvasManager(self, didCompleteStroke: stroke, bundleID: frontBundle) {
            // A rule matched and its action was executed.
            consumed = true
        } else {
            // No gesture matched: give the click back to the app so the button
            // still does whatever it normally does.
            let trigger = activeTrigger ?? .right
            if trigger == .right,
               let needsRightClickMenu = needsRightClickMenu,
               needsRightClickMenu(frontBundle), !hasDragged {
                // Apps like JetBrains IDEs: synthesize Ctrl+left-click so the
                // native context menu appears (original: threadRightClick).
                // Only meaningful for the right button — that is the click
                // whose job is opening a context menu.
                if let down = downLocation {
                    performSyntheticRightClick(at: down)
                }
            } else if let down = downLocation {
                // Replay the trigger button's down + up so the app sees the click.
                replayClick(button: trigger, down: down, up: event.point)
            }
            consumed = true
        }

        resetGestureState()
        return consumed
    }

    /// Build the completed stroke from the recorded points.
    private func completedStroke() -> Stroke? {
        guard currentPoints.count >= 2 else { return nil }
        var stroke = Stroke(capacity: currentPoints.count)
        for p in currentPoints {
            stroke.addPoint(p)
        }
        return stroke
    }

    /// Reset gesture state and hide the canvas after a short delay so the
    /// user still sees the drawn path (matches original reinitWindow timing).
    private func resetGestureState() {
        currentPoints = []
        lastDragPoint = nil
        isCapturing = false
        hasDragged = false
        activeTrigger = nil
        downLocation = nil
        shouldShow = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.hideAllCanvasWindows()
        }
    }

    /// Original AppDelegate.m:332-357 — previous drag point near a primary
    /// screen edge and the new point near the screen center means Synergy
    /// teleported the pointer to another machine.
    private func isSynergyJump(from previous: GesturePoint?, to current: GesturePoint) -> Bool {
        guard let previous, let screen = NSScreen.main else { return false }
        let f = screen.frame
        let threshold: Double = 30
        let nearEdge = abs(previous.x - f.minX) < threshold
            || abs(previous.x - f.maxX) < threshold
            || abs(previous.y - f.minY) < threshold
            || abs(previous.y - f.maxY) < threshold
        let nearCenter = abs(current.x - (f.minX + f.width / 2)) < threshold
            && abs(current.y - (f.minY + f.height / 2)) < threshold
        return nearEdge && nearCenter
    }

    /// Replay the pending down + a synthetic up for an interrupted gesture.
    private func finishInterruptedGesture() {
        if let down = downLocation {
            replayClick(
                button: activeTrigger ?? .right,
                down: down,
                up: currentPoints.last ?? down
            )
        }
        resetGestureState()
    }

    // MARK: - Event replay / synthesis

    /// Replay a down/up pair for the button that started the gesture, so the
    /// frontmost application receives the click normally (a middle click still
    /// opens links, a side click still navigates back).
    private func replayClick(button: MouseButton, down: GesturePoint, up: GesturePoint) {
        let number = button.cgNumber
        postSyntheticMouseEvent(number: number, pressed: true, at: down)
        postSyntheticMouseEvent(number: number, pressed: false, at: up)
    }

    private func postSyntheticMouseEvent(number: Int, pressed: Bool, at point: GesturePoint) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch number {
        case 0:
            type = pressed ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        case 1:
            type = pressed ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        default:
            // Every non-left/right button, and the real number is written into
            // the payload below (CG only names left/right/center).
            type = pressed ? .otherMouseDown : .otherMouseUp
            cgButton = .center
        }

        // Convert back from AppKit (bottom-left) to CG (top-left) global coords.
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: cgPoint,
            mouseButton: cgButton
        ) else { return }
        if number >= 2 {
            // `otherMouse*` covers every non-left/right button, so the payload
            // has to carry which one this actually was.
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        }
        // Original: CGEventPost(kCGSessionEventTap, …) — session level is
        // downstream of our HID tap, so the replay is not re-captured
        // (posting at HID would loop: capture → replay → capture …).
        event.post(tap: .cgSessionEventTap)
    }

    /// Synthesize Ctrl+left-click at the given point on a background thread,
    /// mirroring the original's `threadRightClick:` (used for apps whose
    /// context menus need a synthetic click, e.g. JetBrains IDEs).
    private func performSyntheticRightClick(at point: GesturePoint) {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        Thread.detachNewThread {
            // Original taps: control keys at session, left clicks at HID.
            let controlDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x3B, keyDown: true)
            controlDown?.post(tap: .cgSessionEventTap)
            usleep(25_000) // improve reliability (matches original)

            let leftDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            )
            leftDown?.post(tap: .cghidEventTap)
            usleep(15_000) // improve reliability (matches original)

            let leftUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            )
            leftUp?.post(tap: .cghidEventTap)

            let controlUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x3B, keyDown: false)
            controlUp?.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Public helpers

    /// Cancel the current stroke without notifying the delegate.
    public func cancelStroke() {
        resetGestureState()
        hideAllCanvasWindows()
    }

    /// Whether currently capturing a gesture.
    public var capturing: Bool { isCapturing }

    // MARK: - Canvas Window Management

    /// Adds a point to all visible canvas windows for visual feedback.
    private func addPointToCanvas(_ point: GesturePoint) {
        for window in canvasWindows.values {
            let viewPoint = convertPointToView(point, for: window)
            window.canvasView.addPoint(viewPoint)
        }
    }

    /// Shows a canvas window covering the screen that contains the given point.
    private func showCanvasWindow(for point: GesturePoint) {
        hideAllCanvasWindows()

        let screen = screenContainingPoint(point)
        let screenKey = String(describing: screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber ?? NSNumber(value: 0))
        let screenFrame = screen.frame

        let window: CanvasWindow
        if let existing = canvasWindows[screenKey] {
            existing.setEnable(true)
            if existing.frame != screenFrame {
                existing.setFrame(screenFrame, display: false)
                existing.canvasView.resize(to: screenFrame)
            }
            window = existing
        } else {
            window = CanvasWindow(screenFrame: screenFrame)
            canvasWindows[screenKey] = window
        }

        window.canvasView.updateColorFromDefaults()
        window.show()
    }

    /// Hides all canvas windows and clears their drawing.
    private func hideAllCanvasWindows() {
        for (_, window) in canvasWindows {
            window.hide()
            window.canvasView.clear()
        }
    }

    /// Returns the screen that contains the given point.
    private func screenContainingPoint(_ point: GesturePoint) -> NSScreen {
        let location = CGPoint(x: point.x, y: point.y)
        for screen in NSScreen.screens {
            if NSPointInRect(location, screen.frame) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Converts a GesturePoint (in AppKit global coordinates) to the local
    /// coordinate system of the given screen-covering canvas window.
    private func convertPointToView(_ point: GesturePoint, for window: CanvasWindow) -> CGPoint {
        let screenFrame = window.screen?.frame ?? NSScreen.main?.frame ?? .zero
        return CGPoint(
            x: point.x - screenFrame.origin.x,
            y: point.y - screenFrame.origin.y
        )
    }
}
