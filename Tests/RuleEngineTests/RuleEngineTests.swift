//
//  RuleEngineTests
//  MacStroke
//

import XCTest
@testable import RuleEngine
@testable import GestureEngine

final class RuleEngineTests: XCTestCase {

    func testRuleCreation() {
        let template = GestureTemplate(
            points: (0..<20).map { GesturePoint(x: Double($0), y: Double($0)) },
            name: "Test template"
        )

        let rule = Rule(
            name: "Test rule",
            description: "A test rule",
            template: template,
            minSimilarityScore: 50.0,
            action: .keyPress("space"),
            isEnabled: true
        )

        XCTAssertEqual(rule.name, "Test rule")
        XCTAssertEqual(rule.description, "A test rule")
        XCTAssertEqual(rule.template.name, "Test template")
        XCTAssertEqual(rule.template.points.count, 20)
        XCTAssertEqual(rule.minSimilarityScore, 50.0)
        XCTAssertTrue(rule.isEnabled)

        if case .keyPress(let key) = rule.action {
            XCTAssertEqual(key, "space")
        } else {
            XCTFail("Expected keyPress action")
        }
    }

    func testRuleEngineAddAndMatch() {
        let engine = RuleEngine()

        let points = (0..<20).map { i in
            GesturePoint(x: Double(i) * 2, y: Double(i) * 2)
        }
        let template = GestureTemplate(points: points, name: "Diagonal template")

        let rule = Rule(
            name: "Diagonal rule",
            description: "Matches diagonal strokes",
            template: template,
            minSimilarityScore: 80.0,
            action: .keyPress("d"),
            isEnabled: true
        )

        engine.add(rule)
        XCTAssertEqual(engine.enabledRuleCount, 1)

        // Create a matching stroke with enough points
        var stroke = Stroke()
        for i in 0..<20 {
            stroke.addPoint(GesturePoint(x: Double(i) * 2, y: Double(i) * 2))
        }
        stroke.normalize()

        // Test the rule engine
        let result = engine.match(stroke: stroke)
        XCTAssertNotNil(result)
        if let (matchedRule, matchedScore) = result {
            XCTAssertEqual(matchedRule.name, "Diagonal rule")
            XCTAssertGreaterThanOrEqual(matchedScore, 80.0)
        }
    }

    func testRuleEngineReturnsNilForNoMatch() {
        let engine = RuleEngine()

        // Create a template with enough points
        let template = GestureTemplate(
            points: (0..<20).map { GesturePoint(x: Double($0), y: Double($0)) },
            name: "Diagonal template"
        )

        let rule = Rule(
            name: "Diagonal rule",
            description: "Matches diagonal strokes",
            template: template,
            minSimilarityScore: 80.0,
            action: .applescript("display dialog \"test\""),
            isEnabled: true
        )

        engine.add(rule)

        // Create a perpendicular stroke that should NOT match
        var stroke = Stroke()
        for i in 0..<20 {
            stroke.addPoint(GesturePoint(x: Double(i), y: Double(19 - i)))
        }
        stroke.normalize()

        let result = engine.match(stroke: stroke)
        // Perpendicular strokes should score lower than 80
        // But since the template IS the diagonal and the stroke IS perpendicular,
        // the match should fail
        XCTAssertNil(result)
    }

    func testDisabledRuleIsNotMatched() {
        let engine = RuleEngine()

        let template = GestureTemplate(
            points: (0..<20).map { GesturePoint(x: Double($0), y: Double($0)) },
            name: "Diagonal template"
        )

        let rule = Rule(
            name: "Disabled rule",
            description: "This rule is disabled",
            template: template,
            minSimilarityScore: 10.0,
            action: .keyPress("a"),
            isEnabled: false  // Disabled
        )

        engine.add(rule)
        XCTAssertEqual(engine.enabledRuleCount, 0)

        var stroke = Stroke()
        for i in 0..<20 {
            stroke.addPoint(GesturePoint(x: Double(i), y: Double(i)))
        }
        stroke.normalize()

        let result = engine.match(stroke: stroke)
        XCTAssertNil(result)
    }

    func testRuleEngineExecuteAction() {
        let engine = RuleEngine()

        let template = GestureTemplate(
            points: (0..<20).map { GesturePoint(x: Double($0), y: Double($0)) },
            name: "Diagonal template"
        )

        let rule = Rule(
            name: "Test rule",
            description: "Test action execution",
            template: template,
            minSimilarityScore: 30.0,
            action: .applescript("display dialog \"Hello\""),
            isEnabled: true
        )

        engine.add(rule)

        var stroke = Stroke()
        for i in 0..<20 {
            stroke.addPoint(GesturePoint(x: Double(i), y: Double(i)))
        }
        stroke.normalize()

        let action = engine.executeAction(for: stroke)
        XCTAssertNotNil(action)

        if case .applescript(let script) = action {
            XCTAssertEqual(script, "display dialog \"Hello\"")
        } else {
            XCTFail("Expected applescript action")
        }
    }

    // MARK: - Original LIKE filter semantics (utils.m wildcardArray)

    func testWildcardLikePatternsAreAnchored() {
        XCTAssertTrue(wildcardLikeMatch("com.apple.mail", "com.apple.*"))
        XCTAssertFalse(wildcardLikeMatch("com.apple.mail", "com.apple"))
        XCTAssertFalse(wildcardLikeMatch("xcom.apple", "com.apple"))
        XCTAssertTrue(wildcardLikeMatch("com.apple.mail", "com.*.mail"))
        XCTAssertTrue(wildcardLikeMatch("com.apple.dt.xcode", "com.*.dt.*"))
        // `?` is exactly one character, unlike the previous substring matcher.
        XCTAssertTrue(wildcardLikeMatch("com.apple.mail", "com.apple.mai?"))
        XCTAssertFalse(wildcardLikeMatch("com.apple.mail", "com.apple.mail?"))
        XCTAssertTrue(wildcardLikeMatch("", ""))
        XCTAssertFalse(wildcardLikeMatch("com.apple.mail", ""))
        XCTAssertTrue(wildcardLikeMatch("com.apple.mail", "*"))
    }

    func testWildcardFilterIgnoresCaseButKeepsWhitespace() {
        XCTAssertTrue(wildcardArray("Com.Apple.Mail", patterns: ["com.apple.*"], ignoreCase: true))
        // Original lowercases both sides and never trims the patterns.
        XCTAssertFalse(wildcardArray("com.apple.mail", patterns: [" com.apple.*"], ignoreCase: true))
        XCTAssertTrue(wildcardString("com.apple.mail", patterns: "com.other.*|com.apple.*", ignoreCase: true))
        XCTAssertTrue(wildcardString("com.apple.mail", patterns: "com.other.*\ncom.apple.*", ignoreCase: true))
    }

    private func ruleWithFilter(_ filter: String, filterType: String = "wildcard") -> Rule {
        Rule(
            name: "Filter rule",
            description: "",
            template: GestureTemplate(points: [GesturePoint(x: 0, y: 0)], name: "A Shape"),
            action: .text("x"),
            filter: filter,
            filterType: filterType
        )
    }

    private func engine(withFilter filter: String, filterType: String = "wildcard") -> RuleEngine {
        let engine = RuleEngine()
        engine.add(ruleWithFilter(filter, filterType: filterType))
        return engine
    }

    func testEmptyFilterMatchesNothing() {
        // Original quirk: an empty filter is evaluated as `LIKE ""`, so the rule
        // never fires (the old Swift code treated it as "all apps").
        XCTAssertFalse(engine(withFilter: "").appSuitedRule(bundleID: "com.apple.mail"))
    }

    func testRegexFilterIsCaseSensitiveSubstring() {
        XCTAssertTrue(engine(withFilter: "apple\\.ma", filterType: "regex").appSuitedRule(bundleID: "com.apple.mail"))
        XCTAssertFalse(engine(withFilter: "APPLE", filterType: "regex").appSuitedRule(bundleID: "com.apple.mail"))
        XCTAssertFalse(engine(withFilter: "(", filterType: "regex").appSuitedRule(bundleID: "com.apple.mail"))
    }

    // MARK: - Action field round trip (original keeps every payload)

    func testActionTypeChangeKeepsOtherFields() throws {
        let json = [
            "direction": "Email",
            "data": [["x": 0.0, "y": 0.0]],
            "filter": "*",
            "filterType": 0,
            "actionType": 2,
            "text": "hi@example.com",
            "password": "12345678",
            "shortcut_code": 13,
            "shortcut_flag": 1048576,
            "note": "input e-mail",
        ] as [String: Any]

        let rule = try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: json))
        guard case .text(let value) = rule.action else { return XCTFail("expected text action") }
        XCTAssertEqual(value, "hi@example.com")
        XCTAssertEqual(rule.spareActions.password, "12345678")
        XCTAssertEqual(rule.spareActions.shortcutCode, 13)
        XCTAssertEqual(rule.spareActions.shortcutFlag, 1048576)

        // Switching the action type only rewrites actionType, like the original.
        let switched = Rule(
            name: rule.name,
            description: rule.description,
            template: rule.template,
            action: .password(rule.spareActions.password),
            filter: rule.filter,
            filterType: rule.filterType,
            spareActions: rule.spareActions
        )
        let data = try JSONEncoder().encode(switched)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["actionType"] as? Int, 3)
        XCTAssertEqual(object["text"] as? String, "hi@example.com")
        XCTAssertEqual(object["password"] as? String, "12345678")
        // Original only writes the shortcut keys for the shortcut action type.
        XCTAssertNil(object["shortcut_code"])
        XCTAssertNil(object["apple_script_id"])
    }

    func testShortcutActionWritesShortcutKeysOnly() throws {
        let rule = Rule(
            name: "Back",
            description: "",
            template: GestureTemplate(points: [GesturePoint(x: 0, y: 0)], name: "A Shape"),
            action: .shortcut(keyCode: 123, flags: 1048576),
            spareActions: RuleSpareActions(appleScriptId: "SCRIPT-UUID")
        )
        let data = try JSONEncoder().encode(rule)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["actionType"] as? Int, 0)
        XCTAssertEqual(object["shortcut_code"] as? Int, 123)
        XCTAssertEqual(object["shortcut_flag"] as? Int, 1048576)
        XCTAssertNil(object["apple_script_id"])
    }

    /// 原版把四类动作的值各存一个字段，切换 actionType 只改类型、不换值，所以
    /// 「当前执行的动作」必然等于它自己那一格。代码内构造的 Rule（默认规则、预设
    /// 手势）只给了 action，不同步进格子的话，偏好页里把类型切走再切回来就把值丢了。
    func testProgrammaticActionSeedsItsOwnSlot() {
        func built(_ action: RuleAction) -> Rule {
            Rule(name: "x", description: "",
                 template: GestureTemplate(points: [], name: "x"), action: action)
        }
        XCTAssertEqual(built(.text("原文")).spareActions.text, "原文")
        XCTAssertEqual(built(.password("12345678")).spareActions.password, "12345678")
        XCTAssertEqual(built(.applescript("SCRIPT-UUID")).spareActions.appleScriptId, "SCRIPT-UUID")
        let shortcut = built(.shortcut(keyCode: 123, flags: 1048576))
        XCTAssertEqual(shortcut.spareActions.shortcutCode, 123)
        XCTAssertEqual(shortcut.spareActions.shortcutFlag, 1048576)
        // 显式给出的其他格子不能被当前动作覆盖。
        let explicit = Rule(name: "x", description: "",
                            template: GestureTemplate(points: [], name: "x"),
                            action: .text("原文"),
                            spareActions: RuleSpareActions(password: "留着"))
        XCTAssertEqual(explicit.spareActions.password, "留着")
    }

    /// 出厂默认规则是用户最先会在规则页切类型的对象，值必须在格子里。
    func testDefaultRulesCarryTheirActionValuesInSlots() {
        let rules = RuleStore.defaultRules()
        let password = rules.first { $0.name == "password" }
        XCTAssertEqual(password?.spareActions.password, "12345678")
        let textRules = rules.filter { if case .text = $0.action { return true }; return false }
        XCTAssertTrue(textRules.allSatisfy { !$0.spareActions.text.isEmpty },
                      "文本类默认规则的 text 格子要有值")
    }

    func testDefaultRulesUseOriginalLowercasePasswordDirection() {
        let names = RuleStore.defaultRules().map { $0.name }
        XCTAssertTrue(names.contains("password"))
        XCTAssertFalse(names.contains("Password"))
    }
}
