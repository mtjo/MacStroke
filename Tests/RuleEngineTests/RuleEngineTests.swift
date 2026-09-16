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
}