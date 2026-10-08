//
//  RemoteClickExecutor.swift
//  MacStroke
//
//  Turns decoded remote commands into real mouse events.
//
//  The posting recipe is the same one the gesture replay already uses
//  (`postSyntheticMouseEvent` in Sources/EventCapture/CanvasManager.swift):
//  events go out at `kCGSessionEventTap`, which is downstream of MacStroke's
//  own HID tap, so a remote click is never mistaken for the start of a
//  gesture.
//

import AppKit
import CoreGraphics

public enum RemoteClickExecutor {
    public struct ScreenState: Equatable {
        public var size: RemoteScreenSize
        public var cursor: RemoteScreenPoint
    }

    /// A single `move` command cannot fling the pointer further than this —
    /// a buggy or hostile client should not be able to teleport the cursor
    /// across every screen in one packet.
    static let maxMoveDelta: CGFloat = 500

    /// Screen size and cursor position in CoreGraphics coordinates
    /// (top-left origin, y grows downward) — the space the wire protocol uses.
    public static func state() -> ScreenState {
        let primary = NSScreen.screens.first
        let width = primary?.frame.width ?? 0
        let height = primary?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        return ScreenState(
            size: RemoteScreenSize(w: width, h: height),
            cursor: RemoteScreenPoint(x: mouse.x, y: height - mouse.y)
        )
    }

    /// Moves the pointer by a pixel delta and tells the frontmost app about it,
    /// so hover state follows the pointer instead of lagging behind a warp.
    public static func moveCursor(byX dx: CGFloat, y dy: CGFloat) {
        let current = state()
        let target = moveTarget(from: current.cursor, size: current.size, dx: dx, dy: dy)
        guard target != cgPoint(current.cursor) else { return }
        guard CGWarpMouseCursorPosition(target) == .success else { return }
        // Warping alone does not generate movement events, and the cursor
        // services may have de-associated the HID device while catching up.
        CGAssociateMouseAndMouseCursorPosition(1)
        post(type: .mouseMoved, button: .left, at: target)
    }

    /// Pure part of a move: clamp the delta, then clamp to the screen. Kept
    /// separate so the arithmetic is testable without dragging the user's
    /// pointer around.
    static func moveTarget(from cursor: RemoteScreenPoint, size: RemoteScreenSize,
                           dx: CGFloat, dy: CGFloat) -> CGPoint {
        let clampedX = min(max(dx, -maxMoveDelta), maxMoveDelta)
        let clampedY = min(max(dy, -maxMoveDelta), maxMoveDelta)
        return CGPoint(
            x: min(max(cursor.x + clampedX, 0), max(size.w - 1, 0)),
            y: min(max(cursor.y + clampedY, 0), max(size.h - 1, 0))
        )
    }

    /// Presses or releases a button wherever the pointer currently is.
    public static func setButton(_ button: RemoteMouseButton, pressed: Bool) {
        press(button, at: state().cursor, pressed: pressed)
    }

    /// A click, optionally the second one of a double-click.
    public static func click(button: RemoteMouseButton, doubleClick: Bool) {
        let point = state().cursor
        press(button, at: point, pressed: true, clickState: 1)
        press(button, at: point, pressed: false, clickState: 1)
        guard doubleClick else { return }
        // Apps key off the click-count field more often than off wall-clock
        // timing, so the second press carries it explicitly.
        usleep(60_000)
        press(button, at: point, pressed: true, clickState: 2)
        press(button, at: point, pressed: false, clickState: 2)
    }

    private static func press(_ button: RemoteMouseButton, at point: RemoteScreenPoint,
                              pressed: Bool, clickState: Int = 1) {
        let position = CGPoint(x: point.x, y: point.y)
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button.cgNumber {
        case 0:
            type = pressed ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        case 1:
            type = pressed ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        default:
            // Everything else shares otherMouse*; the real number goes into the
            // payload below, because CG only names left/right/center.
            type = pressed ? .otherMouseDown : .otherMouseUp
            cgButton = .center
        }

        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                 mouseCursorPosition: position, mouseButton: cgButton) else { return }
        if button.cgNumber >= 2 {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.cgNumber))
        }
        if clickState != 1 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cgSessionEventTap)
    }

    static func cgPoint(_ point: RemoteScreenPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    private static func post(type: CGEventType, button: CGMouseButton, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                 mouseCursorPosition: point, mouseButton: button) else { return }
        event.post(tap: .cgSessionEventTap)
    }
}
