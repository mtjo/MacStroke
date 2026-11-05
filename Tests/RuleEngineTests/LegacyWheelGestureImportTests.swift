//
//  LegacyWheelGestureImportTests.swift
//  MacStroke
//
//  3.2.4 把「按住起手键 + 滚轮」从独立偏好整并进规则表。老用户升级时，当年真开过的
//  那两档要一次性地变成两条瞬时规则；没开过的人一条规则都不许多出来。
//
//  判据分三头：
//  - **什么时候迁移**：只认持久域里 `wheelGestureEnabled == true`。注册域里的默认值
//    （issue #76 那一课）和「键从没落过盘」都不算，否则全新安装也会凭空多两条规则。
//  - **迁成什么**：方向、动作、filter、空模板逐格核；「无」和解析不出来的自定义键不生成规则。
//  - **只迁一次**：迁移后总开关落成 false，第二次调用什么都不加；同一方向已有规则也不重复。
//

import XCTest
import Foundation
@testable import RuleEngine
@testable import GestureEngine

final class LegacyWheelGestureImportTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.LegacyWheelGestureImport"
    private var url: URL!
    private var store: RuleStore!

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        store = RuleStore(storageURL: url)
        store.rules = []
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: url)
        store = nil
        super.tearDown()
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    /// 写旧偏好并同步，保证 `persistentDomain` 当场读得到。
    private func writeLegacy(enabled: Bool = true,
                             upAction: Int? = nil,
                             downAction: Int? = nil,
                             upShortcut: String? = nil,
                             downShortcut: String? = nil) {
        let defaults = suite()
        defaults.set(enabled, forKey: "wheelGestureEnabled")
        if let upAction { defaults.set(upAction, forKey: "wheelGestureUpAction") }
        if let downAction { defaults.set(downAction, forKey: "wheelGestureDownAction") }
        if let upShortcut { defaults.set(upShortcut, forKey: "wheelGestureUpShortcut") }
        if let downShortcut { defaults.set(downShortcut, forKey: "wheelGestureDownShortcut") }
        defaults.synchronize()
    }

    @discardableResult
    private func migrate(parseShortcut: @escaping (String) -> (keyCode: UInt16, flags: UInt)? = { _ in nil }) -> Bool {
        store.importLegacyWheelGesturesIfNeeded(
            defaults: suite(),
            domainName: Self.suiteName,
            upName: "上滚",
            downName: "下滚",
            parseShortcut: parseShortcut)
    }

    // MARK: - 什么时候迁移

    /// 全新安装（五个键一个都没落过盘）→ 什么也不加。
    func testFreshInstallAddsNothing() {
        XCTAssertFalse(migrate())
        XCTAssertTrue(store.rules.isEmpty)
    }

    /// 注册域里写着 true/1/2（不是用户写的）→ 不许当成用户配过。
    /// 这正是 issue #76 那回黑名单每启动被清一次的根因。
    func testRegisteredDefaultsAloneDoNotTriggerAMigration() {
        suite().register(defaults: [
            "wheelGestureEnabled": true,
            "wheelGestureUpAction": 1,
            "wheelGestureDownAction": 2,
        ])
        XCTAssertFalse(migrate(), "注册域的默认值被当成了用户设置：全新安装凭空多两条滚轮规则")
        XCTAssertTrue(store.rules.isEmpty)
    }

    /// 总开关当年是关着的（旧页面关开关会写 false）→ 不迁移。
    func testDisabledSwitchDoesNotMigrate() {
        writeLegacy(enabled: false, upAction: 1, downAction: 2)
        XCTAssertFalse(migrate())
        XCTAssertTrue(store.rules.isEmpty)
    }

    // MARK: - 迁成什么

    /// 最普通的升级：只开过总开关，两个下拉保持默认的「上一个/下一个标签页」。
    func testDefaultTabPresetsBecomeCommandShiftBracketShortcuts() throws {
        writeLegacy()
        XCTAssertTrue(migrate())

        XCTAssertEqual(store.rules.count, 2)
        let up = try XCTUnwrap(store.rules.first { $0.instantGesture == .wheelUp })
        let down = try XCTUnwrap(store.rules.first { $0.instantGesture == .wheelDown })
        XCTAssertEqual(up.name, "上滚")
        XCTAssertEqual(down.name, "下滚")
        XCTAssertEqual(up.action, .shortcut(keyCode: 33, flags: 1_179_648),
                       "上滚要迁成 ⌘⇧[（33 是 bracketleft；写反就和新版默认行为对调）")
        XCTAssertEqual(down.action, .shortcut(keyCode: 30, flags: 1_179_648),
                       "下滚要迁成 ⌘⇧]（30 是 bracketright）")
        for rule in [up, down] {
            XCTAssertTrue(rule.isEnabled)
            XCTAssertEqual(rule.filter, "*", "迁移出来的规则必须对所有应用生效，否则老用户看不出变化")
            XCTAssertEqual(rule.filterType, "wildcard")
            XCTAssertTrue(rule.template.points.isEmpty, "瞬时规则不该带轨迹点")
        }
        // 总开关落回 false：下次启动不再迁一遍。
        XCTAssertEqual(suite().object(forKey: "wheelGestureEnabled") as? Bool, false)
    }

    /// 音量两档 → 规则动作里的音量增/减（3.2.4 新加的档位）。
    func testVolumePresetsBecomeVolumeActions() throws {
        writeLegacy(upAction: 3, downAction: 4)
        XCTAssertTrue(migrate())

        let up = try XCTUnwrap(store.rules.first { $0.instantGesture == .wheelUp })
        let down = try XCTUnwrap(store.rules.first { $0.instantGesture == .wheelDown })
        XCTAssertEqual(up.action, .volumeUp)
        XCTAssertEqual(down.action, .volumeDown)
    }

    /// 自定义快捷键：键值串交给调用方那一份解析口径，解析结果原样进规则。
    func testCustomShortcutIsParsedThroughTheInjectedParser() throws {
        writeLegacy(upAction: 5, upShortcut: "keyCode=9, flags=1048576")
        var seen: [String] = []
        XCTAssertTrue(migrate { text in
            seen.append(text)
            return (9, 1_048_576)
        })

        XCTAssertEqual(seen, ["keyCode=9, flags=1048576"], "解析器没拿到旧串，或者把没录键的方向也喂了进去")
        let up = try XCTUnwrap(store.rules.first { $0.instantGesture == .wheelUp })
        XCTAssertEqual(up.action, .shortcut(keyCode: 9, flags: 1_048_576))
        let down = try XCTUnwrap(store.rules.first { $0.instantGesture == .wheelDown })
        XCTAssertEqual(down.action, .shortcut(keyCode: 30, flags: 1_179_648),
                       "下滚没写过的键按旧版注册默认值走「下一个标签页」")
    }

    /// 「无」不生成规则；自定义档但串解析不出来也不生成 —— 旧版这两档本来就不动作。
    func testUnboundDirectionsProduceNoRules() {
        writeLegacy(upAction: 0, downAction: 5, downShortcut: "")
        XCTAssertFalse(migrate())
        XCTAssertTrue(store.rules.isEmpty)
    }

    /// 一条方向配了、另一条是「无」→ 只迁配了的那条。
    func testOnlyTheConfiguredDirectionIsImported() throws {
        writeLegacy(upAction: 1, downAction: 0)
        XCTAssertTrue(migrate())

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.instantGesture, .wheelUp)
    }

    // MARK: - 只迁一次

    /// 迁移跑完再跑一遍：总开关已是 false，规则数不再涨。
    func testSecondRunIsANoOp() {
        writeLegacy()
        XCTAssertTrue(migrate())
        XCTAssertEqual(store.rules.count, 2)

        XCTAssertFalse(migrate())
        XCTAssertEqual(store.rules.count, 2, "第二次启动又加了一遍：用户会看到两条重复规则")
    }

    /// 规则表里已经有同方向的瞬时规则（用户在新版手配过）→ 旧档不再插一脚。
    func testAnExistingInstantRuleForTheSameDirectionIsNotDuplicated() {
        let existing = Rule(name: "手配的上滚", description: "",
                            template: GestureTemplate(points: [], name: "Wheel Up"),
                            action: .text("keep"), note: "",
                            filter: "*", instantGesture: .wheelUp)
        store.rules = [existing]
        writeLegacy()

        XCTAssertTrue(migrate())
        XCTAssertEqual(store.rules.filter { $0.instantGesture == .wheelUp }.count, 1,
                       "同一方向出现了两条：按列表顺序取第一条，用户不知道该信哪条")
        XCTAssertEqual(store.rules.first { $0.instantGesture == .wheelUp }?.name, "手配的上滚")
        XCTAssertNotNil(store.rules.first { $0.instantGesture == .wheelDown })
    }

    /// 迁出来的规则要落盘：规则文件重开还在（偏好窗口一关就重建 store）。
    func testMigratedRulesSurviveReloadingTheStore() throws {
        writeLegacy(upAction: 3, downAction: 4)
        XCTAssertTrue(migrate())

        let reloaded = RuleStore(storageURL: url)
        XCTAssertEqual(reloaded.rules.count, 2)
        XCTAssertEqual(reloaded.rules.first { $0.instantGesture == .wheelUp }?.action, .volumeUp)
        XCTAssertEqual(reloaded.rules.first { $0.instantGesture == .wheelDown }?.action, .volumeDown)
    }

    /// 规则名撞上已有规则时加序号：规则按名字寻址，同名会让改名/编辑互相改错行。
    func testNameCollisionsGetASuffix() throws {
        store.rules = [Rule(name: "上滚", description: "",
                            template: GestureTemplate(points: [], name: "A Shape"),
                            action: .text("existing"), note: "", filter: "*")]
        writeLegacy(upAction: 1)

        XCTAssertTrue(migrate())
        XCTAssertEqual(store.rules.filter { $0.instantGesture == .wheelUp }.count, 1)
        XCTAssertEqual(store.rules.first { $0.instantGesture == .wheelUp }?.name, "上滚 (2)")
        XCTAssertEqual(store.rule(named: "上滚")?.action, .text("existing"),
                       "名字撞车把用户原来那条规则顶掉了")
    }
}
