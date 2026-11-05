//
//  check.swift —— 桩件自证。
//
//  「桩件跑出来全绿」这件事本身需要证据：这里 15 条用例，8 条写法正确、
//  6 条**故意写反**、1 条**故意跳过**。跑出来必须正好「红 6 / 绿 8 / 跳过 1」，
//  少一条多一条都说明桩件在替用例撒谎（比如某条断言压根没被求值）。
//
//  跑法：`python3 tools/xctstub/xct.py selfcheck`
//

import Foundation
import XCTest

struct StubCheckError: Error {}

final class StubCheckGreen: XCTestCase {

    func testMarkersForTheSelfCheck() {
        print("EXPECT_FAILED 6")
        print("EXPECT_PASSED 8")
        print("EXPECT_SKIPPED 1")
    }

    func testEqualityHolds() {
        XCTAssertEqual(1 + 1, 2)
        XCTAssertEqual("a", "a")
        XCTAssertEqual([1, 2], [1, 2])
        XCTAssertNotEqual(1, 2)
    }

    func testTruthinessHolds() {
        XCTAssertTrue(2 > 1)
        XCTAssertFalse(2 < 1)
        XCTAssert(2 != 3)
    }

    func testNotNilHolds() {
        let value: Int? = 7
        XCTAssertNotNil(value)
    }

    func testNilHolds() {
        XCTAssertNil(nil as Int?)
    }

    func testComparisonsHold() {
        XCTAssertGreaterThan(5, 3)
        XCTAssertGreaterThanOrEqual(3, 3)
        XCTAssertLessThan(3, 5)
        XCTAssertLessThanOrEqual(3, 3)
        XCTAssertEqual(1.005, 1.0, accuracy: 0.01)
    }

    func testUnwrapReturnsTheValue() throws {
        let unwrapped = try XCTUnwrap("text" as String?)
        XCTAssertEqual(unwrapped.count, 4)
    }

    func testThrowsErrorHolds() {
        XCTAssertThrowsError(try { () throws -> Void in throw StubCheckError() }()) { error in
            XCTAssertTrue(error is StubCheckError)
        }
        XCTAssertNoThrow(try { () throws -> Void in }())
    }
}

/// 一条「跳过不算红」的用例：验 `try XCTSkip(...)` 冒泡到边界后记成 skipped。
final class StubCheckSkip: XCTestCase {

    func testSkipIsNotAFailure() throws {
        XCTAssertEqual(1, 1)
        throw XCTSkip("这条按设计跳过")
    }
}

/// 六条**故意写反**的：每一条都必须变红。
final class StubCheckRed: XCTestCase {

    func testRedEqual() {
        XCTAssertEqual(1, 2, "写反：相等判据")
    }

    func testRedTrue() {
        XCTAssertTrue(false, "写反：真值判据")
    }

    func testRedFalse() {
        XCTAssertFalse(true, "写反：假值判据")
    }

    func testRedNotNil() {
        XCTAssertNotNil(nil as Int?, "写反：非空判据")
    }

    func testRedOrdering() {
        XCTAssertGreaterThan(1, 9, "写反：大小判据")
    }

    func testRedUnwrapThrowsTheCase() throws {
        _ = try XCTUnwrap(nil as Int?, "写反：XCTUnwrap 拿到 nil，既要记红又要打断用例体")
        Stub.record("这行不该被执行到", file: #filePath, line: #line)
    }
}

_stubAdd("StubCheckGreen", StubCheckGreen.self, "testMarkersForTheSelfCheck") { t in t.testMarkersForTheSelfCheck() }
_stubAdd("StubCheckGreen", StubCheckGreen.self, "testEqualityHolds") { t in t.testEqualityHolds() }
_stubAdd("StubCheckGreen", StubCheckGreen.self, "testTruthinessHolds") { t in t.testTruthinessHolds() }
_stubAdd("StubCheckGreen", StubCheckGreen.self, "testNotNilHolds") { t in t.testNotNilHolds() }
_stubAdd("StubCheckGreen", StubCheckGreen.self, "testNilHolds") { t in t.testNilHolds() }
_stubAdd("StubCheckGreen", StubCheckGreen.self, "testComparisonsHold") { t in t.testComparisonsHold() }
_stubAdd("StubCheckGreen", StubCheckGreen.self, "testUnwrapReturnsTheValue") { t in try t.testUnwrapReturnsTheValue() }
_stubAdd("StubCheckGreen", StubCheckGreen.self, "testThrowsErrorHolds") { t in t.testThrowsErrorHolds() }

_stubAdd("StubCheckSkip", StubCheckSkip.self, "testSkipIsNotAFailure") { t in try t.testSkipIsNotAFailure() }

_stubAdd("StubCheckRed", StubCheckRed.self, "testRedEqual") { t in t.testRedEqual() }
_stubAdd("StubCheckRed", StubCheckRed.self, "testRedTrue") { t in t.testRedTrue() }
_stubAdd("StubCheckRed", StubCheckRed.self, "testRedFalse") { t in t.testRedFalse() }
_stubAdd("StubCheckRed", StubCheckRed.self, "testRedNotNil") { t in t.testRedNotNil() }
_stubAdd("StubCheckRed", StubCheckRed.self, "testRedOrdering") { t in t.testRedOrdering() }
_stubAdd("StubCheckRed", StubCheckRed.self, "testRedUnwrapThrowsTheCase") { t in try t.testRedUnwrapThrowsTheCase() }

exit(_stubRun())
