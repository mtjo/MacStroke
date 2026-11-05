//
//  XCTestStub.swift — 本机 CommandLineTools 不带 XCTest（2026-10-22 起），
//  `swift test` 跑不了。这一份复刻仓库用例实际用到的 `XCTAssert*` / `XCTestCase`
//  / `XCTestExpectation` / `XCTWaiter` 签名，让 **仓库里未改动的用例文件** 能直接
//  编进一个可执行文件跑起来。
//
//  语义对齐：
//  - 断言失败记录一条红，**用例继续往下跑**（真 XCTest 就是这个行为）。
//  - `XCTUnwrap` / `XCTSkip` 是 throwing 的，红/跳过以错误形式冒泡到用例边界。
//  - 每个用例一个新实例，跑 `setUp` → `setUpWithError` → 方法体 → `tearDown` →
//    `tearDownWithError`；用例体里再往外抛的错误算红。
//  - `wait(for:)` 靠排空主线程 run loop 实现，因此用例必须在主线程跑（生成的 main 就是）。
//
//  桩件本身由 `check.swift` 自证：故意写反的必须全红、写对的必须全绿。
//

// 真 XCTest 会让 `import XCTest` 的客户端直接拿到 Foundation（仓库里不少用例
// 只 import XCTest 就用了 `JSONEncoder` / `sin`），所以这里同样导出一份。
@_exported import Foundation

// MARK: - 记账

/// 一次「红」：断言失败、用例抛错或用例超时。
public struct StubIssue {
    public let test: String
    public let file: StaticString
    public let line: UInt
    public let message: String
}

/// 桩件的全局状态。用例之间不并行（主线程逐个跑），不需要锁。
public enum Stub {
    public internal(set) static var current = "<none>"
    public internal(set) static var issues: [StubIssue] = []
    public internal(set) static var skipped: [(test: String, reason: String)] = []
    public internal(set) static var ran = 0

    public static func record(_ message: String, file: StaticString, line: UInt) {
        issues.append(StubIssue(test: current, file: file, line: line, message: message))
    }

    static func describe(_ value: Any?) -> String {
        if let value { return String(describing: value) }
        return "nil"
    }
}

/// `try XCTSkip(...)` 抛的就是它；用例边界认出来算「跳过」，不算红。
public struct StubSkip: Error {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// 用例体内没被 catch 的错误，一律算红（真 XCTest 也是 failed）。
struct StubThrown: Error {
    let error: Error
}

// MARK: - XCTestCase

open class XCTestCase {

    /// `required` 是给跑具的：它只拿着 `S.Type` 也要能造出实例。
    public required init() {}

    /// 真 XCTest 的 `setUp` / `tearDown` 就是主隔离的，仓库里 `@MainActor` 的套件
    /// 会在 `setUp` 里直接改自己的存储属性；这里不标 `@MainActor` 就编不过。
    @MainActor open func setUp() {}
    @MainActor open func setUpWithError() throws {}
    @MainActor open func tearDown() {}
    @MainActor open func tearDownWithError() throws {}

    /// 桩件不需要 `invokeTest` 的反射：生成的 main 直接点名每个用例。
    public func expectation(description: String) -> XCTestExpectation {
        XCTestExpectation(description: description)
    }

    /// 等一组 expectation。非 inversion 的要在超时内全部 fulfill；inversion 的
    /// 反过来 —— 超时内一次都没 fulfill 才算通过。
    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval) {
        let outcome = XCTWaiter().wait(for: expectations, timeout: timeout)
        if outcome != .completed {
            Stub.record("wait(for:) 超时：期望 \(expectations.map { $0.stubDescription })，实际 \(outcome)",
                        file: #filePath, line: #line)
        }
    }
}

// MARK: - Expectation / waiter

public final class XCTestExpectation {

    let stubDescription: String
    public var isInverted = false
    public var expectedFulfillmentCount = 1
    public var assertForOverFulfill = false
    public private(set) var fulfillmentCount = 0
    public var isFulfilled: Bool { fulfillmentCount >= expectedFulfillmentCount }

    public init(description: String = "") {
        stubDescription = description.isEmpty ? "expectation" : description
    }

    public func fulfill() {
        fulfillmentCount += 1
    }
}

public enum XCTestWaiterStatus: Equatable {
    case completed
    case timedOut
    case incorrectOrder
    case invertedFulfillment
    case interrupted
}

public final class XCTWaiter {

    public init() {}

    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval) -> XCTestWaiterStatus {
        let deadline = Date().addingTimeInterval(timeout)
        // 用例就跑在主线程上，所以「等」必须是排空当前 run loop，而不是 sleep ——
        // sleep 会把回调要用的主队列块一起饿死。
        while Date() < deadline {
            drainRunLoop(until: min(deadline, Date().addingTimeInterval(0.02)))
            let normal = expectations.filter { !$0.isInverted }
            let inverted = expectations.filter { $0.isInverted }
            if inverted.contains(where: { $0.fulfillmentCount > 0 }) { return .invertedFulfillment }
            if normal.contains(where: { $0.assertForOverFulfill
                                          && $0.fulfillmentCount > $0.expectedFulfillmentCount }) {
                return .incorrectOrder
            }
            if !normal.isEmpty, normal.allSatisfy({ $0.isFulfilled }) {
                // inverted 的还要在剩下时间里保持不被 fulfill，才敢判 completed。
                if inverted.isEmpty { return .completed }
            }
        }
        let normal = expectations.filter { !$0.isInverted }
        if normal.allSatisfy({ $0.isFulfilled }) { return .completed }
        return .timedOut
    }

    private func drainRunLoop(until date: Date) {
        RunLoop.current.run(mode: .default, before: date)
    }
}

// MARK: - 断言

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    Stub.record(message.isEmpty ? "XCTFail" : message, file: file, line: line)
}

public func XCTAssert(_ condition: @autoclosure () throws -> Bool,
                      _ message: @autoclosure () -> String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !condition() {
            Stub.record(message().isEmpty ? "XCTAssert failed" : message(), file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool,
                          _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !expression() {
            Stub.record(message().isEmpty ? "XCTAssertTrue failed" : message(), file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool,
                           _ message: @autoclosure () -> String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() {
            Stub.record(message().isEmpty ? "XCTAssertFalse failed" : message(), file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T,
                                         _ expression2: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if lhs != rhs {
            let prefix = "\(Stub.describe(lhs)) is not equal to \(Stub.describe(rhs))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertNotEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T,
                                            _ expression2: @autoclosure () throws -> T,
                                            _ message: @autoclosure () -> String = "",
                                            file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if lhs == rhs {
            let prefix = "\(Stub.describe(lhs)) is equal to \(Stub.describe(rhs))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertNotEqual<T: BinaryFloatingPoint>(_ expression1: @autoclosure () throws -> T,
                                                      _ expression2: @autoclosure () throws -> T,
                                                      accuracy: T,
                                                      _ message: @autoclosure () -> String = "",
                                                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if abs(lhs - rhs) <= accuracy {
            let prefix = "\(Stub.describe(lhs)) differs from \(Stub.describe(rhs)) by \(abs(lhs - rhs)) (≤ \(accuracy))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertNotEqual<T: BinaryInteger>(_ expression1: @autoclosure () throws -> T,
                                                _ expression2: @autoclosure () throws -> T,
                                                accuracy: Double,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        let delta = abs(Double(lhs) - Double(rhs))
        if delta <= accuracy {
            let prefix = "\(Stub.describe(lhs)) differs from \(Stub.describe(rhs)) by \(delta) (≤ \(accuracy))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertEqual<T: BinaryFloatingPoint>(_ expression1: @autoclosure () throws -> T,
                                                   _ expression2: @autoclosure () throws -> T,
                                                   accuracy: T,
                                                   _ message: @autoclosure () -> String = "",
                                                   file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        let delta = abs(lhs - rhs)
        if delta > accuracy {
            let prefix = "\(Stub.describe(lhs)) differs from \(Stub.describe(rhs)) by \(delta) (> \(accuracy))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

/// 整数比较也用 `accuracy: 2` 这种写法（用例里 `XCTAssertEqual(image.width, image.height * 2, accuracy: 2)`）。
/// 只给浮点那一手的话，编译器会把 `2` 当 Float 去乘 `image.height`，报的就是「Int * Float」。
public func XCTAssertEqual<T: BinaryInteger>(_ expression1: @autoclosure () throws -> T,
                                             _ expression2: @autoclosure () throws -> T,
                                             accuracy: Double,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        let delta = abs(Double(lhs) - Double(rhs))
        if delta > accuracy {
            let prefix = "\(Stub.describe(lhs)) differs from \(Stub.describe(rhs)) by \(delta) (> \(accuracy))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertGreaterThan<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                                _ expression2: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if !(lhs > rhs) {
            let prefix = "\(Stub.describe(lhs)) is not greater than \(Stub.describe(rhs))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                                       _ expression2: @autoclosure () throws -> T,
                                                       _ message: @autoclosure () -> String = "",
                                                       file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if !(lhs >= rhs) {
            let prefix = "\(Stub.describe(lhs)) is not greater than or equal to \(Stub.describe(rhs))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertLessThan<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                             _ expression2: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if !(lhs < rhs) {
            let prefix = "\(Stub.describe(lhs)) is not less than \(Stub.describe(rhs))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                                    _ expression2: @autoclosure () throws -> T,
                                                    _ message: @autoclosure () -> String = "",
                                                    file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if !(lhs <= rhs) {
            let prefix = "\(Stub.describe(lhs)) is not less than or equal to \(Stub.describe(rhs))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertNil(_ expression: @autoclosure () throws -> Any?,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        if let value = try expression() {
            let prefix = "is not nil: \(Stub.describe(value))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?,
                            _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() == nil {
            Stub.record(message().isEmpty ? "is nil" : message(), file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertIdentical(_ expression1: @autoclosure () throws -> AnyObject?,
                               _ expression2: @autoclosure () throws -> AnyObject?,
                               _ message: @autoclosure () -> String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if lhs !== rhs {
            let prefix = "\(Stub.describe(lhs)) is not identical to \(Stub.describe(rhs))"
            Stub.record(message().isEmpty ? prefix : "\(message()) — \(prefix)", file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

public func XCTAssertNotIdentical(_ expression1: @autoclosure () throws -> AnyObject?,
                                  _ expression2: @autoclosure () throws -> AnyObject?,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if lhs === rhs {
            Stub.record(message().isEmpty ? "is identical" : message(), file: file, line: line)
        }
    } catch {
        Stub.record("threw \(error)", file: file, line: line)
    }
}

@discardableResult
public func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        Stub.record(message().isEmpty ? "XCTUnwrap got nil" : message(), file: file, line: line)
        throw StubUnwrapFailure()
    }
    return value
}

/// `XCTUnwrap` 拿到 nil 时既要「红」又要把用例体打断，用的就是这个错误。
/// 用例边界认出它不再重复记账（红已经在上面记过了）。
public struct StubUnwrapFailure: Error {}

public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                                    _ message: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line,
                                    _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        Stub.record(message().isEmpty ? "XCTAssertThrowsError: 没抛错" : message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

public func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T,
                                _ message: @autoclosure () -> String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try expression()
    } catch {
        Stub.record(message().isEmpty ? "XCTAssertNoThrow: \(error)" : "\(message()): \(error)",
                    file: file, line: line)
    }
}

/// 仓库里的用法全是 `throw XCTSkip("…")`（没有 `try`），所以这里返回错误值本身，
/// 由 `throw` 把它抛出去 —— 用例边界认出来记成「跳过」。
public func XCTSkip(_ message: String? = nil,
                    file: StaticString = #filePath, line: UInt = #line) -> StubSkip {
    StubSkip(message ?? "XCTSkip(\(file):\(line))")
}

// MARK: - 跑具（生成的 main 只调这三个）

/// 一条待跑的用例：套件名 + 方法名 + 「造实例并调方法」的闭包。
private struct StubCase {
    let suite: String
    let test: String
    let body: @MainActor () -> Void
}

private var _stubCases: [StubCase] = []

/// 生成的 main 逐条登记。每个用例一个新实例（和真 XCTest 一致）。
///
/// 闭包标了 `@MainActor`：仓库里既有 `@MainActor` 的套件类，也有普通类，两边都要
/// 能在同一个跑具里编过（`setUp` / `tearDown` 本身就是主隔离的）。
public func _stubAdd<S: XCTestCase>(_ suite: String, _ type: S.Type, _ test: String,
                                    _ call: @escaping @MainActor (S) throws -> Void) {
    _stubCases.append(StubCase(suite: suite, test: test) {
        Stub.current = suite + "." + test
        Stub.ran += 1
        let instance = S()
        var skip: StubSkip?
        do {
            instance.setUp()
            try instance.setUpWithError()
            try call(instance)
        } catch let error as StubSkip {
            skip = error
        } catch is StubUnwrapFailure {
            // 红已经记过了，这里只负责把用例体打断。
        } catch {
            Stub.record("用例抛出 \(error)", file: #filePath, line: #line)
        }
        do {
            try instance.tearDownWithError()
            instance.tearDown()
        } catch {
            Stub.record("tearDown 抛出 \(error)", file: #filePath, line: #line)
        }
        if let skip { Stub.skipped.append((Stub.current, skip.reason)) }
    })
}

/// 跑完所有登记过的用例，打印汇总，返回退出码（有红就 1）。
/// `ONLY` 环境变量按子串筛用例，方便单跑一条复现。
///
/// 用例体是 `@MainActor` 的，而调用这里的顶层代码（main.swift 第一层）在这个语言模式
/// 下**不是**主隔离的，所以用 `assumeIsolated` 认领「我们已经在主线程上了」—— 跑具确实
/// 起在主线程。这里刻意不走 `DispatchQueue.main.async` + 泵：那样每条用例都从主队列块里
/// 再嵌一层 run loop，`asyncAfter` 那类块会被饿掉，实测就是「长截图只滚了一下就不动了」。
public func _stubRun() -> Int32 {
    let only = ProcessInfo.processInfo.environment["ONLY"]
    let cases = _stubCases.filter { item in
        only.map { item.suite.contains($0) || item.test.contains($0) || (item.suite + "." + item.test).contains($0) } ?? true
    }
    let issuesBefore = Stub.issues.count
    let skippedBefore = Stub.skipped.count
    for item in cases { MainActor.assumeIsolated { item.body() } }

    for issue in Stub.issues[issuesBefore...] {
        print("FAIL \(issue.test) \(issue.file):\(issue.line) \(issue.message)")
    }
    for skip in Stub.skipped[skippedBefore...] {
        print("SKIP \(skip.test) — \(skip.reason)")
    }
    let failed = Set(Stub.issues[issuesBefore...].map { $0.test }).count
    let skipped = Stub.skipped.count - skippedBefore
    print("SUMMARY total=\(cases.count) failed=\(failed) skipped=\(skipped)")
    return failed > 0 ? 1 : 0
}
