//
//  GesturePointTests
//  MacStroke
//

import XCTest
@testable import GestureEngine

final class GesturePointTests: XCTestCase {

    func testInit() {
        let p = GesturePoint(x: 100, y: 200)
        XCTAssertEqual(p.x, 100)
        XCTAssertEqual(p.y, 200)
    }

    func testInitDefaults() {
        let p = GesturePoint(x: 0, y: 0)
        XCTAssertEqual(p.x, 0)
        XCTAssertEqual(p.y, 0)
        XCTAssertEqual(p.t, 0)
        XCTAssertEqual(p.dt, 0)
        XCTAssertEqual(p.alpha, 0)
    }

    func testEquatable() {
        let p1 = GesturePoint(x: 10, y: 20)
        let p2 = GesturePoint(x: 10, y: 20)
        let p3 = GesturePoint(x: 20, y: 30)
        XCTAssertEqual(p1, p2)
        XCTAssertNotEqual(p1, p3)
    }

    func testCodable() throws {
        let p = GesturePoint(x: 50, y: 75)
        let encoded = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(GesturePoint.self, from: encoded)
        XCTAssertEqual(decoded.x, 50)
        XCTAssertEqual(decoded.y, 75)
    }
}