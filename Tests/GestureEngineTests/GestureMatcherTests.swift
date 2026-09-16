//
//  GestureMatcherTests
//  MacStroke
//

import XCTest
@testable import GestureEngine

final class GestureMatcherTests: XCTestCase {

    func testCompare_FewerThan10Points() {
        // Template: 5 points
        var template = Stroke(capacity: 10)
        for i in 0..<5 {
            template.addPoint(GesturePoint(x: Double(i), y: Double(i)))
        }

        // Candidate: 8 points
        var candidate = Stroke(capacity: 10)
        for i in 0..<8 {
            candidate.addPoint(GesturePoint(x: Double(i), y: Double(i)))
        }

        let score = compare(template: template, candidate: candidate)
        XCTAssertEqual(score, 0.0)
    }

    func testCompare_IdenticalStrokes() {
        let numPoints = 20
        var template = Stroke(capacity: numPoints)
        var candidate = Stroke(capacity: numPoints)

        for i in 0..<numPoints {
            template.addPoint(GesturePoint(x: Double(i), y: Double(i)))
            candidate.addPoint(GesturePoint(x: Double(i), y: Double(i)))
        }

        let score = compare(template: template, candidate: candidate)
        // Identical normalized strokes should score close to 100
        XCTAssertGreaterThan(score, 95)
    }

    func testCompare_ReversedStrokes() {
        let numPoints = 20
        var template = Stroke(capacity: numPoints)
        var candidate = Stroke(capacity: numPoints)

        for i in 0..<numPoints {
            template.addPoint(GesturePoint(x: Double(i), y: Double(i)))
            // Reverse the candidate
            candidate.addPoint(GesturePoint(x: Double(numPoints - 1 - i), y: Double(numPoints - 1 - i)))
        }

        let score = compare(template: template, candidate: candidate)
        // Reversed should still have some similarity but less than identical
        XCTAssertGreaterThanOrEqual(score, 0)
        XCTAssertLessThan(score, 100)
    }

    func testCompare_ClosedShape() {
        // A circle-like shape (many points)
        let numPoints = 50
        var template = Stroke(capacity: numPoints)
        var candidate = Stroke(capacity: numPoints)

        for i in 0..<numPoints {
            let angle = Double(i) * 2 * .pi / Double(numPoints)
            template.addPoint(GesturePoint(x: cos(angle) * 50 + 50, y: sin(angle) * 50 + 50))
            candidate.addPoint(GesturePoint(x: cos(angle) * 50 + 50, y: sin(angle) * 50 + 50))
        }

        let score = compare(template: template, candidate: candidate)
        // Same shape should score high
        XCTAssertGreaterThan(score, 70)
    }

    func testCompare_DifferentShapes() {
        let numPoints = 30
        var template = Stroke(capacity: numPoints)
        var candidate = Stroke(capacity: numPoints)

        // Template: diagonal line
        for i in 0..<numPoints {
            template.addPoint(GesturePoint(x: Double(i), y: Double(i)))
        }

        // Candidate: anti-diagonal line
        for i in 0..<numPoints {
            candidate.addPoint(GesturePoint(x: Double(i), y: Double(numPoints - 1 - i)))
        }

        let score = compare(template: template, candidate: candidate)
        // Perpendicular should score low
        XCTAssertLessThan(score, 30)
    }

    func testCompare_CodableRoundTrip() throws {
        let numPoints = 20
        var template = Stroke(capacity: numPoints)
        for i in 0..<numPoints {
            template.addPoint(GesturePoint(x: Double(i), y: Double(i) * 0.5))
        }

        let encoded = try JSONEncoder().encode(template)
        var decoded = try JSONDecoder().decode(Stroke.self, from: encoded)

        let score = compare(template: template, candidate: decoded)
        XCTAssertGreaterThan(score, 50)
    }
}