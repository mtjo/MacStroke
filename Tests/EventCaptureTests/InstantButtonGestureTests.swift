//
//  InstantButtonGestureTests.swift
//  MacStroke
//
//  issue #78 第 2 条扩展：中键 / 侧键（后退、前进）也能直接当触发，不用画轨迹。
//
//  这一层验的是 `CanvasManager` 的分发口径，不碰真 CGEventTap（命令行测试进程里没有
//  辅助功能授权）。四条判据各咬一种坏：
//  - 命中规则：down 吞掉、之后的 dragged/up 跟着吞（否则前台应用收到一个没有 down 的
//    up，侧键会莫名其妙后退一次），动作只触发一次。
//  - 没命中：down/moved/up 原样放行 —— 中键照样开链接、侧键照样后退。
//  - **起手键优先**：同一颗键既是起手键又配了瞬时规则时，走画手势那条路，瞬时回调
//    一次都不许被叫到。
//  - 旁路闸门：停用/挂起/录制态/修饰键让位/过滤不通过时都不动手势。
//

import XCTest
import AppKit
import CoreGraphics
@testable import EventCapture
@testable import GestureEngine

final class InstantButtonGestureTests: XCTestCase {

    private var manager: CanvasManager!
    private var firedGestures: [InstantGesture] = []
    private var firedBundles: [String] = []
    private var shouldFire = true
    private var frontBundle = "com.example.app"

    override func setUp() {
        super.setUp()
        manager = CanvasManager()
        firedGestures = []
        firedBundles = []
        shouldFire = true
        frontBundle = "com.example.app"
        manager.frontBundleReader = { [weak self] in self?.frontBundle ?? "" }
        manager.onInstantButtonGesture = { [weak self] gesture, bundleID in
            self?.firedGestures.append(gesture)
            self?.firedBundles.append(bundleID)
            return self?.shouldFire ?? false
        }
    }

    override func tearDown() {
        manager.onInstantButtonGesture = nil
        manager.frontBundleReader = nil
        manager.cancelStroke()
        manager = nil
        super.tearDown()
    }

    private func event(_ button: MouseButton, _ phase: MousePhase,
                       modifiers: Set<GestureModifier> = []) -> MouseEvent {
        MouseEvent(point: GesturePoint(x: 0.5, y: 0.5), button: button, phase: phase,
                   modifiers: modifiers)
    }

    private func send(_ button: MouseButton, _ phase: MousePhase) -> Bool {
        manager.eventCapture(EventCapture(), didReceive: event(button, phase))
    }

    // MARK: - 命中规则：吞掉整击，只触发一次

    func testMiddleClickFiresTheMatchingGestureAndSwallowsTheWholeClick() {
        XCTAssertTrue(send(.middle, .down), "命中瞬时规则的中键 down 没被吞：前台应用也会收到")
        XCTAssertTrue(send(.middle, .moved), "moved 没跟着吞：前台应用收到半套拖拽")
        XCTAssertTrue(send(.middle, .up), "up 没跟着吞：前台应用收到一个没有 down 的 up")

        XCTAssertEqual(firedGestures, [.middleClick], "中键没有触发中键那一档（或触发了不止一次）")
    }

    func testBackAndForwardMapToTheirOwnGestures() {
        XCTAssertTrue(send(.extra(3), .down))
        XCTAssertTrue(send(.extra(3), .up))
        XCTAssertTrue(send(.extra(4), .down))
        XCTAssertTrue(send(.extra(4), .up))

        XCTAssertEqual(firedGestures, [.backClick, .forwardClick],
                       "侧键 3/4 接错了档位：后退与前进串线")
    }

    func testTheFrontBundleAtPressTimeIsHandedOut() {
        frontBundle = "com.example.target"
        _ = send(.middle, .down)

        XCTAssertEqual(firedBundles, ["com.example.target"],
                       "带出去的不是按下那一刻的前台应用：按应用过滤会匹到别人家")
    }

    /// 只有中键/侧键 3、4 有档位；更高编号的键原样交给前台应用。
    func testHigherExtraButtonsAreNotInstantGestures() {
        XCTAssertFalse(send(.extra(5), .down), "第 5 颗鼠标键被当成了瞬时手势")
        XCTAssertFalse(send(.extra(6), .up))
        XCTAssertTrue(firedGestures.isEmpty, "没有档位的键也叫了瞬时回调")
    }

    // MARK: - 没命中：整击还回去

    func testUnmatchedClickPassesEveryPhaseThrough() {
        shouldFire = false
        XCTAssertFalse(send(.middle, .down), "没有规则命中却吞掉了 down")
        XCTAssertFalse(send(.middle, .moved))
        XCTAssertFalse(send(.middle, .up))
        XCTAssertEqual(firedGestures, [.middleClick], "回调没被叫到：这一条根本没测到放行口径")
    }

    /// 放行之后紧接着来另一颗键的 down，不能被上一击的状态带偏。
    func testAPassingClickDoesNotLeaveStateBehind() {
        shouldFire = false
        _ = send(.extra(3), .down)
        _ = send(.extra(3), .up)

        shouldFire = true
        XCTAssertTrue(send(.middle, .down), "上一击没吞，却把下一击的状态也带歪了")
        XCTAssertTrue(send(.middle, .up))
        XCTAssertEqual(firedGestures, [.backClick, .middleClick])
    }

    // MARK: - 起手键优先

    /// 中键被配置成起手键、同时规则里又有中键瞬时档：按下走画手势，瞬时回调一次都不叫。
    /// 用户据此看到的是画布，而不是「按一下就把动作做了」。
    func testTriggerButtonWinsOverAnInstantRuleOnTheSameButton() {
        manager.isTriggerButtonAllowed = { $0 == .middle }

        XCTAssertTrue(send(.middle, .down), "起手键按下没进画手势那条路")
        XCTAssertTrue(manager.capturing, "起手键按下后没开始画手势")
        XCTAssertTrue(firedGestures.isEmpty,
                      "同一颗键同时是起手键和瞬时档时，瞬时规则也跑了：起手键没有优先")

        // 起手键这一路自己收尾；瞬时那一路压根没参与。
        _ = send(.middle, .up)
        XCTAssertFalse(manager.capturing)
        XCTAssertTrue(firedGestures.isEmpty)
    }

    // MARK: - 旁路闸门

    func testSuspendedManagerDoesNotFireInstantGestures() {
        manager.isSuspended = true
        XCTAssertFalse(send(.middle, .down))
        XCTAssertTrue(firedGestures.isEmpty, "挂起期间（正在录制起手键）还在执行瞬时规则")
    }

    func testDisabledManagerDoesNotFireInstantGestures() {
        manager.isEnabled = false
        XCTAssertFalse(send(.middle, .down))
        XCTAssertTrue(firedGestures.isEmpty, "功能总开关关了还在执行瞬时规则")
    }

    func testRecordingAGestureDoesNotFireInstantGestures() {
        manager.isRecordingGesture = true
        XCTAssertFalse(send(.middle, .down))
        XCTAssertTrue(firedGestures.isEmpty, "「画手势」录制态里按中键不该顺手执行规则")
    }

    func testSuppressingModifierHandsTheClickBack() {
        manager.suppressedModifiers = { [.command] }
        let suppressed = event(.middle, .down, modifiers: [.command])

        XCTAssertFalse(manager.eventCapture(EventCapture(), didReceive: suppressed),
                       "按住让位的修饰键时中键仍被吞：用户按 ⌘ 点中键打不开链接了")
        XCTAssertTrue(firedGestures.isEmpty)

        // 同一颗键不按修饰键时照常触发 —— 证明确实是修饰键那一格挡的。
        XCTAssertTrue(send(.middle, .down))
        XCTAssertEqual(firedGestures, [.middleClick])
    }

    /// 过滤不通过（黑白名单/按应用适用）时同样放行：中键与侧键的原本用途不能被吞掉。
    func testCaptureFilterRejectionPassesTheClickThrough() {
        manager.shouldCaptureGesture = { _ in false }
        XCTAssertFalse(send(.middle, .down))
        XCTAssertTrue(firedGestures.isEmpty, "过滤拒绝了这段窗口，瞬时规则还是执行了")
    }
}
