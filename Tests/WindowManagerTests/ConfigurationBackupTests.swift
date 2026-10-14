// issue #69：常规页的「导出」只搬 UserDefaults 的开关，手势规则和 AppleScript
// 列表在 Application Support 的 JSON 文件里，于是一份"配置备份"只剩几 KB 的勾选项。
// 这里验的是 ConfigurationBackup 把两边合起来之后：导出内容、导入分派（新格式优先、
// 2.x 归档兜底）、以及坏载荷绝不能动现有配置。
import XCTest
import Foundation
import AppKit
import Storage
import RuleEngine
@testable import AppleScriptRunner
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
final class ConfigurationBackupTests: XCTestCase {
    private var rulesURL: URL!
    private var scriptsURL: URL!
    private var ruleStore: RuleStore!
    private var scriptList: AppleScriptsList!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rulesURL = dir.appendingPathComponent("rules.json")
        scriptsURL = dir.appendingPathComponent("appleScripts.json")
        ruleStore = RuleStore(storageURL: rulesURL)
        ruleStore.rules = []
        ruleStore.save()
        scriptList = AppleScriptsList(storageURL: scriptsURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rulesURL.deletingLastPathComponent())
        ruleStore = nil
        scriptList = nil
        super.tearDown()
    }

    private func rule(named name: String, note: String = "") -> Rule {
        Rule(name: name,
             description: note,
             template: GestureTemplate(points: [GesturePoint(x: 0.1, y: 0.2)],
                                       name: "A Shape"),
             action: .text("hello"),
             note: note)
    }

    /// 原版一条规则字典的样子（`data` 是 NSValue 包的 NSPoint 数组）。
    private func legacyRuleRow(direction: String, scriptID: String? = nil) -> NSMutableDictionary {
        let row = NSMutableDictionary()
        row["direction"] = direction
        row["data"] = [NSValue(point: NSPoint(x: 10, y: 20)), NSValue(point: NSPoint(x: 30, y: 40))]
        row["filter"] = "^com\\.apple\\.Safari$"
        row["filterType"] = 1
        row["actionType"] = scriptID == nil ? 2 : 1
        row["text"] = "typed text"
        row["password"] = ""
        row["apple_script_id"] = scriptID ?? ""
        row["shortcut_code"] = 123
        row["shortcut_flag"] = 1_048_576
        row["note"] = direction
        row["trigger_on_every_match"] = false
        return row
    }

    private func legacyArchive(_ rows: [NSMutableDictionary]) -> Data {
        try! NSKeyedArchiver.archivedData(withRootObject: rows as NSArray, requiringSecureCoding: false)
    }

    private func legacyScriptArchive(_ entries: [[String: String]]) -> Data {
        try! NSKeyedArchiver.archivedData(withRootObject: entries as NSArray, requiringSecureCoding: false)
    }

    // MARK: - 导出内容

    func testPayloadCarriesSettingsAndBothConfigurations() throws {
        ruleStore.add(rule(named: "CloseTab", note: "关闭标签页"))
        scriptList.addScript(name: "Close Tabs", source: "tell application \"Chrome\"")
        let domain: [String: Any] = [
            "showUIInWhateverApp": true,
            "whiteList": "com.apple.Safari",
            "filterIsInWhiteMode": true,
            "rightClicksList": ["com.apple.finder"],
            "com.apple.SomethingElse.enabled": "not ours",
            "NSQuitAlwaysKeepsWindows": "not ours",
        ]

        let payload = ConfigurationBackup.payload(
            domainValues: domain,
            rules: try ruleStore.configurationJSON(),
            scripts: try scriptList.configurationJSON())

        XCTAssertEqual(payload[ConfigurationBackup.rulesKey] is Data, true)
        XCTAssertEqual(payload[ConfigurationBackup.scriptsKey] is Data, true)
        XCTAssertEqual(payload["showUIInWhateverApp"] as? Bool, true)
        XCTAssertEqual(payload["whiteList"] as? String, "com.apple.Safari")
        XCTAssertEqual(payload["rightClicksList"] as? [String], ["com.apple.finder"])
        XCTAssertNil(payload["com.apple.SomethingElse.enabled"], "别人的键不能混进备份")
        XCTAssertNil(payload["NSQuitAlwaysKeepsWindows"])

        let decoded = try JSONDecoder().decode([Rule].self, from: payload[ConfigurationBackup.rulesKey] as! Data)
        XCTAssertEqual(decoded.map(\.name), ["CloseTab"])
        XCTAssertEqual(decoded.first?.note, "关闭标签页")
    }

    func testDomainValuesStripThePayloads() {
        let backup: [String: Any] = [
            "showUIInWhateverApp": false,
            ConfigurationBackup.rulesKey: Data(#"[]"#.utf8),
            ConfigurationBackup.scriptsKey: Data(#"[]"#.utf8),
        ]

        let values = ConfigurationBackup.domainValues(from: backup)

        XCTAssertEqual(values.keys.sorted(), ["showUIInWhateverApp"],
                       "载荷写回偏好域就是一份没人读的规则副本")
    }

    /// 备份真的要用 plist 容器装 Data：这里用与 App 完全相同的 API 落盘再读回。
    func testPlistContainerRoundTripsThePayloads() throws {
        ruleStore.add(rule(named: "CloseTab", note: "关闭标签页"))
        ruleStore.add(rule(named: "Maximize"))
        scriptList.addScript(name: "Close Tabs", source: "tell application \"Chrome\"")
        let payload = ConfigurationBackup.payload(
            domainValues: ["showUIInWhateverApp": true],
            rules: try ruleStore.configurationJSON(),
            scripts: try scriptList.configurationJSON())
        let url = rulesURL.deletingLastPathComponent().appendingPathComponent("backup.plist")
        defer { try? FileManager.default.removeItem(at: url) }

        try (payload as NSDictionary).write(to: url)
        let readBack = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])

        XCTAssertEqual(readBack["showUIInWhateverApp"] as? Bool, true)
        let rules = try JSONDecoder().decode([Rule].self,
                                             from: try XCTUnwrap(readBack[ConfigurationBackup.rulesKey] as? Data))
        XCTAssertEqual(rules.map(\.name), ["Maximize", "CloseTab"], "备份要保持列表里的顺序（新增在表头）")
    }

    // MARK: - 导入分派

    func testApplyRestoresBothFromJSONAndPersists() throws {
        // 载荷从另一对 store 走公开的导出接口拿，和 App 里「导出」按下去产出的字节同构。
        let dir = rulesURL.deletingLastPathComponent()
        let exportStore = RuleStore(storageURL: dir.appendingPathComponent("export-rules.json"))
        exportStore.rules = []
        exportStore.add(rule(named: "CloseTab", note: "关闭标签页"))
        let exportScripts = AppleScriptsList(storageURL: dir.appendingPathComponent("export-scripts.json"))
        exportScripts.addScript(name: "Close Tabs", source: "tell application \"Chrome\"")
        let backup: [String: Any] = [
            ConfigurationBackup.rulesKey: try exportStore.configurationJSON(),
            ConfigurationBackup.scriptsKey: try exportScripts.configurationJSON(),
        ]

        try ConfigurationBackup.apply(backup, ruleStore: ruleStore, scriptList: scriptList)

        XCTAssertEqual(ruleStore.rules.map(\.name), ["CloseTab"])
        XCTAssertEqual(scriptList.getAllScripts().map(\.name), ["Close Tabs"])
        XCTAssertEqual(RuleStore(storageURL: rulesURL).rules.map(\.name), ["CloseTab"])
        XCTAssertEqual(AppleScriptsList(storageURL: scriptsURL).getAllScripts().map(\.name), ["Close Tabs"])
    }

    func testJSONPayloadWinsOverTheLegacyArchive() throws {
        let backup: [String: Any] = [
            ConfigurationBackup.rulesKey: try JSONEncoder().encode([rule(named: "FromBackup")]),
            "rules": legacyArchive([legacyRuleRow(direction: "FromLegacy")]),
        ]

        try ConfigurationBackup.apply(backup, ruleStore: ruleStore, scriptList: scriptList)

        XCTAssertEqual(ruleStore.rules.map(\.name), ["FromBackup"])
    }

    /// 2.x 导出的 plist 仍然是可用的恢复工具（issue #67 那条路不能被这次改动挡掉）。
    func testLegacyOnlyBackupStillUsesThePre3_0Path() throws {
        let scriptID = "MacStroke-9AB2-hostname-1723456789-00000003"
        let backup: [String: Any] = [
            "rules": legacyArchive([legacyRuleRow(direction: "Script", scriptID: scriptID)]),
            "appleScripts": legacyArchive([["title": "Close Tabs",
                                            "script": "tell application \"Chrome\"",
                                            "id": scriptID]]),
        ]

        try ConfigurationBackup.apply(backup, ruleStore: ruleStore, scriptList: scriptList)

        XCTAssertEqual(ruleStore.rules.map(\.name), ["Script"])
        XCTAssertEqual(ruleStore.rules.first?.filterType, "regex")
        let restoredScriptID = try XCTUnwrap(ruleStore.rules.first?.spareActions.appleScriptId)
        let resolved = try XCTUnwrap(scriptList.scriptID(forLegacyID: scriptID))
        XCTAssertEqual(restoredScriptID, resolved.uuidString,
                       "规则要指向导入进来的那个脚本，不能留成旧 id")
    }

    func testGarbagePayloadThrowsAndChangesNothing() throws {
        ruleStore.add(rule(named: "Keep"))
        scriptList.addScript(name: "Keep", source: "return 1")
        ruleStore.save()
        let rulesBefore = try Data(contentsOf: rulesURL)
        let scriptsBefore = try Data(contentsOf: scriptsURL)

        XCTAssertThrowsError(try ConfigurationBackup.apply(
            [ConfigurationBackup.rulesKey: Data("garbage".utf8)],
            ruleStore: ruleStore, scriptList: scriptList))

        XCTAssertEqual(ruleStore.rules.map(\.name), ["Keep"])
        XCTAssertEqual(try Data(contentsOf: rulesURL), rulesBefore)
        XCTAssertEqual(try Data(contentsOf: scriptsURL), scriptsBefore)
    }

    /// 备份里没有配置载荷时（3.0–3.1.2 那种只有开关的文件）导入不能报错，
    /// 也不能凭空造一份规则出来。
    func testSettingsOnlyBackupIsANoOp() throws {
        ruleStore.add(rule(named: "Keep"))

        try ConfigurationBackup.apply(["showUIInWhateverApp": true],
                                      ruleStore: ruleStore,
                                      scriptList: scriptList)

        XCTAssertEqual(ruleStore.rules.map(\.name), ["Keep"])
        XCTAssertEqual(scriptList.count, 0)
    }
}
