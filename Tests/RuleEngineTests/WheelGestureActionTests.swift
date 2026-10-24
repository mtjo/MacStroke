// issue #75 的下半段：滚轮触发之后那「一下」到底投出去什么。
//
// 三段各自钉住：
// 1. `WheelGesturePlan` 那张查表 —— 档位与效应的对应、以及「没配 = nil」（nil 时调用方
//    不许吞事件，这是整套判据的底线）；⌘⇧ 那两个键码写反就是「上滚切下一页」。
// 2. `WheelGestureExecutor` —— 两条出口都换接缝：数「前台应用收到了什么键」而不必真去
//    切标签页；音量那条同样喂假写手，测试期间绝不碰本机音量。
// 3. `SystemVolume` —— 读写与「有没有这一档」全走接缝，于是能钉住三件在真设备上没法
//    反复演的事：Main 档报 unknown property 时逐声道退让、钳位、已经在 0/1 头上时
//    仍然算「配了动作」（不能因为到底了就退回去滚页面）。
import XCTest
import CoreAudio
@testable import RuleEngine

final class WheelGestureActionTests: XCTestCase {

    override func tearDown() {
        SystemVolume.propertyReader = nil
        SystemVolume.propertyWriter = nil
        SystemVolume.defaultDeviceReader = nil
        SystemVolume.propertyPresenceChecker = nil
        super.tearDown()
    }

    // MARK: - 查表

    func testTabDirectionKeys() {
        XCTAssertEqual(WheelGesturePlan.effect(kind: .tabPrevious, customShortcut: nil),
                       .shortcut(keyCode: 33, flags: WheelGesturePlan.commandShiftFlags),
                       "上一个标签页 = ⌘⇧[ （33 是 bracketleft；写反就和下滚对调了）")
        XCTAssertEqual(WheelGesturePlan.effect(kind: .tabNext, customShortcut: nil),
                       .shortcut(keyCode: 30, flags: WheelGesturePlan.commandShiftFlags),
                       "下一个标签页 = ⌘⇧] （30 是 bracketright）")
        XCTAssertEqual(WheelGesturePlan.commandShiftFlags, 1_179_648,
                       "⌘(0x100000)|⇧(0x20000)：少一位就变成按 [ 而不是 ⌘⇧[")
    }

    func testVolumeDirectionsAreOpposite() {
        XCTAssertEqual(WheelGesturePlan.effect(kind: .volumeUp, customShortcut: nil)?.describe.contains("+5%"), true)
        XCTAssertEqual(WheelGesturePlan.effect(kind: .volumeUp, customShortcut: nil), .volume(step: 0.05))
        XCTAssertEqual(WheelGesturePlan.effect(kind: .volumeDown, customShortcut: nil), .volume(step: -0.05),
                       "上下必须反号，否则上滚下滚都在把音量往同一头推")
    }

    func testNoneIsNoEffect() {
        XCTAssertNil(WheelGesturePlan.effect(kind: .none, customShortcut: (0, 0)),
                     "「无」哪怕带着一条录好的键也不该动 —— 事件要原样交回前台应用")
    }

    func testCustomShortcutUsesTheRecordedKey() {
        XCTAssertEqual(WheelGesturePlan.effect(kind: .customShortcut, customShortcut: (5, 262144)),
                       .shortcut(keyCode: 5, flags: 262144))
    }

    /// 录了「自定义快捷键」但录入框是空的（或被清除）→ 这一格当没配。
    func testCustomShortcutWithoutAKeyIsNoEffect() {
        XCTAssertNil(WheelGesturePlan.effect(kind: .customShortcut, customShortcut: nil),
                     "空快捷键不能退化成「按 0 号键」（0 就是 A），那等于把用户的 A 键全局吞掉")
    }

    /// 偏好里存的是裸整数：认不出的数（手改 plist / 将来加新档）一律当「没配」。
    func testUnknownPreferenceValuesFallBackToNone() {
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: 99), .none)
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: -1), .none)
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: 1), .tabPrevious,
                       "StorageDefaults 的 1/2 就是这两档，改了序号就是老用户设置全跑位")
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: 2), .tabNext)
    }

    // MARK: - 执行：两条出口

    func testExecutorPostsTheShortcutExactlyOnce() {
        var posted: [(keyCode: UInt16, flags: UInt)] = []
        let executor = WheelGestureExecutor()
        executor.shortcutPoster = { keyCode, flags in posted.append((keyCode, flags)) }

        XCTAssertTrue(executor.fire(kind: .tabNext, customShortcut: nil))
        XCTAssertEqual(posted.count, 1, "一次滚轮只投一条：投两发就是切两页")
        XCTAssertEqual(posted.first?.keyCode, 30)
        XCTAssertEqual(posted.first?.flags, WheelGesturePlan.commandShiftFlags)
    }

    func testExecutorDoesNothingForUnboundDirection() {
        var posted: [(keyCode: UInt16, flags: UInt)] = []
        var volumeCalls = 0
        let executor = WheelGestureExecutor()
        executor.shortcutPoster = { keyCode, flags in posted.append((keyCode, flags)) }
        executor.volumeStepper = { _ in volumeCalls += 1; return true }

        XCTAssertFalse(executor.fire(kind: .none, customShortcut: nil),
                       "返回 false = 这一格没接住，调用方必须把滚轮交回前台应用")
        XCTAssertTrue(posted.isEmpty)
        XCTAssertEqual(volumeCalls, 0)
    }

    /// 音量动不了（没插输出设备）→ false → 页面照常滚，不假装成功。
    func testExecutorReportsAFailedVolumeStep() {
        let executor = WheelGestureExecutor()
        executor.volumeStepper = { _ in false }
        XCTAssertFalse(executor.fire(kind: .volumeUp, customShortcut: nil))
    }

    func testExecutorPassesTheSignedStep() {
        var steps: [Double] = []
        let executor = WheelGestureExecutor()
        executor.volumeStepper = { steps.append($0); return true }

        XCTAssertTrue(executor.fire(kind: .volumeDown, customShortcut: nil))
        XCTAssertEqual(steps, [-0.05])
    }

    // MARK: - SystemVolume：档位、钳位、到底了

    /// 假设备：Main 那一档「没有」（本机实测就是这形态），声道 1/2 有。
    private func fakeDevice(channels: [UInt32], values: [UInt32: Double] = [:]) {
        SystemVolume.defaultDeviceReader = { 42 }
        SystemVolume.propertyPresenceChecker = { _, channel in channels.contains(channel) }
        var stored = values
        SystemVolume.propertyReader = { _, channel in stored[channel] }
        SystemVolume.propertyWriter = { _, channel, value in
            stored[channel] = value
            return true
        }
    }

    func testMainElementIsPreferredWhenItExists() throws {
        fakeDevice(channels: [kAudioObjectPropertyElementMain, 1, 2],
                   values: [kAudioObjectPropertyElementMain: 0.5, 1: 0.9, 2: 0.9])
        XCTAssertTrue(SystemVolume.step(by: 0.05))
        // Main 档在列表最前，读到并写回的都是它。
        XCTAssertEqual(try XCTUnwrap(SystemVolume.current()), 0.55, accuracy: 0.0001,
                       "有 Main 汇总档时要用它，逐声道写会把两声道写成不同的值")
    }

    func testFallsBackToChannelsWhenMainIsMissing() throws {
        fakeDevice(channels: [1, 2], values: [1: 0.34363854, 2: 0.34363854])
        XCTAssertTrue(SystemVolume.step(by: 0.05))
        XCTAssertEqual(try XCTUnwrap(SystemVolume.current()), 0.39363854, accuracy: 0.0001,
                       "本机实测就是这条：Main 报 unknown property，音量挂在声道 1/2 上")
    }

    func testBothChannelsMoveTogether() {
        var written: [UInt32: Double] = [:]
        SystemVolume.defaultDeviceReader = { 42 }
        SystemVolume.propertyPresenceChecker = { _, channel in channel == 1 || channel == 2 }
        SystemVolume.propertyReader = { _, _ in 0.5 }
        SystemVolume.propertyWriter = { _, channel, value in written[channel] = value; return true }

        XCTAssertTrue(SystemVolume.step(by: 0.05))
        XCTAssertEqual(written, [1: 0.55, 2: 0.55], "只写一个声道就是一边响一边不响")
    }

    func testClampsAtTheTop() throws {
        fakeDevice(channels: [1], values: [1: 0.98])
        XCTAssertTrue(SystemVolume.step(by: 0.05))
        XCTAssertEqual(try XCTUnwrap(SystemVolume.current()), 1.0, accuracy: 0.0001,
                       "越界要钳住，不能写成 1.03")
    }

    /// 已经在 100% 时这一档写不动，但用户确实配了动作 —— 仍算做成，不许退回去滚页面。
    func testAlreadyAtTheLimitStillCountsAsHandled() {
        fakeDevice(channels: [1], values: [1: 1.0])
        XCTAssertTrue(SystemVolume.step(by: 0.05),
                       "到底了就说「没做成」，事件会漏给前台应用，页面跟着滚一下")
    }

    func testDownClampsAtZero() throws {
        fakeDevice(channels: [1], values: [1: 0.02])
        XCTAssertTrue(SystemVolume.step(by: -0.05))
        XCTAssertEqual(try XCTUnwrap(SystemVolume.current()), 0.0, accuracy: 0.0001)
    }

    func testNoOutputDeviceIsReportedHonestly() {
        SystemVolume.defaultDeviceReader = { nil }
        XCTAssertFalse(SystemVolume.step(by: 0.05))
        XCTAssertNil(SystemVolume.current())
    }

    func testDeviceWithoutAnyVolumeChannelDoesNothing() {
        SystemVolume.defaultDeviceReader = { 42 }
        SystemVolume.propertyPresenceChecker = { _, _ in false }
        XCTAssertFalse(SystemVolume.step(by: 0.05),
                       "读写不到音量就说读写不到：让调用方把滚轮交回去，比假装调过强")
    }

    func testZeroDeltaIsNotATrigger() {
        fakeDevice(channels: [1], values: [1: 0.5])
        XCTAssertFalse(SystemVolume.step(by: 0))
    }
}
