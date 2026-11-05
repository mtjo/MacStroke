// 3.2.4 起「右键增强」页那两档滚轮整并进规则表，本文件只剩两头：
//
// 1. 旧 plist 那 0…5 档到 `RuleAction` 的映射（`WheelGestureActionKind.ruleAction`）——
//    启动迁移只走这一张表。⌘⇧ 那两个键码写反就是「上滚切下一页」；「无」必须映射成
//    nil（nil 时迁移不生成规则，滚轮原样交给前台应用）。
// 2. `SystemVolume` —— 读写与「有没有这一档」全走接缝，于是能钉住三件在真设备上没法
//    反复演的事：Main 档报 unknown property 时逐声道退让、钳位、已经在 0/1 头上时
//    仍然算「做成了」。
//
// 迁移本身的用例在 `LegacyWheelGestureImportTests`；规则里音量动作的执行侧在
// `VolumeRuleActionTests`。
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

    // MARK: - 旧档位 → 规则动作

    func testTabDirectionKeys() {
        XCTAssertEqual(WheelGestureActionKind.tabPrevious.ruleAction(),
                       .shortcut(keyCode: 33, flags: WheelGestureActionKind.commandShiftFlags),
                       "上一个标签页 = ⌘⇧[ （33 是 bracketleft；写反就和下滚对调了）")
        XCTAssertEqual(WheelGestureActionKind.tabNext.ruleAction(),
                       .shortcut(keyCode: 30, flags: WheelGestureActionKind.commandShiftFlags),
                       "下一个标签页 = ⌘⇧] （30 是 bracketright）")
        XCTAssertEqual(WheelGestureActionKind.commandShiftFlags, 1_179_648,
                       "⌘(0x100000)|⇧(0x20000)：少一位就变成按 [ 而不是 ⌘⇧[")
    }

    func testVolumeDirectionsAreDistinct() {
        XCTAssertEqual(WheelGestureActionKind.volumeUp.ruleAction(), .volumeUp)
        XCTAssertEqual(WheelGestureActionKind.volumeDown.ruleAction(), .volumeDown,
                       "上下必须是两个动作，否则上下滚都在把音量往同一头推")
    }

    func testNoneIsNoAction() {
        XCTAssertNil(WheelGestureActionKind.none.ruleAction(customShortcut: (0, 0)),
                     "「无」哪怕带着一条录好的键也不该生成规则 —— 滚轮要原样交回前台应用")
    }

    func testCustomShortcutUsesTheRecordedKey() {
        XCTAssertEqual(WheelGestureActionKind.customShortcut.ruleAction(customShortcut: (5, 262144)),
                       .shortcut(keyCode: 5, flags: 262144))
    }

    /// 录了「自定义快捷键」但录入框是空的（或被清除）→ 这一格当没配。
    func testCustomShortcutWithoutAKeyIsNoAction() {
        XCTAssertNil(WheelGestureActionKind.customShortcut.ruleAction(customShortcut: nil),
                     "空快捷键不能退化成「按 0 号键」（0 就是 A），那等于把用户的 A 键全局吞掉")
    }

    /// 偏好里存的是裸整数：认不出的数（手改 plist / 将来加新档）一律当「没配」。
    /// 1/2 是历史默认值（切上/下一个标签页），序号一改老用户设置就全体跑位。
    func testUnknownPreferenceValuesFallBackToNone() {
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: 99), .none)
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: -1), .none)
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: 1), .tabPrevious)
        XCTAssertEqual(WheelGestureActionKind(preferenceValue: 2), .tabNext)
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
