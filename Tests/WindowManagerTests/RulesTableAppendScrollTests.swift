// The rules table must reveal the row "+" just appended: with a long list the
// new row sits below the fold, and the "Draw Gesture" button in it is what the
// user needs to click next.
import XCTest
import AppKit
import RuleEngine
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
final class RulesTableAppendScrollTests: XCTestCase {
    private func makeStore() -> (RuleStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        store.rules = []
        return (store, url)
    }

    private func rule(named name: String) -> Rule {
        Rule(
            name: name,
            description: "",
            template: GestureTemplate(points: [], name: name),
            action: .text("x"),
            note: ""
        )
    }

    @MainActor
    private func makeTable(rows: Int) -> (RulesTable.Coordinator, NSScrollView, NSTableView, RuleStore, URL) {
        let (store, url) = makeStore()
        store.rules = (0..<rows).map { rule(named: "r\($0)") }

        let table = NSTableView()
        table.rowHeight = 84
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.hasVerticalScroller = true
        scroll.documentView = table

        let coordinator = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })
        table.dataSource = coordinator
        table.delegate = coordinator
        RulesTable.Coordinator.makeColumns().forEach(table.addTableColumn)
        coordinator.table = table

        let window = NSWindow(contentRect: scroll.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = scroll
        window.layoutIfNeeded()
        scroll.contentView.scroll(to: .zero)
        return (coordinator, scroll, table, store, url)
    }

    /// Opening the pane shows the top of the list; only growth scrolls.
    @MainActor
    func testInitialReloadKeepsTheTableAtTheTop() {
        let (coordinator, scroll, _, store, url) = makeTable(rows: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.reloadIfNeeded()

        XCTAssertEqual(store.rules.count, 30)
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, 1)
    }

    @MainActor
    func testAppendedRuleIsScrolledIntoView() {
        let (coordinator, scroll, table, store, url) = makeTable(rows: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        coordinator.reloadIfNeeded()

        store.rules.append(rule(named: "newest"))
        coordinator.reloadIfNeeded()
        table.layout()

        let last = store.rules.count - 1
        XCTAssertTrue(table.rows(in: table.visibleRect).contains(last),
                      "row \(last) not visible, got \(table.rows(in: table.visibleRect)) "
                          + "at offset \(scroll.contentView.bounds.origin)")
    }
}
