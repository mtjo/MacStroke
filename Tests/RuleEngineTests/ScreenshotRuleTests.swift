//
//  ScreenshotRuleTests.swift
//
//  截图手势触发（移植版新增，超出原版）的规则侧取证。手势走的是普通规则管线，所以
//  判据分两头：一头是「存得回去、读得回来」—— rules.json 用的是原版字典 schema，
//  actionType 只能占一个新号（4），旧字段一个都不能丢；另一头是「什么时候装、装在哪」
//  —— 升级只补一次，用户在规则表里删掉后不能被启动流程复活。
//

import XCTest
@testable import RuleEngine
@testable import GestureEngine

final class ScreenshotRuleTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.ScreenshotRule"

    private func makeStore() -> (RuleStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        store.rules = []
        store.save()
        return (store, url)
    }

    private func isolatedSuite() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }

    override func tearDown() {
        isolatedSuite().removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // MARK: - 规则本体

    func testScreenshotRuleIsAGlobalOneWithNoGestureNote() {
        let rule = RuleStore.screenshotRule()
        XCTAssertEqual(rule.name, RuleStore.screenshotRuleName)
        XCTAssertEqual(rule.filter, "*", "截图不该按应用过滤：任何前台都要能画 S 出选区")
        XCTAssertEqual(rule.note, "", "遮罩摊开本身就是反馈，规则气泡会跟它抢")
        XCTAssertTrue(rule.isEnabled)
        guard case .screenshot = rule.action else { return XCTFail("动作必须是截图") }
        XCTAssertFalse(rule.template.points.isEmpty, "默认手势要有轨迹点，否则永远匹配不上")
        XCTAssertEqual(rule.template.points.map { "\($0.x):\($0.y)" },
                       PresetGesture.letterS.template.points.map { "\($0.x):\($0.y)" },
                       "默认手势就是 S 预设，用户在截图页看到的样子要等于实际生效的样子")
    }

    // MARK: - 原版字典 schema 里的第 5 类动作

    func testScreenshotActionPersistsAsActionTypeFour() throws {
        let data = try JSONEncoder().encode(RuleStore.screenshotRule())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["actionType"] as? Int, 4)
        // 原版只在动作类型用到 shortcut 时才写这两格；截图没有参数，写了会被
        // 老版本读成「快捷键动作 + keyCode 0」。
        XCTAssertNil(object["shortcut_code"])
        XCTAssertNil(object["shortcut_flag"])
        XCTAssertNil(object["apple_script_id"])

        let reloaded = try JSONDecoder().decode(Rule.self, from: data)
        guard case .screenshot = reloaded.action else { return XCTFail("读回来要还是截图动作") }
        XCTAssertEqual(reloaded.name, RuleStore.screenshotRuleName)
    }

    /// 切换 actionType 只改类型不换值（原版语义），所以一条从别的动作切过来的规则，
    /// 切回截图时 text/password 格子必须还填着。
    func testActionTypeFourKeepsTheOtherSlots() throws {
        let json = [
            "direction": "Screenshot",
            "data": [["x": 0.0, "y": 0.0]],
            "filter": "*",
            "filterType": 0,
            "actionType": 4,
            "text": "留着",
            "password": "12345678",
            "note": "",
        ] as [String: Any]

        let rule = try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: json))
        guard case .screenshot = rule.action else { return XCTFail("expected screenshot action") }
        XCTAssertEqual(rule.spareActions.text, "留着")
        XCTAssertEqual(rule.spareActions.password, "12345678")
    }

    func testUnknownActionTypeStillReadsAsShortcut() throws {
        // 老版本读到 4 会走 default 分支当成快捷键动作，新版读到没见过的号也不能崩。
        let json = [
            "direction": "x", "data": [["x": 0.0, "y": 0.0]], "filter": "*",
            "filterType": 0, "actionType": 9, "shortcut_code": 13, "shortcut_flag": 1048576,
        ] as [String: Any]
        let rule = try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: json))
        guard case .shortcut(let keyCode, let flags) = rule.action else {
            return XCTFail("未知动作类型要退到快捷键，不能解不开整份规则")
        }
        XCTAssertEqual(keyCode, 13)
        XCTAssertEqual(flags, 1048576)
    }

    // MARK: - 出厂列表与安装位置

    func testDefaultRulesEndWithTheScreenshotRule() {
        let rules = RuleStore.defaultRules()
        XCTAssertEqual(rules.last?.name, RuleStore.screenshotRuleName,
                       "截图规则要落在最后一行，原版那 15 条的位置一个都不能动")
        XCTAssertEqual(rules.filter { $0.name != RuleStore.screenshotRuleName }.count, 15)
        XCTAssertEqual(rules.filter { if case .screenshot = $0.action { return true }; return false }.count, 1,
                       "整份默认列表里只能有一条截图规则")
    }

    func testInstallAppendsOnceAndPersists() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(store.installScreenshotRule())
        XCTAssertFalse(store.installScreenshotRule(), "已经有了就不要再塞一条")
        XCTAssertEqual(store.rules.count, 1)

        let reloaded = RuleStore(storageURL: url)
        XCTAssertEqual(reloaded.rules.map(\.name), [RuleStore.screenshotRuleName])
    }

    func testInstallKeepsTheUserExistingRulesInPlace() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.rules = [
            Rule(name: "Back", description: "", template: GestureTemplate(points: [], name: "A Shape"),
                 action: .shortcut(keyCode: 123, flags: 1048576), note: ""),
        ]
        XCTAssertTrue(store.installScreenshotRule())
        XCTAssertEqual(store.rules.map(\.name), ["Back", RuleStore.screenshotRuleName],
                       "新增规则只能在末尾，用户的手势顺序是可见的优先级")
    }

    // MARK: - 一次性升级迁移

    func testUpgradeInstallsOnceAndNeverRevivesADeletedRule() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = isolatedSuite()
        defaults.removePersistentDomain(forName: Self.suiteName)
        // 另留一条用户规则：规则表整个空了 RuleStore 会按原版语义重灌默认列表，
        // 那跟迁移复活无关，会把判据搅浑。
        store.rules = [
            Rule(name: "Back", description: "", template: GestureTemplate(points: [], name: "A Shape"),
                 action: .shortcut(keyCode: 123, flags: 1048576), note: ""),
        ]

        XCTAssertTrue(store.installScreenshotRuleIfNeeded(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: "screenshotGestureRuleInstalled"),
                      "标记要先落库：这一轮没装成也不能下次再补装")

        // 用户把这条删了（规则表里删行 / 截图页点移除），重启后不能复活。
        store.remove(named: RuleStore.screenshotRuleName)
        store.save()
        let restarted = RuleStore(storageURL: url)
        XCTAssertFalse(restarted.installScreenshotRuleIfNeeded(defaults: defaults))
        XCTAssertNil(restarted.rule(named: RuleStore.screenshotRuleName))
        XCTAssertEqual(restarted.rules.map(\.name), ["Back"])
    }

    func testFreshInstallNeedsNoMarkerRoundTrip() throws {
        // 全新库里默认列表已经带这条规则，迁移再跑一次也只会被去重挡掉。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RuleStore(storageURL: url)
        let defaults = isolatedSuite()
        defaults.removePersistentDomain(forName: Self.suiteName)

        XCTAssertTrue(store.rules.contains { $0.name == RuleStore.screenshotRuleName })
        XCTAssertFalse(store.installScreenshotRuleIfNeeded(defaults: defaults))
        XCTAssertEqual(store.rules.filter { $0.name == RuleStore.screenshotRuleName }.count, 1)
    }

    // MARK: - 执行入口

    func testScreenshotActionRunsTheHookAndStaysSilentWithoutIt() {
        var fired = 0
        let executor = ActionExecutor()
        executor.execute(.screenshot)
        XCTAssertEqual(fired, 0, "App 层没挂入口时不能假装执行")

        executor.onScreenshotRequested = { fired += 1 }
        executor.execute(.screenshot, for: RuleStore.screenshotRule())
        XCTAssertEqual(fired, 1, "手势命中要立刻进遮罩，一次调用一次触发")
    }
}
