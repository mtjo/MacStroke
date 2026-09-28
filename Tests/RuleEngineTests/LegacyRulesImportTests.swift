// 升级找回（issue #67）：3.0 把规则从 UserDefaults["rules"] 的 NSKeyedArchiver
// 归档搬到了 rules.json，只读文件的那条路会让 2.x 用户的手势凭空消失。这里覆盖
// 归档解码，以及"什么时候才允许覆盖现有规则"的判据。
import XCTest
@testable import RuleEngine
import GestureEngine

@available(macOS 13.0, *)
final class LegacyRulesImportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var storeURL: URL!
    private var suiteName: String { "LegacyRulesImportTests-\(UUID().uuidString)" }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    /// 原版 `addRuleWithDirection:` 写出的那条字典：`data` 是 NSValue 包的 NSPoint
    /// 数组，其余是 NSNumber / NSString。
    private func legacyRuleDictionary(
        direction: String = "Back",
        points: [NSPoint] = [NSPoint(x: 10, y: 20), NSPoint(x: 30, y: 40)],
        filter: String = "*",
        filterType: Int = 0,
        actionType: Int = 0,
        text: String = "",
        password: String = "",
        scriptID: String? = nil,
        shortcutCode: Int = 123,
        shortcutFlag: Int = 1_048_576,
        note: String = "Back",
        triggerOnEveryMatch: Bool = false,
        omitDirection: Bool = false
    ) -> NSMutableDictionary {
        let rule = NSMutableDictionary()
        if !omitDirection { rule["direction"] = direction }
        rule["data"] = points.map { NSValue(point: $0) }
        rule["filter"] = filter
        rule["filterType"] = filterType
        rule["actionType"] = actionType
        rule["text"] = text
        rule["password"] = password
        if let scriptID { rule["apple_script_id"] = scriptID }
        rule["shortcut_code"] = shortcutCode
        rule["shortcut_flag"] = shortcutFlag
        rule["note"] = note
        rule["trigger_on_every_match"] = triggerOnEveryMatch
        return rule
    }

    /// 旧版落库方式：整条 NSMutableArray 归档成 NSData 塞进 UserDefaults["rules"]。
    private func archive(_ rules: [Any]) -> Data {
        let list = NSMutableArray(array: rules)
        return try! NSKeyedArchiver.archivedData(withRootObject: list, requiringSecureCoding: false)
    }

    private func makeStore(seedRules: [Rule]? = nil) -> RuleStore {
        let store = RuleStore(storageURL: storeURL)
        if let seedRules {
            store.rules = seedRules
            store.save()
        }
        return store
    }

    private func rule(named name: String) -> Rule {
        Rule(
            name: name,
            description: name,
            template: GestureTemplate(points: [], name: name),
            action: .text("x"),
            note: name
        )
    }

    // MARK: - Archive decoding

    func testArchivedRuleDecodesIntoStoreSchema() throws {
        let data = archive([legacyRuleDictionary()])

        let rules = try XCTUnwrap(RuleStore.rules(fromLegacyArchive: data))

        XCTAssertEqual(rules.count, 1)
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.name, "Back")
        XCTAssertEqual(rule.note, "Back")
        XCTAssertEqual(rule.description, "Back")
        XCTAssertEqual(rule.filter, "*")
        XCTAssertEqual(rule.filterType, "wildcard")
        XCTAssertEqual(rule.action, .shortcut(keyCode: 123, flags: 1_048_576))
        XCTAssertEqual(rule.template.points.map(\.x), [10, 30])
        XCTAssertEqual(rule.template.points.map(\.y), [20, 40])
    }

    func testRegexFilterAndActionPayloadsArePreserved() throws {
        let data = archive([
            legacyRuleDictionary(filter: "^com\\.apple\\.Safari$", filterType: 1, actionType: 2,
                                 text: "mtjo.net@gmail.com"),
            legacyRuleDictionary(direction: "Code", actionType: 3, password: "12345678"),
        ])

        let rules = try XCTUnwrap(RuleStore.rules(fromLegacyArchive: data))

        XCTAssertEqual(rules.map(\.filterType), ["regex", "wildcard"])
        XCTAssertEqual(rules[0].action, .text("mtjo.net@gmail.com"))
        XCTAssertEqual(rules[1].action, .password("12345678"))
        // 快捷键值是每条规则都挂着的备用值，换动作类型时不能丢。
        XCTAssertEqual(rules[0].spareActions.shortcutCode, 123)
        XCTAssertEqual(rules[0].spareActions.shortcutFlag, 1_048_576)
    }

    func testTriggerOnEveryMatchRoundTrips() throws {
        let data = archive([legacyRuleDictionary(triggerOnEveryMatch: true)])

        let rules = try XCTUnwrap(RuleStore.rules(fromLegacyArchive: data))

        XCTAssertTrue(try XCTUnwrap(rules.first).triggerOnEveryMatch)
    }

    /// 旧版「+」按钮新增的规则 gestureData 是 nil（`data` 键直接不存在），
    /// 这类行要落成空轨迹，界面才会继续显示"绘制手势"占位。
    func testRuleWithoutGestureImportsWithEmptyTemplate() throws {
        let data = archive([legacyRuleDictionary(points: [])])

        let rules = try XCTUnwrap(RuleStore.rules(fromLegacyArchive: data))

        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(try XCTUnwrap(rules.first).template.points.isEmpty)
    }

    func testUnreadableRowIsSkippedWithoutDroppingTheList() throws {
        let data = archive([
            legacyRuleDictionary(omitDirection: true),
            legacyRuleDictionary(direction: "Next"),
        ])

        let rules = try XCTUnwrap(RuleStore.rules(fromLegacyArchive: data))

        XCTAssertEqual(rules.map(\.name), ["Next"])
    }

    func testAppleScriptIDIsRewrittenByTheResolver() throws {
        let data = archive([legacyRuleDictionary(direction: "Run", actionType: 1,
                                                 scriptID: "MacStroke-1234-5678")])
        let newID = UUID().uuidString

        let rules = try XCTUnwrap(
            RuleStore.rules(fromLegacyArchive: data, appleScriptID: { _ in newID })
        )

        XCTAssertEqual(try XCTUnwrap(rules.first).action, .applescript(newID))
    }

    func testNonRuleArchiveIsRejected() throws {
        let data = try! NSKeyedArchiver.archivedData(withRootObject: ["not": "rules"],
                                                    requiringSecureCoding: false)

        XCTAssertNil(RuleStore.rules(fromLegacyArchive: data))
    }

    // MARK: - When the import may run

    func testArchivedRulesReplaceThePresetFileOnAnUpgradedMachine() throws {
        defaults.set(archive([legacyRuleDictionary(direction: "Back")]), forKey: "rules")
        let store = makeStore(seedRules: RuleStore.defaultRules())

        XCTAssertTrue(store.importLegacyRulesIfNeeded(defaults: defaults, appleScriptID: { $0 }))
        XCTAssertEqual(store.rules.map(\.name), ["Back"])
        XCTAssertTrue(defaults.bool(forKey: "legacyRulesImported"))
        XCTAssertNil(defaults.object(forKey: "rules"))
    }

    func testImportIsSkippedWhenTheUserAlreadyEditedRules() throws {
        defaults.set(archive([legacyRuleDictionary(direction: "Back")]), forKey: "rules")
        let edited = [rule(named: "Mine")]
        let store = makeStore(seedRules: edited)

        XCTAssertFalse(store.importLegacyRulesIfNeeded(defaults: defaults, appleScriptID: { $0 }))
        XCTAssertEqual(store.rules.map(\.name), ["Mine"])
        XCTAssertFalse(defaults.bool(forKey: "legacyRulesImported"))
        // 不导入就得留着归档，用户还能自己找回。
        XCTAssertNotNil(defaults.object(forKey: "rules"))
    }

    func testImportRunsOnlyOnce() throws {
        let archive = archive([legacyRuleDictionary(direction: "Back")])
        defaults.set(archive, forKey: "rules")
        let store = makeStore()
        XCTAssertTrue(store.importLegacyRulesIfNeeded(defaults: defaults, appleScriptID: { $0 }))

        // 清掉规则后归档又回来了（例如再次导入了旧 plist）：只有标记能挡住复活。
        store.rules = []
        store.save()
        defaults.set(archive, forKey: "rules")

        XCTAssertFalse(store.importLegacyRulesIfNeeded(defaults: defaults, appleScriptID: { $0 }))
        XCTAssertTrue(store.rules.isEmpty)
    }

    /// 「导入」按钮是用户明确要恢复旧备份，这时即使当前规则是改过的也要覆盖。
    func testForceImportOverridesEditedRules() throws {
        defaults.set(archive([legacyRuleDictionary(direction: "Back")]), forKey: "rules")
        let store = makeStore(seedRules: [rule(named: "Mine")])

        XCTAssertTrue(store.importLegacyRulesIfNeeded(defaults: defaults,
                                                      appleScriptID: { $0 },
                                                      force: true))
        XCTAssertEqual(store.rules.map(\.name), ["Back"])
    }

    func testImportWithoutArchiveLeavesStoreAlone() throws {
        let store = makeStore(seedRules: [rule(named: "Mine")])

        XCTAssertFalse(store.importLegacyRulesIfNeeded(defaults: defaults, appleScriptID: { $0 }))
        XCTAssertEqual(store.rules.map(\.name), ["Mine"])
    }

    func testImportedRulesArePersistedAndReloadSame() throws {
        defaults.set(archive([
            legacyRuleDictionary(direction: "Back"),
            legacyRuleDictionary(direction: "Back"),
            legacyRuleDictionary(direction: "Next"),
        ]), forKey: "rules")
        let store = makeStore()

        XCTAssertTrue(store.importLegacyRulesIfNeeded(defaults: defaults, appleScriptID: { $0 }))
        // 旧版按行号寻址，同名规则合法；本版本按名字找规则，所以后来的要改名。
        XCTAssertEqual(store.rules.map(\.name), ["Back", "Back (2)", "Next"])

        let reloaded = RuleStore(storageURL: storeURL)
        XCTAssertEqual(reloaded.rules.map(\.name), store.rules.map(\.name))
    }
}
