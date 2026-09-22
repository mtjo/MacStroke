// RuleStore CRUD tests: the rules list is positional (original: rows addressed
// by index), so rename must go through replace(named:with:).
import XCTest
@testable import RuleEngine
import GestureEngine

@available(macOS 13.0, *)
final class RuleStoreTests: XCTestCase {
    /// A store with the built-in default rules removed, so CRUD assertions are
    /// not polluted by the default preset list.
    private func makeStore() -> (RuleStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        store.rules = []
        store.save()
        return (store, url)
    }

    private func rule(named name: String, note: String = "") -> Rule {
        Rule(
            name: name,
            description: note,
            template: GestureTemplate(points: [], name: "A Shape"),
            action: .text("x"),
            note: note
        )
    }

    func testAddInsertsAtFrontAndPersists() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.add(rule(named: "First"))
        store.add(rule(named: "Second"))

        XCTAssertEqual(store.rules.map(\.name), ["Second", "First"])
        let reloaded = RuleStore(storageURL: url)
        XCTAssertEqual(reloaded.rules.map(\.name), ["Second", "First"])
    }

    func testUpdateMatchesByNameOnly() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.add(rule(named: "CloseTab", note: "old"))
        XCTAssertNil(store.update(rule(named: "Renamed", note: "new")))
        XCTAssertEqual(store.rules.map(\.name), ["CloseTab"])
    }

    func testReplaceSupportsRename() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.add(rule(named: "CloseTab", note: "old"))
        store.add(rule(named: "Paste", note: "keep"))

        XCTAssertTrue(store.replace(named: "CloseTab", with: rule(named: "NewName", note: "new")))
        XCTAssertEqual(store.rules.count, 2)
        XCTAssertEqual(store.rules[1].name, "NewName")
        XCTAssertEqual(store.rules[1].note, "new")
        XCTAssertFalse(store.replace(named: "missing", with: rule(named: "X")))
    }

    func testExistsExcludingOwnName() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.add(rule(named: "Paste"))
        XCTAssertTrue(store.exists(named: "Paste"))
        XCTAssertFalse(store.exists(named: "Paste", excluding: "Paste"))
        XCTAssertTrue(store.exists(named: "Paste", excluding: "Other"))
    }

    /// Swift 的解码器是全有或全无，一条坏数据就能让整份规则失效；原版的
    /// `reInit` + save 会直接把文件覆盖掉，所以这里必须先留备份再写默认规则。
    func testUnreadableRulesFileIsBackedUpBeforeDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        let backupURL = url.appendingPathExtension("bak")
        let garbage = #"{"not":"a rules array"}"#
        try Data(garbage.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: backupURL)
        }

        let store = RuleStore(storageURL: url)

        XCTAssertEqual(store.rules.count, RuleStore.defaultRules().count)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), garbage)
    }

    func testEmptyRulesFileFallsBackToDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        try Data("[]".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = RuleStore(storageURL: url)

        XCTAssertFalse(store.rules.isEmpty)
    }
}
