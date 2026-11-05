//
//  VolumeRuleActionTests.swift
//  MacStroke
//
//  issue #78 第 3 条（音量做规则动作）的取证。
//
//  3.2.4 起滚轮两档也已并进规则表（旧 plist 在启动时迁移成规则，见
//  LegacyWheelGestureImportTests），音量动作只剩这一条出口：画一条手势 → 动作选
//  「音量 +1 / −1 档」。所以本层只钉两头：
//  - **执行**：`ActionExecutor` 传给音量的那个数。坏法有三种 —— 正反号写反（下拉选 +1 却
//    把音量往下压）、档位大小另写一份（改了 `SystemVolume.volumeStep` 忘了改这里，两处
//    手感不一样）、桩件没接管于是真去动本机音量。
//  - **持久化**：原版字典 schema 里 `actionType` 只能接着往下占号（截图占了 4，这两个是
//    5/6），而且这两个动作没有参数，写多了字段会被老版本读成「快捷键 + keyCode 0」。
//
//  全程不碰本机真音量：`SystemVolume` 那四个接缝在 setUp/tearDown 里成对装卸，
//  「接缝优先」本身也是一条判据（下面 testVolumeStepperStubReplacesTheRealDeviceEntirely）。
//
import XCTest
import CoreAudio
@testable import RuleEngine
@testable import GestureEngine

final class VolumeRuleActionTests: XCTestCase {

    private var stored: [UInt32: Double] = [:]

    override func tearDown() {
        SystemVolume.propertyReader = nil
        SystemVolume.propertyWriter = nil
        SystemVolume.defaultDeviceReader = nil
        SystemVolume.propertyPresenceChecker = nil
        super.tearDown()
    }

    /// 一台「只有分声道、Main 档没有」的假设备（本机实测正是这形态）。
    private func fakeDevice(values: [UInt32: Double]) {
        stored = values
        SystemVolume.defaultDeviceReader = { 42 }
        SystemVolume.propertyPresenceChecker = { _, channel in channel == 1 || channel == 2 }
        SystemVolume.propertyReader = { _, channel in self.stored[channel] }
        SystemVolume.propertyWriter = { _, channel, value in
            self.stored[channel] = value
            return true
        }
    }

    // MARK: - 执行：那一个数

    func testVolumeActionsCarryTheSharedStepSize() {
        var steps: [Double] = []
        let executor = ActionExecutor()
        executor.volumeStepper = { steps.append($0); return true }

        executor.execute(.volumeUp)
        executor.execute(.volumeDown)

        XCTAssertEqual(steps, [SystemVolume.volumeStep, -SystemVolume.volumeStep],
                       "规则动作必须和 SystemVolume 用同一个数、而且是相反的两个方向")
        XCTAssertEqual(SystemVolume.volumeStep, 0.05, "一格 = 5%：改了这档要连带改文档")
    }

    func testOneTriggerIsOneStepAndOnlyTheChosenDirection() {
        var steps: [Double] = []
        let executor = ActionExecutor()
        executor.volumeStepper = { steps.append($0); return true }

        executor.execute(.volumeUp, for: volumeRule(.volumeUp))
        XCTAssertEqual(steps.count, 1, "一次手势推两档，用户只要再配一条 −1 就找不回平衡了")
        XCTAssertEqual(steps.first, 0.05)
        XCTAssertGreaterThan(steps.first ?? 0, 0, "「+1 档」传负数就是方向装反")

        steps = []
        executor.execute(.volumeDown, for: volumeRule(.volumeDown))
        XCTAssertEqual(steps, [-0.05])
    }

    /// 假设备上某一声道此刻的读数。缺失就当 0：这几条期望值没有一个是 0，
    /// 「压根没写」照样会红，但用例里不必被 Optional 绊住。
    private func volume(of channel: UInt32) -> Double { stored[channel] ?? 0 }

    /// 桩件必须**顶掉**真设备那一手，而不是在它之外再走一遍：否则测试跑一趟本机音量就动了，
    /// 而且线上真挂了 stepper 时会出现「动了两次」。
    func testVolumeStepperStubReplacesTheRealDeviceEntirely() {
        fakeDevice(values: [1: 0.5, 2: 0.5])
        var steps: [Double] = []
        let executor = ActionExecutor()
        executor.volumeStepper = { steps.append($0); return true }

        executor.execute(.volumeUp)

        XCTAssertEqual(steps, [0.05])
        XCTAssertEqual(stored, [1: 0.5, 2: 0.5], "桩件接管了还写进设备，等于音量一次跳两档")
    }

    /// 没挂桩件时走的是 `SystemVolume` 默认输出设备那一条真链路（两声道一起动）。
    func testVolumeUpWithoutAStubDrivesTheDefaultOutputDevice() {
        fakeDevice(values: [1: 0.5, 2: 0.5])
        let executor = ActionExecutor()

        executor.execute(.volumeUp)

        XCTAssertEqual(volume(of: 1), 0.55, accuracy: 0.0001)
        XCTAssertEqual(volume(of: 2), 0.55, accuracy: 0.0001, "只写一个声道就是左右不平衡")
    }

    func testVolumeDownWithoutAStubDrivesTheSameDevice() {
        fakeDevice(values: [1: 0.5, 2: 0.5])
        let executor = ActionExecutor()

        executor.execute(.volumeDown)

        XCTAssertEqual(volume(of: 1), 0.45, accuracy: 0.0001)
        XCTAssertEqual(volume(of: 2), 0.45, accuracy: 0.0001)
    }

    /// 已经顶到头：这一档写不动，但动作仍然算做完了 —— 音量到 1.0 之后规则不能改成
    /// 「这条手势没匹配上」。钳位本身的判据在 WheelGestureActionTests，这里只钉执行侧的取值。
    func testSteppingUpAtTheCeilingKeepsTheValueClamped() {
        fakeDevice(values: [1: 0.98, 2: 1.0])
        let executor = ActionExecutor()

        executor.execute(.volumeUp)

        XCTAssertEqual(volume(of: 1), 1.0, accuracy: 0.0001)
        XCTAssertEqual(volume(of: 2), 1.0, accuracy: 0.0001, "越界不钳会把标量写成 1.05，CoreAudio 直接拒收")
    }

    // MARK: - 持久化：actionType 5 / 6

    func testVolumeActionsPersistAsActionTypesFiveAndSix() throws {
        let up = try jsonObject(for: volumeRule(.volumeUp))
        XCTAssertEqual(up["actionType"] as? Int, 5)
        XCTAssertNil(up["shortcut_code"], "音量没有参数；写了会被老版本读成「快捷键 keyCode 0」，那是 A 键")
        XCTAssertNil(up["shortcut_flag"])
        XCTAssertNil(up["apple_script_id"])

        let down = try jsonObject(for: volumeRule(.volumeDown))
        XCTAssertEqual(down["actionType"] as? Int, 6)

        XCTAssertEqual(try decodeActionType(4, extra: [:]), .screenshot, "截图仍占 4：号位一滑，老规则全体错位")
        XCTAssertEqual(try decodeActionType(5, extra: [:]), .volumeUp)
        XCTAssertEqual(try decodeActionType(6, extra: [:]), .volumeDown)
    }

    func testVolumeActionsRoundTripThroughTheRuleEncoder() throws {
        for action in [RuleAction.volumeUp, RuleAction.volumeDown] {
            let data = try JSONEncoder().encode(volumeRule(action))
            let reloaded = try JSONDecoder().decode(Rule.self, from: data)
            XCTAssertEqual(reloaded.action, action, "读回来变了动作：\(action)")
            XCTAssertEqual(reloaded.name, "音量")
        }
    }

    /// 切 actionType 只改类型不换值（原版语义）：从快捷键切到音量再切回来，录的那串键
    /// 必须还填着。音量这一档自己带着 spares 读写，漏一手就把用户的快捷键冲掉。
    func testVolumeActionTypesKeepTheOtherSlots() throws {
        for type in [5, 6] {
            let json = [
                "direction": "Volume", "data": [["x": 0.0, "y": 0.0]], "filter": "*",
                "filterType": 0, "actionType": type,
                "text": "留着", "password": "12345678",
                "shortcut_code": 4, "shortcut_flag": 1048576,
                "note": "",
            ] as [String: Any]
            let rule = try JSONDecoder().decode(Rule.self,
                                                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(rule.action, type == 5 ? .volumeUp : .volumeDown)
            XCTAssertEqual(rule.spareActions.text, "留着")
            XCTAssertEqual(rule.spareActions.password, "12345678")
            XCTAssertEqual(rule.spareActions.shortcutCode, 4)
            XCTAssertEqual(rule.spareActions.shortcutFlag, 1048576)
        }
    }

    /// 老版本 / 手改文件读到没占过的号，仍旧退成快捷键而不是把整份 rules.json 顶崩。
    func testAnUnassignedActionTypeStillDecodesAsShortcut() throws {
        let json = [
            "direction": "x", "data": [["x": 0.0, "y": 0.0]], "filter": "*",
            "filterType": 0, "actionType": 7, "shortcut_code": 13, "shortcut_flag": 1048576,
        ] as [String: Any]
        let rule = try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(rule.action, .shortcut(keyCode: 13, flags: 1048576))
    }

    // MARK: -  helpers

    private func volumeRule(_ action: RuleAction) -> Rule {
        Rule(name: "音量", description: "", template: GestureTemplate(points: [], name: "Volume"),
             action: action, note: "")
    }

    private func jsonObject(for rule: Rule) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(rule)) as? [String: Any])
    }

    private func decodeActionType(_ type: Int, extra: [String: Any]) throws -> RuleAction {
        var json: [String: Any] = [
            "direction": "n", "data": [["x": 0.0, "y": 0.0]], "filter": "*",
            "filterType": 0, "actionType": type,
        ]
        extra.forEach { json[$0] = $1 }
        return try JSONDecoder().decode(Rule.self,
                                       from: JSONSerialization.data(withJSONObject: json)).action
    }
}
