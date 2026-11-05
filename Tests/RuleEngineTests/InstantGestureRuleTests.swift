//
//  InstantGestureRuleTests.swift
//  MacStroke
//
//  issue #78 第 2 条：规则表里除了「画一笔」，还可以配「按住起始键 + 滚轮上/下」这种
//  不用画的瞬时手势。规则层是这件事的地基，所以判据分两头。
//
//  一头是**存的形状**：原版 rules.json 是一个字典数组，能占的只有键位。新键 `instant_gesture`
//  只在瞬时规则上出现，轨迹规则（含原版那 15 条）导出的 JSON 必须和改动前逐字节相同 ——
//  否则老版本读到我们的文件、或用户手抄一份新文件回滚，都会看到多出来的一格。
//  认不出的取值一律退成轨迹规则：让一条脏数据炸掉整份文件、连别人手势一起没，比这一条
//  退化严重得多。
//
//  另一头是**匹配的分寸**，四条各咬一种坏法：
//  - 方向串线：上滚命中下滚那条（下拉里换了档位，实际生效的是另一档）。
//  - 空模板撞高分：瞬时规则没有轨迹点，让它参与 DTW 打分，空模板会撞出一条「谁都不该中」
//    的命中，症状是画任意一笔都触发那条滚轮规则。
//  - 黑白名单只管一半：轨迹走 `BlackWhiteFilter`，滚轮也得走同一条，否则过滤页把某个软件
//    拉黑之后它还能被滚轮触发。
//  - 顺序：没有分数可比，按列表第一条（新规则插在顶上，所以「后配的赢」，与原版轨迹匹配
//    的「最高分赢」是两种口径，这里必须钉住用的是哪一种）。
//
import XCTest
@testable import RuleEngine
@testable import GestureEngine

final class InstantGestureRuleTests: XCTestCase {

    private var store: RuleStore!
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        store = RuleStore(storageURL: url)
        store.rules = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        store = nil
        super.tearDown()
    }

    // MARK: - 造规则

    private func wheelRule(_ gesture: InstantGesture,
                           name: String = "滚轮",
                           filter: String = "*",
                           filterType: String = "wildcard",
                           isEnabled: Bool = true) -> Rule {
        Rule(name: name, description: "", template: GestureTemplate(points: [], name: gesture.displayName),
             action: .shortcut(keyCode: 1, flags: 1048576), note: "", isEnabled: isEnabled,
             filter: filter, filterType: filterType, instantGesture: gesture)
    }

    /// 一条真的画过一笔的规则（20 点斜线，与 RuleEngineTests 同一份形状）。
    private func strokeRule(name: String = "斜线", points: [GesturePoint]? = nil) -> Rule {
        let dots = points ?? (0..<20).map { GesturePoint(x: Double($0) * 2, y: Double($0) * 2) }
        return Rule(name: name, description: "", template: GestureTemplate(points: dots, name: name),
                    minSimilarityScore: 50, action: .keyPress("d"), note: "", filter: "*")
    }

    private func diagonalStroke() -> Stroke {
        let stroke = Stroke(points: (0..<20).map { GesturePoint(x: Double($0) * 2, y: Double($0) * 2) })
        return stroke
    }

    /// 按键编号是捕获层与规则层之间的契约：接错一格就是「配中键、按侧键」。
    func testInstantGesturesCarryTheRightMouseButtonNumbers() {
        XCTAssertEqual(InstantGesture.middleClick.mouseButtonNumber, 2)
        XCTAssertEqual(InstantGesture.backClick.mouseButtonNumber, 3)
        XCTAssertEqual(InstantGesture.forwardClick.mouseButtonNumber, 4)
        XCTAssertNil(InstantGesture.wheelUp.mouseButtonNumber)
        XCTAssertNil(InstantGesture.wheelDown.mouseButtonNumber)
        XCTAssertTrue(InstantGesture.wheelUp.isWheel)
        XCTAssertFalse(InstantGesture.middleClick.isWheel)

        XCTAssertEqual(InstantGesture(mouseButtonNumber: 2), .middleClick)
        XCTAssertEqual(InstantGesture(mouseButtonNumber: 3), .backClick)
        XCTAssertEqual(InstantGesture(mouseButtonNumber: 4), .forwardClick)
        XCTAssertNil(InstantGesture(mouseButtonNumber: 0), "左键不参与瞬时手势")
        XCTAssertNil(InstantGesture(mouseButtonNumber: 5), "第 5 键没有对应档位，不能顺手当成前进")
    }

    // MARK: - 存的形状

    func testWheelRulesWriteTheirOwnKeyAndRoundTrip() throws {
        for gesture in InstantGesture.allCases {
            let data = try JSONEncoder().encode(wheelRule(gesture))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["instant_gesture"] as? String, gesture.rawValue,
                           "键名或取值不对：老版本/别的机器读不到这一档")

            let reloaded = try JSONDecoder().decode(Rule.self, from: data)
            XCTAssertEqual(reloaded.instantGesture, gesture, "读回来换了档：\(gesture)")
            XCTAssertEqual(reloaded.action, .shortcut(keyCode: 1, flags: 1048576))
            XCTAssertTrue(reloaded.template.points.isEmpty,
                          "瞬时规则不该有轨迹点；留着的话哪天键被手工删掉，那条没人认的笔画会静默复活")
        }
    }

    /// 轨迹规则导出的 JSON 里不许出现这一格 —— 原版那 15 条与用户手抄回滚的旧文件都靠这条兜底。
    func testStrokeRulesExportExactlyWhatTheyDidBefore() throws {
        let data = try JSONEncoder().encode(strokeRule())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(object?["data"], "轨迹点照常写：这一格不能被瞬时那套顺手接管")
        XCTAssertNil(object?["instant_gesture"], "普通规则多写一格，老版本读到就是一行看不懂的字段")

        let reloaded = try JSONDecoder().decode(Rule.self, from: data)
        XCTAssertNil(reloaded.instantGesture)
    }

    func testOldFileWithoutTheKeyIsStillAStrokeRule() throws {
        let json = [
            "direction": "Old", "data": [["x": 0.0, "y": 0.0]], "filter": "*",
            "filterType": 0, "actionType": 0, "shortcut_code": 4, "shortcut_flag": 1048576,
        ] as [String: Any]
        let rule = try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(rule.instantGesture, "3.2.3 及以前的 rules.json 没有这一格，读出来就是轨迹规则")
    }

    /// 认不出的值（手改文件 / 将来别处写的新档）退成轨迹规则，而不是把整份文件顶崩。
    func testUnknownInstantValueDegradesInsteadOfBreakingTheFile() throws {
        let json = [
            "direction": "Odd", "data": [["x": 0.0, "y": 0.0]], "filter": "*",
            "filterType": 0, "actionType": 0, "instant_gesture": "button9",
        ] as [String: Any]
        let rule = try JSONDecoder().decode(Rule.self,
                                           from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(rule.instantGesture)

        let engine = RuleEngine()
        engine.add(rule)
        XCTAssertNil(engine.match(instant: .wheelUp, bundleID: "com.example.app"),
                      "认不出的档位不能顺手当成上滚")
    }

    func testTheFactoryRuleListHasNoWheelRulesYet() {
        // 出厂 15+1 条全是轨迹规则：这一档要用户自己在面板里点，不能预装一条把他人的手势换掉。
        XCTAssertTrue(RuleStore.defaultRules().allSatisfy { $0.instantGesture == nil })
    }

    // MARK: - 匹配：方向与顺序

    func testWheelMatchingAnswersOnlyTheRequestedDirection() {
        let engine = RuleEngine()
        engine.add(wheelRule(.wheelDown, name: "下滚"))

        XCTAssertEqual(engine.match(instant: .wheelDown, bundleID: "com.example.app")?.name, "下滚")
        XCTAssertNil(engine.match(instant: .wheelUp, bundleID: "com.example.app"),
                     "上滚命中了下滚那条：下拉里换了档，实际投出去的却是另一档的动作")
    }

    func testWheelMatchingTakesTheFirstRuleInListOrder() {
        let engine = RuleEngine()
        // 规则表把新规则插在第 0 行，所以「列表第一条」= 用户最近配的那条；
        // 这里刻意先加 A 再加 B，钉住用的是顺序而不是「后加的覆盖先加的」。
        engine.add(wheelRule(.wheelUp, name: "A"))
        engine.add(wheelRule(.wheelUp, name: "B"))
        XCTAssertEqual(engine.match(instant: .wheelUp, bundleID: "com.example.app")?.name, "A")

        let reloaded = RuleEngine()
        reloaded.add(wheelRule(.wheelUp, name: "B"))
        reloaded.add(wheelRule(.wheelUp, name: "A"))
        XCTAssertEqual(reloaded.match(instant: .wheelUp, bundleID: "com.example.app")?.name, "B",
                       "同一个规则换个顺序结果就变了：那不是按列表取第一条")
    }

    func testDisabledWheelRuleDoesNotAnswer() {
        let engine = RuleEngine()
        engine.add(wheelRule(.wheelUp, name: "关着的", isEnabled: false))
        XCTAssertNil(engine.match(instant: .wheelUp, bundleID: "com.example.app"),
                     "行首取消勾选之后滚轮还在触发，用户没法只停一条")
    }

    func testStrokeRulesNeverAnswerAWheelQuery() {
        let engine = RuleEngine()
        engine.add(strokeRule())
        XCTAssertNil(engine.match(instant: .wheelUp, bundleID: "com.example.app"),
                      "轨迹规则被滚轮撞上了：老用户的手势会凭空多一个触发方式")
    }

    /// 反向那一手：瞬时规则的空模板一旦参与 DTW 打分，就可能撞出一条高分。
    /// 把滚轮那条排在前面，坏法是「画一笔斜线结果触发了滚轮规则的动作」。
    func testWheelRulesNeverAnswerAStrokeQuery() throws {
        let engine = RuleEngine()
        engine.add(wheelRule(.wheelUp, name: "滚轮那条"))
        engine.add(strokeRule(name: "斜线"))

        let hit = engine.match(stroke: diagonalStroke())
        XCTAssertEqual(hit?.rule.name, "斜线", "画的一笔该中轨迹规则")

        // 按 App 那一手要过黑白名单那扇门（本机是用户真配置），门开着才判得动。
        guard BlackWhiteFilter.shared.shouldHookMouseEventForApp("com.example.app") else {
            throw XCTSkip("本机过滤页把这家挡了（用户真配置），这一条只验得了无过滤那一半")
        }
        let byApp = engine.match(stroke: diagonalStroke(), bundleID: "com.example.app")
        XCTAssertEqual(byApp?.rule.name, "斜线", "瞬时规则答了轨迹查询，或干脆谁都没中")
    }

    // MARK: - 匹配：过滤

    func testWheelMatchingHonoursTheAppFilter() {
        let engine = RuleEngine()
        engine.add(wheelRule(.wheelUp, filter: "com.example.*"))

        XCTAssertNotNil(engine.match(instant: .wheelUp, bundleID: "com.example.app"))
        XCTAssertNil(engine.match(instant: .wheelUp, bundleID: "com.other.app"),
                     "按应用过滤对滚轮失效，等于这条规则变成全局的")

        let regexEngine = RuleEngine()
        regexEngine.add(wheelRule(.wheelDown, filter: "com\\.other\\.", filterType: "regex"))
        XCTAssertNotNil(regexEngine.match(instant: .wheelDown, bundleID: "com.other.app"),
                        "过滤页里正则那一档也要同样作用于滚轮")
        XCTAssertNil(regexEngine.match(instant: .wheelDown, bundleID: "com.example.app"))
    }

    /// 黑白名单是同一扇门：过滤页把某个软件拉黑之后，它的滚轮规则要和轨迹规则一起失效。
    ///
    /// 这里改的是 `UserDefaults.standard` 那两份名单（本机真配置），所以先把原值取出来、
    /// 用完原样写回，`defer` 保证断言失败也走得掉。用例只碰一个不可能撞车的假 bundle ID。
    func testWheelMatchingSharesTheBlackListGate() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: BlackWhiteFilter.whiteListModeKey)
        let savedBlack = defaults.stringArray(forKey: BlackWhiteFilter.blackListKey)
        defer {
            if let savedMode { defaults.set(savedMode, forKey: BlackWhiteFilter.whiteListModeKey) }
            else { defaults.removeObject(forKey: BlackWhiteFilter.whiteListModeKey) }
            if let savedBlack { defaults.set(savedBlack, forKey: BlackWhiteFilter.blackListKey) }
            else { defaults.removeObject(forKey: BlackWhiteFilter.blackListKey) }
        }
        defaults.set(false, forKey: BlackWhiteFilter.whiteListModeKey)
        BlackWhiteFilter.shared.blackListText = "com.qoder.blocked"

        let engine = RuleEngine()
        engine.add(wheelRule(.wheelUp))
        XCTAssertNil(engine.match(instant: .wheelUp, bundleID: "com.qoder.blocked"),
                     "黑名单只管轨迹不管滚轮：过滤页里看着拉黑了，滚轮照样触发")
        XCTAssertNotNil(engine.match(instant: .wheelUp, bundleID: "com.qoder.allowed"))
    }

    // MARK: - 匹配：中键/侧键

    /// 三档按键各答各的，不串到滚轮，也不串到别的键。
    func testClickGesturesMatchOnlyTheirOwnButton() {
        let engine = RuleEngine()
        engine.add(wheelRule(.middleClick, name: "中键"))
        engine.add(wheelRule(.backClick, name: "后退"))
        engine.add(wheelRule(.forwardClick, name: "前进"))
        engine.add(wheelRule(.wheelUp, name: "上滚"))

        XCTAssertEqual(engine.match(instant: .middleClick, bundleID: "com.example.app")?.name, "中键")
        XCTAssertEqual(engine.match(instant: .backClick, bundleID: "com.example.app")?.name, "后退")
        XCTAssertEqual(engine.match(instant: .forwardClick, bundleID: "com.example.app")?.name, "前进")
        XCTAssertEqual(engine.match(instant: .wheelUp, bundleID: "com.example.app")?.name, "上滚")
        XCTAssertNil(engine.match(instant: .wheelDown, bundleID: "com.example.app"),
                     "没配下滚却答了：按键档串到了滚轮那一头")
    }

    func testClickGesturesHonourTheSameFiltersAndDisabledFlag() {
        let engine = RuleEngine()
        engine.add(wheelRule(.middleClick, filter: "com.example.*"))
        engine.add(wheelRule(.backClick, name: "关着的", isEnabled: false))

        XCTAssertNotNil(engine.match(instant: .middleClick, bundleID: "com.example.app"))
        XCTAssertNil(engine.match(instant: .middleClick, bundleID: "com.other.app"),
                     "按应用过滤对中键失效，等于这条规则变成全局的")
        XCTAssertNil(engine.match(instant: .backClick, bundleID: "com.example.app"),
                     "行首取消勾选之后侧键还在触发")
    }

    // MARK: - 上膛条件

    func testHasWheelInstantRuleOnlyCountsEnabledWheelRules() {
        XCTAssertFalse(store.hasWheelInstantRule, "空库不用为滚轮花一次 tap Enable")

        store.rules = [strokeRule()]
        XCTAssertFalse(store.hasWheelInstantRule, "只有轨迹规则时不该把滚轮那只二级 tap 叫醒")

        store.rules = [wheelRule(.middleClick)]
        XCTAssertFalse(store.hasWheelInstantRule,
                       "只配了中键/侧键不该上膛滚轮 tap：它们走主 tap，上膛是白花一次往返")

        store.rules = [wheelRule(.wheelUp, isEnabled: false)]
        XCTAssertFalse(store.hasWheelInstantRule, "取消勾选的那条已经不算配了")

        store.rules = [strokeRule(), wheelRule(.wheelDown)]
        XCTAssertTrue(store.hasWheelInstantRule, "规则页配了滚轮就该上膛，不必再去「右键增强」补勾一次")
    }

    // MARK: - 起手键冲突

    /// 只有启用中的按键档才算冲突；滚轮档没有按键编号，永不与起手键冲突。
    func testConflictQueryOnlyCountsEnabledClickRulesOnThatButton() {
        store.rules = [
            wheelRule(.middleClick, name: "中键"),
            wheelRule(.backClick, name: "关着的后退", isEnabled: false),
            wheelRule(.wheelUp, name: "上滚"),
        ]

        XCTAssertEqual(store.instantGestureConflicting(withTriggerButton: 2), .middleClick)
        XCTAssertNil(store.instantGestureConflicting(withTriggerButton: 3),
                     "关着的那条不该提示冲突")
        XCTAssertNil(store.instantGestureConflicting(withTriggerButton: 1),
                     "右键没配瞬时档")
        XCTAssertNil(store.instantGestureConflicting(withTriggerButton: 4),
                     "前进键没配瞬时档")
    }

    func testClickRulesRoundTripThroughDiskToo() throws {
        store.rules = [wheelRule(.middleClick, name: "中键"),
                       wheelRule(.backClick, name: "后退"),
                       wheelRule(.forwardClick, name: "前进")]
        store.save()

        let reloaded = RuleStore(storageURL: url)
        XCTAssertEqual(reloaded.rules.compactMap(\.instantGesture),
                       [.middleClick, .backClick, .forwardClick],
                       "三档按键读回来换了位：侧键会按错方向")
        XCTAssertFalse(reloaded.hasWheelInstantRule,
                       "全是按键档却上膛了滚轮 tap")
    }

    func testStoreAnswersWithTheLiveList() {
        store.rules = [wheelRule(.wheelUp, name: "滚轮")]
        XCTAssertEqual(store.match(instant: .wheelUp, bundleID: "com.example.app")?.name, "滚轮")

        // 面板里点了「下滚」：档位换了以后马上就该按新的算，不能等重启。
        store.update(wheelRule(.wheelDown, name: "滚轮"))
        XCTAssertNil(store.match(instant: .wheelUp, bundleID: "com.example.app"),
                     "档位换了，上滚那一格还在答旧账")
        XCTAssertEqual(store.match(instant: .wheelDown, bundleID: "com.example.app")?.name, "滚轮")
    }

    func testStoreRoundTripsWheelRulesThroughDisk() throws {
        store.rules = [wheelRule(.wheelUp, name: "上滚"), strokeRule(name: "斜线")]
        store.save()

        let reloaded = RuleStore(storageURL: url)
        XCTAssertEqual(reloaded.rules.map(\.name), ["上滚", "斜线"], "顺序也是判据：列表顺序就是匹配优先级")
        XCTAssertEqual(reloaded.rules.first?.instantGesture, .wheelUp)
        XCTAssertNil(reloaded.rules.last?.instantGesture)
        XCTAssertTrue(reloaded.hasWheelInstantRule)
    }
}
