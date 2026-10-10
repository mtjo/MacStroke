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

    /// Same idea for `scroll`: one packet should not blow past a whole page.
    static let maxScrollDelta: CGFloat = 300

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
        placeCursor(at: target)
    }

    /// 触屏页的「点哪儿就是哪儿」：手机给的是主屏归一化坐标（0…1），
    /// 所以它不需要知道这台 Mac 是 1440 还是 3025 宽，帧图和坐标天然同一套比例。
    public static func warp(x: Double, y: Double) {
        placeCursor(at: warpTarget(nx: x, ny: y, size: state().size))
    }

    /// 纯换算部分：夹进 0…1 再摊到屏幕上，右下角留一像素，免得贴边点不到。
    static func warpTarget(nx: Double, ny: Double, size: RemoteScreenSize) -> CGPoint {
        let fx = min(max(nx, 0), 1)
        let fy = min(max(ny, 0), 1)
        return CGPoint(x: fx * max(size.w - 1, 0), y: fy * max(size.h - 1, 0))
    }

    private static func placeCursor(at target: CGPoint) {
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

    /// 双指滑动 → 滚轮事件。单位取像素不取「行」：行到像素由系统按当前设置换算
    /// （实测固定 10px/行），手机预知不了，只有像素才谈得上跟手。
    ///
    /// 2026-10-09 用真窗口实测：dy=+100 三条 → 内容原点 -300，也就是 dy 为正
    /// （手指往下划）页面往下走、看到更靠前的内容，和手机上的手感一致，
    /// 所以这里不做任何翻号，方向就是协议里写的那个方向。
    public static func scrollBy(x dx: CGFloat, y dy: CGFloat) {
        let delta = scrollDelta(dx: dx, dy: dy)
        guard delta.x != 0 || delta.y != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: delta.y, wheel2: delta.x, wheel3: 0) else { return }
        // 滚轮事件作用于指针底下的窗口，位置不填就落到 (0,0)。
        event.location = cgPoint(state().cursor)
        event.post(tap: .cgSessionEventTap)
    }

    /// 纯计算部分：夹取上限并取整，wheel1 是垂直轴、wheel2 是水平轴。
    static func scrollDelta(dx: CGFloat, dy: CGFloat) -> (x: Int32, y: Int32) {
        let clampedX = min(max(dx, -maxScrollDelta), maxScrollDelta).rounded()
        let clampedY = min(max(dy, -maxScrollDelta), maxScrollDelta).rounded()
        return (x: Int32(clampedX), y: Int32(clampedY))
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
