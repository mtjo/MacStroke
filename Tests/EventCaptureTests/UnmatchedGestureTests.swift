// 手势画完却没匹配上时，这一次右键去哪儿了（issue #73）。
//
// 判据全部走 `syntheticEventSink` 那道接缝：数「前台应用到底收到了几发合成事件」，
// 而不是读 CanvasManager 自己声明的状态，也不用真动这台机器的指针 —— 回放路径原本
// 是直接 `CGEvent.post(tap:)` 打进会话层的，没有接缝就只能靠肉眼看菜单弹没弹。
//
// 三条反向对照缺一不可：默认关（= 原版行为，画错了照样弹菜单）、开关开着但只是纯
// 单击（右键菜单不能因此消失）、开关开着且落在 RightClicksList 的应用里（那一条走的是
// 合成 Ctrl+左键，跟回放不是一个出口）。
import XCTest
import CoreGraphics
@testable import EventCapture
@testable import GestureEngine

final class UnmatchedGestureTests: XCTestCase {

    private final class FixedDelegate: CanvasManagerDelegate {
        /// false = 一条规则都没匹配上，抬手后进兜底分支。
        var matches = false
        private(set) var strokePointCount = 0

        @discardableResult
        func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) -> Bool {
            strokePointCount = stroke.count
            return matches
        }
    }

    private struct Delivery {
        let type: CGEventType
        let location: CGEventTapLocation
    }

    private var delegate: FixedDelegate!
    private var manager: CanvasManager!
    private var capture: EventCapture!
    private var deliveries: [Delivery] = []

    override func setUp() {
        super.setUp()
        delegate = FixedDelegate()
        manager = CanvasManager()
        capture = EventCapture()
        manager.delegate = delegate
        capture.delegate = manager
        deliveries = []
        manager.syntheticEventSink = { [weak self] event, location in
            self?.deliveries.append(Delivery(type: event.type, location: location))
        }
    }

    override func tearDown() {
        manager.syntheticEventSink = nil
        manager.cancelStroke()
        capture.stop()
        delegate = nil
        manager = nil
        capture = nil
        super.tearDown()
    }

    // MARK: - 默认：不匹配就把手势原样还成一次点击（原版行为）

    func testUnmatchedStrokeIsReplayedByDefault() {
        delegate.matches = false
        drawGesture(points: 20)

        XCTAssertEqual(replayedButtons(), [.rightDown, .rightUp],
                       "默认必须回放一对右键，用户画错了还能弹出菜单")
        XCTAssertEqual(replayLocations(), [.session, .session],
                       "回放只能打在会话层：投到 HID 会被自己的 tap 再抓一次")
    }

    // MARK: - 开关开：真画了一条就不还了

    func testSwitchOnSwallowsADeliberateUnmatchedStroke() {
        manager.shouldSwallowUnmatchedGesture = { true }
        delegate.matches = false

        let consumed = drawGesture(points: 20)

        XCTAssertTrue(consumed, "抬手那一下仍然要被吞掉，不能漏一发进系统")
        XCTAssertTrue(deliveries.isEmpty, "不该有任何合成事件投给前台应用：\(deliveries.map { $0.type.rawValue })")
        XCTAssertFalse(manager.capturing, "吞掉之后手势状态要复位，否则下一右键起不了手")
        XCTAssertGreaterThan(delegate.strokePointCount, 10, "判据前提：这条轨迹确实够格当手势")
    }

    // MARK: - 反向对照①：纯右键单击永远照常弹菜单

    func testPlainRightClickIsStillReplayedWhenSwallowingIsOn() {
        manager.shouldSwallowUnmatchedGesture = { true }
        delegate.matches = false
        click(withoutDragging: true)

        XCTAssertEqual(replayedButtons(), [.rightDown, .rightUp],
                       "开关只该管「画了一条」的，右键单击被吞掉就是凭空废掉整个菜单")
    }

    /// 反向对照②：手抖拖了两下、点数不够 DTW 起步（<10），也不算画了手势。
    func testShortDragBelowTheGestureThresholdIsStillReplayed() {
        manager.shouldSwallowUnmatchedGesture = { true }
        delegate.matches = false
        drawGesture(points: 6)

        XCTAssertEqual(replayedButtons(), [.rightDown, .rightUp],
                       "六个点够不成一条手势，这一下还得还给应用")
    }

    // MARK: - 反向对照③：匹配成功那条路不受影响

    func testMatchedStrokeNeverReplays() {
        manager.shouldSwallowUnmatchedGesture = { true }
        delegate.matches = true
        drawGesture(points: 20)

        XCTAssertTrue(deliveries.isEmpty, "匹配上了本来就不该回放，开不开这个开关都一样")
    }

    // MARK: - RightClicksList 的应用：单击走的是合成 Ctrl+左键，另一个出口

    func testClickInRightClickListAppsStillSynthesisesCtrlLeftClick() throws {
        manager.shouldSwallowUnmatchedGesture = { true }
        manager.needsRightClickMenu = { _ in true }
        delegate.matches = false
        click(withoutDragging: true)

        // 那四发（⌃↓ ←↓ ←↑ ⌃↑）在后台线程投，中间还有 usleep，等它凑齐。
        let deadline = Date().addingTimeInterval(2)
        while deliveries.count < 4 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // 实测：⌃那两发出来的类型是 flagsChanged 而不是 keyDown（0x3B 是修饰键位，
        // CGEvent 自己按键位归了类）—— 这正是 JetBrains 那套合成能弹出菜单的原因。
        let types = deliveries.map { Int($0.type.rawValue) }
        XCTAssertEqual(types, [Int(CGEventType.flagsChanged.rawValue),
                               Int(CGEventType.leftMouseDown.rawValue),
                               Int(CGEventType.leftMouseUp.rawValue),
                               Int(CGEventType.flagsChanged.rawValue)],
                       "修饰键仍走会话层、左键仍走 HID 层，这条路径不该被新分支接管")
        XCTAssertEqual(deliveries.map { $0.location == .cghidEventTap }, [false, true, true, false])
    }

    // MARK: - 驱动

    /// 沿对角线拖出 `points` 个点（含起手与抬手），返回抬手那一下有没有被吞。
    @discardableResult
    private func drawGesture(points: Int) -> Bool {
        send(.right, .down, at: 0)
        for step in 1..<(points - 1) {
            send(.right, .moved, at: Double(step) * 12)
        }
        return send(.right, .up, at: Double(points - 1) * 12)
    }

    /// 按下再抬手，中间不挪窝（`withoutDragging` 为假时算手抖一动）。
    @discardableResult
    private func click(withoutDragging: Bool) -> Bool {
        send(.right, .down, at: 100)
        if !withoutDragging { _ = send(.right, .moved, at: 101) }
        return send(.right, .up, at: withoutDragging ? 100 : 102)
    }

    @discardableResult
    private func send(_ button: MouseButton, _ phase: MousePhase, at coordinate: Double) -> Bool {
        manager.eventCapture(capture, didReceive: MouseEvent(
            point: GesturePoint(x: coordinate, y: coordinate),
            button: button,
            phase: phase
        ))
    }

    /// 投出去的鼠标键，按「哪个键的按下/抬起」归纳，方便断言顺序。
    private enum ReplayButton: Equatable { case rightDown, rightUp, other }

    private func replayedButtons() -> [ReplayButton] {
        deliveries.map {
            switch $0.type {
            case .rightMouseDown: return .rightDown
            case .rightMouseUp: return .rightUp
            default: return .other
            }
        }
    }

    private enum Tap: Equatable { case session, hid, other }

    private func replayLocations() -> [Tap] {
        deliveries.map {
            switch $0.location {
            case .cgSessionEventTap: return .session
            case .cghidEventTap: return .hid
            default: return .other
            }
        }
    }
}
