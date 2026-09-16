//
//  StrokeTests
//  MacStroke
//

import XCTest
@testable import GestureEngine

final class StrokeTests: XCTestCase {

    func testInit_Capacity() {
        var s = Stroke(capacity: 10)
        XCTAssertEqual(s.capacity, 10)
        XCTAssertTrue(s.points.isEmpty)
    }

    func testInit_DefaultCapacity() {
        var s = Stroke()
        XCTAssertGreaterThan(s.capacity, 0)
        XCTAssertTrue(s.points.isEmpty)
    }

    func testInit_WithPoints() {
        var s = Stroke(points: [
            GesturePoint(x: 0, y: 0),
            GesturePoint(x: 10, y: 10)
        ])
        XCTAssertEqual(s.count, 2)
    }

    func testAddPoint_WithinCapacity() {
        var s = Stroke(capacity: 5)
        let added = s.addPoint(GesturePoint(x: 1, y: 1))
        XCTAssertTrue(added)
        XCTAssertEqual(s.count, 1)
    }

    func testAddPoint_ExceedsCapacity() {
        var s = Stroke(capacity: 2)
        _ = s.addPoint(GesturePoint(x: 1, y: 1))
        _ = s.addPoint(GesturePoint(x: 2, y: 2))
        // Third should fail
        let added = s.addPoint(GesturePoint(x: 3, y: 3))
        XCTAssertFalse(added)
        XCTAssertEqual(s.count, 2)
    }

    func testAddPoints() {
        var s = Stroke(capacity: 10)
        s.addPoints([
            GesturePoint(x: 1, y: 1),
            GesturePoint(x: 2, y: 2),
            GesturePoint(x: 3, y: 3)
        ])
        XCTAssertEqual(s.count, 3)
    }

    func testNormalize_SinglePoint() {
        var s = Stroke(points: [GesturePoint(x: 5, y: 5)])
        s.normalize()
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.points[0].x, 0.5)
        XCTAssertEqual(s.points[0].y, 0.5)
    }

    func testNormalize_MultiplePoints() {
        var s = Stroke(points: [
            GesturePoint(x: 0, y: 0),
            GesturePoint(x: 10, y: 0),
            GesturePoint(x: 10, y: 10),
            GesturePoint(x: 0, y: 10)
        ])
        s.normalize()
        XCTAssertGreaterThan(s.count, 0)
        // After normalization all points should be in [0,1]²
        for p in s.points {
            XCTAssertGreaterThanOrEqual(p.x, 0)
            XCTAssertLessThanOrEqual(p.x, 1)
            XCTAssertGreaterThanOrEqual(p.y, 0)
            XCTAssertLessThanOrEqual(p.y, 1)
        }
    }

    func testNormalize_CodableRoundTrip() throws {
        var s = Stroke(points: [
            GesturePoint(x: 0, y: 0),
            GesturePoint(x: 10, y: 5),
            GesturePoint(x: 10, y: 10)
        ])
        s.normalize()
        let encoded = try JSONEncoder().encode(s)
        var decoded = try JSONDecoder().decode(Stroke.self, from: encoded)
        decoded.normalize()
        // After second normalize, points should still be in [0,1]²
        for p in decoded.points {
            XCTAssertGreaterThanOrEqual(p.x, 0)
            XCTAssertLessThanOrEqual(p.x, 1)
            XCTAssertGreaterThanOrEqual(p.y, 0)
            XCTAssertLessThanOrEqual(p.y, 1)
        }
    }

    func testNormalize_IdenticalPoints() {
        var s = Stroke(points: [
            GesturePoint(x: 5, y: 5),
            GesturePoint(x: 5, y: 5),
            GesturePoint(x: 5, y: 5)
        ])
        s.normalize()
        XCTAssertEqual(s.count, 3)
    }
}