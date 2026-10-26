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
    ///   - releasePoint: Where the trigger button was let go, in **WindowServer
    ///     global coordinates** (primary screen's top-left origin, y pointing down) —
    ///     the same space `kCGWindowBounds` uses, so the app layer can hit-test it
    ///     against the on-screen window list without another conversion
    ///     (issue #22: 「动作该打到光标下那一扇」). Note this is *not* the space the
    ///     stroke points are stored in: `EventCapture` flips y to AppKit's
    ///     bottom-left origin (`primaryScreenHeight - y`), which is what the canvas
    ///     and the recogniser use. The capture layer deliberately keeps no opinion
    ///     about which window the gesture belongs to.
    ///   - Returns: true if a rule matched and the action was handled
    ///             (the right-click is consumed); false if nothing matched
    ///             (the manager will replay the right-click).
    @discardableResult
    func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String,
                       releasePoint: CGPoint) -> Bool
}

extension CanvasManager {
    /// 抬手点的坐标系换算 —— **唯一**一处把轨迹坐标翻回窗口服务坐标的地方（issue #22）。
    ///
    /// 两套尺子：轨迹与画布用 AppKit 的**主屏左下原点、y 向上**（`EventCapture.swift:374`
    /// 在采集时就翻了：`appKitY = primaryScreenHeight - cgY`）；而「光标下那扇窗」的命中判定
    /// 吃的是 `kCGWindowBounds` 那套 —— **主屏左上原点、y 向下**。差一个 y 就是
    /// 「明明压在窗上却判成没有窗」，而且只在窗口上/下某一侧出现，装机时看着像时灵时不灵。
    ///
    /// 为什么单独拆一个静态函数：这一手写坏时界面上、日志里都看不出名堂（判据只是
    /// `noWindowUnderCursor` 那一档），所以必须有个能用字面数字钉住的地方 —— 挂在调用处
    /// 那一句上，桩件里就只有一条「delegate 收到什么」的间接断言，红起来也说不清是哪儿翻的。
    ///
    /// `primaryHeight` 要的是**全局原点所在那块屏**的高度：AppKit 里就是 `NSScreen.screens[0]`
    /// （文档保证它的左下角落在全局坐标 (0,0)），与 `EventCapture` 采集时同一个来源 ——
    /// 两处互逆，多屏下才对得上。**不许换成 `NSScreen.main`**（那是含指针那块屏，
    /// 副屏上抬手就会翻错）；这一档离线给不了判据，只有装机多屏那一步能验。
    static func windowServerReleasePoint(_ appKitPoint: GesturePoint,
                                        primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: Double(primaryHeight) - appKitPoint.y)
    }
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
    /// The original only ever watched the right button. The port has one
    /// configurable trigger button (issue #53) and asks the app layer per
    /// event, so changing it in the preferences applies without restarting or
    /// rebuilding the event tap. Unset means right-button-only, which is
    /// exactly the original's behaviour and also the shipped default.
    public var isTriggerButtonAllowed: ((MouseButton) -> Bool)?

    /// The modifier keys that must not start a gesture (issue #59). Asked per
    /// event, like the trigger-button check, so the preferences apply at once.
    /// Unset or empty means modifiers never interfere — the original's
    /// behaviour, since it never looked at the flags a click arrived with.
    public var suppressedModifiers: (() -> Set<GestureModifier>)?

    /// Whether an unmatched **drawn** gesture should be swallowed instead of
    /// handed back to the front app (issue #73). Asked per event, like the two
    /// closures above, so the preference applies without a restart.
    ///
    /// Unset means "hand it back" — the original's behaviour: it always replayed
    /// the click, so a gesture that failed to match still opened the context
    /// menu. Only strokes that look like a deliberate drawing are affected; a
    /// plain right click is never swallowed, or the menu would vanish for
    /// everyone who turns this on. See `handleTriggerMouseUp`.
    public var shouldSwallowUnmatchedGesture: (() -> Bool)?

    /// Where synthetic mouse/key events are delivered. Production leaves this
    /// nil, which posts at the tap location the call site asks for (session for
    /// replays, mixed for the JetBrains synthetic). Tests install a sink to
    /// count what the front app would have received — without it this whole
    /// branch can only be verified by moving the real pointer.
    var syntheticEventSink: ((CGEvent, CGEventTapLocation) -> Void)?

    // MARK: - Wheel triggers (issue #75)

    /// 「右键 + 滚轮」这功能的总开关。Asked per gesture start, like the two
    /// closures above, so the preference applies without a restart.
    ///
    /// 关掉时压根不上膛滚轮 tap —— 默认等于原版行为（原版没这功能），而且不发一次
    /// 无谓的 `tapEnable` 往返。
    public var isWheelGestureEnabled: (() -> Bool)?

    /// 上膛 / 收膛的出口，由 App 层接到 `EventCapture.setWheelCaptureArmed`。
    ///
    /// 走闭包而不是让 CanvasManager 攥着 EventCapture：捕获状态机只决定「这段窗口归不归
    /// 滚轮管」，真正的 tap 生命周期归 EventCapture。没挂上时什么都没发生（单测就靠这点
    /// 只验状态，不去碰真 tap）。
    public var wheelCaptureArmer: ((Bool) -> Void)?

    /// 一次滚轮触发要干什么：返回 true = 这个方向确实配了动作并做成了，事件该吞掉。
    /// 返回 false（那方向配的是「无」/ 音量动不了）→ 事件原样交回前台应用，页面照常滚。
    public var onWheelGesture: ((WheelGestureDirection) -> Bool)?

    /// 一次拨动只触发一次的闸门（高分辨率滚轮 / 触控板惯性会把一格拆成几十发）。
    private var wheelGate = WheelGestureGate()

    /// 这一段窗口里滚轮已经触发过动作了 —— 抬手时既不再拿轨迹去匹配，也不回放点击。
    private var wheelFired = false

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

    /// Whether the given button may start a gesture. The app layer owns the
    /// single configured trigger button; without its answer nothing is allowed,
    /// which leaves the right button as the only trigger.
    private func isTriggerAllowed(_ button: MouseButton) -> Bool {
        guard let isTriggerButtonAllowed else { return button == .right }
        return isTriggerButtonAllowed(button)
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
        wheelFired = false
        wheelGate.reset()

        // 这段窗口开给滚轮（issue #75）：按下起始键到松开之间的那几发滚轮才是「右键+滚轮」
        // 这条触发，窗口外的一律当普通滚轮交回前台应用。
        armWheelCapture()

        showCanvasWindow(for: event.point)
        addPointToCanvas(event.point)

        return true
    }

    /// 要不要给这段窗口上膛滚轮监听。
    ///
    /// 三条件：总开关开、偏好里那功能开、且不在「绘制手势」录制态 —— 录制态里用户要的是一条
    /// 轨迹，滚轮掺进来会同时切标签页，那画面没法解释。
    private func armWheelCapture() {
        guard !isRecordingGesture, isWheelGestureEnabled?() == true else { return }
        wheelCaptureArmed = true
        wheelCaptureArmer?(true)
    }

    private func handleTriggerMouseUp(_ event: MouseEvent) -> Bool {
        // 这段窗口里滚轮已经触发过动作（issue #75）：抬手时什么都不做。
        // 不拿轨迹去匹配 —— 按住滚轮时指针难免抖出半条弧线，那条不该再叠一个手势动作；
        // 也不回放点击 —— 否则「切完标签页凭空弹出右键菜单」，正是 issue #73 里用户抱怨的
        // 那种「我没要菜单」。整段吞掉。
        if wheelFired {
            NSLog("%@", "[CanvasManager] Wheel gesture fired; release consumed without match or replay")
            resetGestureState()
            return true
        }

        currentPoints.append(event.point)
        addPointToCanvas(event.point)

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        // 抬手点交给 App 层去判「这一下归哪一扇窗」（issue #22）。这里唯一做的是把
        // 轨迹那套 AppKit 坐标（左下原点）翻回窗口服务那套（左上原点）—— 见
        // `windowServerReleasePoint` 那一段：判中不中必须和 `kCGWindowBounds` 同一把尺。
        let releasePoint = CanvasManager.windowServerReleasePoint(
            event.point, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        let consumed: Bool

        // Rule-recording mode ("Draw Gesture" from preferences).
        if isRecordingGesture {
            isRecordingGesture = false
            onGestureRecorded?(currentPoints)
            consumed = true
        } else if currentPoints.count >= minimumPointsForGesture,
                  let stroke = completedStroke(),
                  let delegate = delegate,
                  delegate.canvasManager(self, didCompleteStroke: stroke, bundleID: frontBundle,
                                         releasePoint: releasePoint) {
            // A rule matched and its action was executed.
            consumed = true
        } else if shouldSwallowUnmatchedGesture?() == true, drewADeliberateStroke {
            // 用户随手画一条不存在的轨迹来「取消」这次手势（issue #73）。这时候把右键
            // 交回前台应用，就是凭空弹出他刚刚明确不想要的那个菜单 —— 什么都不投，
            // 整段吞掉。判据只看「这一下是不是真的画了一条」：纯单击仍走下面的回放。
            NSLog("%@", "[CanvasManager] Unmatched gesture swallowed (no click replay)")
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

    /// 这一下是不是「真的画了一条」：拖过、而且点数够 DTW 起步（不足 10 点在原版语义里
    /// 就是单击）。只有够格的轨迹才可能被吞 —— 用户抱怨的是「画一个不存在的手势来取消」，
    /// 不是「右键不能弹菜单」。必须在 `resetGestureState()` 之前问，之后这两样都被清了。
    private var drewADeliberateStroke: Bool {
        hasDragged && currentPoints.count >= minimumPointsForGesture
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

    /// Reset gesture state and clear the drawn path right away.
    ///
    /// The original does the same: `reinitWindow` (AppDelegate.m:392) swaps in a
    /// fresh empty CanvasView synchronously at the end of the mouseUp branch, so
    /// the path never outlives the release. Lingering it for 300ms makes every
    /// gesture look like the action arrived half a beat late (issue #68).
    private func resetGestureState() {
        currentPoints = []
        lastDragPoint = nil
        isCapturing = false
        hasDragged = false
        activeTrigger = nil
        downLocation = nil
        shouldShow = false

        // 窗口结束 = 滚轮监听收膛（issue #75）。闸门账也要清：留着上一段的
        // `lastFired` 会让下一次按下起始键的第一格被节流吃掉，症状是「第一次不灵」。
        if wheelCaptureArmed {
            wheelCaptureArmed = false
            wheelCaptureArmer?(false)
        }
        wheelGate.reset()
        wheelFired = false

        hideAllCanvasWindows()
    }

    /// CanvasManager 自己记一份膛态，避免靠读 `EventCapture` 的实时状态来决定要不要收膛
    /// （闭包没挂上时读不到，重复收膛又会多发一次无谓的 `tapEnable` 往返）。
    private var wheelCaptureArmed = false

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
        deliver(event, at: .cgSessionEventTap)
    }

    /// 把合成事件投出去。生产环境没有 sink，就是原来的 `post(tap:)`；单测挂上 sink
    /// 才能数出「前台应用到底收到了几发」——否则这条判定只能靠动真鼠标取证。
    private func deliver(_ event: CGEvent, at location: CGEventTapLocation) {
        if let syntheticEventSink = syntheticEventSink {
            syntheticEventSink(event, location)
        } else {
            event.post(tap: location)
        }
    }

    /// Synthesize Ctrl+left-click at the given point on a background thread,
    /// mirroring the original's `threadRightClick:` (used for apps whose
    /// context menus need a synthetic click, e.g. JetBrains IDEs).
    private func performSyntheticRightClick(at point: GesturePoint) {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        Thread.detachNewThread { [weak self] in
            // Original taps: control keys at session, left clicks at HID.
            guard let self else { return }
            let controlDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x3B, keyDown: true)
            if let controlDown { self.deliver(controlDown, at: .cgSessionEventTap) }
            usleep(25_000) // improve reliability (matches original)

            let leftDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            )
            if let leftDown { self.deliver(leftDown, at: .cghidEventTap) }
            usleep(15_000) // improve reliability (matches original)

            let leftUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            )
            if let leftUp { self.deliver(leftUp, at: .cghidEventTap) }

            let controlUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x3B, keyDown: false)
            if let controlUp { self.deliver(controlUp, at: .cgSessionEventTap) }
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

// MARK: - WheelGestureDelegate (issue #75)

extension CanvasManager: WheelGestureDelegate {

    /// 按住起始键期间来了一发滚轮。
    ///
    /// 四道闸全过才算一次触发：
    /// 1. 这段窗口是本功能自己开出来的（`shouldShow` + `isCapturing` —— 起始键是配置的那颗、
    ///    前台应用过了过滤、没被修饰键让位，都已经在 `handleTriggerMouseDown` 里判过）；
    /// 2. 这发滚轮自己没被该让位的修饰键按住（issue #59 同一条规矩：按住修饰键时不归本功能）；
    /// 3. 累计够一格、且离上一次触发过了最小间隔（`WheelGestureGate`）；
    /// 4. App 层答得出这个方向配了什么动作、并且真的做成了。
    ///
    /// 任何一道没过都返回 false —— 事件原样交回前台应用，页面照常滚。「没接住就不拦」是
    /// 这套判据的底线：用户感知不到功能存在，远好过莫名被吞掉一次滚动。
    ///
    /// 这里不再读一次 `isWheelGestureEnabled`：只有它开了才会膛（`armWheelCapture`），
    /// 再读是把一次偏好查询挂在滚轮热路径上。
    public func eventCapture(_ capture: EventCapture, didScrollWith reading: WheelGestureReading) -> Bool {
        guard shouldShow, isCapturing, isEnabled, !isSuspended else { return false }
        if isSuppressedByModifiers(reading.modifiers) { return false }
        guard wheelGate.accept(reading) else { return false }
        guard onWheelGesture?(reading.direction) == true else { return false }

        wheelFired = true
        NSLog("%@", "[CanvasManager] Wheel gesture \(reading.direction == .up ? "up" : "down") fired "
            + "(累计 \(reading.lines) 格)")
        return true
    }
}
