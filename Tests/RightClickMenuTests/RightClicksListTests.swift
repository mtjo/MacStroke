import XCTest
@testable import RightClickMenu

final class RightClicksListTests: XCTestCase {
    private let suiteName = "com.macstroke.tests.RightClicksList.\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func testStartsEmptyUntilFirstLaunchReInit() {
        let list = RightClicksList(defaults: makeDefaults())
        XCTAssertEqual(list.count, 0)
        XCTAssertFalse(list.needRightClick(byAppname: "com.jetbrains.intellij"))

        list.reInit()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.appname(at: 0), "com.jetbrains.*")
        XCTAssertTrue(list.needRightClick(byAppname: "com.jetbrains.intellij"))
    }

    func testEmptyListStaysEmptyAfterReload() {
        let defaults = makeDefaults()
        RightClicksList(defaults: defaults).reInit()
        let cleared = RightClicksList(defaults: defaults)
        cleared.clear()

        XCTAssertEqual(RightClicksList(defaults: defaults).count, 0)
    }

    func testNeedRightClickMatchesExactBundleIdentifier() {
        let list = RightClicksList(defaults: makeDefaults())
        list.add("com.example.app")

        XCTAssertTrue(list.needRightClick(byAppname: "com.example.app"))
    }

    func testNeedRightClickMatchesWildcardPrefix() {
        let list = RightClicksList(defaults: makeDefaults())
        list.add("com.example.*")

        XCTAssertTrue(list.needRightClick(byAppname: "com.example.desktop"))
        XCTAssertFalse(list.needRightClick(byAppname: "org.example.desktop"))
    }

    func testAddDeduplicatesAndPersists() {
        let firstDefaults = makeDefaults()
        var list = RightClicksList(defaults: firstDefaults)
        list.add("com.example.app")
        list.add("com.example.app")

        let restored = RightClicksList(defaults: firstDefaults)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.appname(at: 1), "com.example.app")
    }

    func testRemoveSetAndClear() {
        let list = RightClicksList(defaults: makeDefaults())
        list.add("com.example.app")

        list.setAppname(at: 0, appname: "org.example.app")
        XCTAssertEqual(list.appname(at: 0), "org.example.app")
        XCTAssertTrue(list.remove(at: 0))
        XCTAssertFalse(list.remove(at: 0))

        list.add("com.jetbrains.*")
        list.clear()
        XCTAssertEqual(list.count, 0)
        XCTAssertFalse(list.needRightClick(byAppname: "com.jetbrains.intellij"))
    }

    func testOutOfBoundsAccessReturnsNil() {
        let list = RightClicksList(defaults: makeDefaults())

        XCTAssertNil(list.appname(at: -1))
        XCTAssertNil(list.appname(at: list.count))
    }
}
