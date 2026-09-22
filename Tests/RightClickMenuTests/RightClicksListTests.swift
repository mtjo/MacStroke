import XCTest
@testable import RightClickMenu

final class RightClicksListTests: XCTestCase {
    /// 固定 suite 名：随机 UUID 会让每次跑测试都在 ~/Library/Preferences 里留下一个新 plist
    private let suiteName = "com.macstroke.tests.RightClicksList"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        purge()
    }

    override func tearDownWithError() throws {
        purge()
        try super.tearDownWithError()
    }

    private func purge() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        )
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
