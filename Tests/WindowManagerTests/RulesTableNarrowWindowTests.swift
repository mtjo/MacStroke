// 规则表窄窗自适应：六列按比例一起收，格子里的控件跟着列宽铺满，
// 而不是保持建表时的固定帧、被表格边界切成两半。判据直接量列宽与控件帧，
// 量的是 `RulesTable.makeTable()` + `RulesTableScrollView` 配出来的那一套 ——
// 和真页面同一段代码。
//
// 只比「列宽总和 == 视口宽度」是不够的：NSTableView 给每列还加了一圈 intercell
// 间隔和两侧留白（六列 117pt），列宽凑满视口时最后一列连同表头会顶出去。
// 这里量 `rect(ofColumn:)` / `headerRect(ofColumn:)`，看的是真正画出来的边界。
import XCTest
import AppKit
import RuleEngine
import GestureEngine
@testable import Preferences

final class RulesTableNarrowWindowTests: XCTestCase {
    /// 最小窗口 820pt 宽：减掉侧栏与页面左右内边距后，表格视口实测 563pt。
    private let narrowTableWidth: CGFloat = 563
    /// 默认窗口 900pt 宽时表格视口实测 643pt。
    private let defaultWindowTableWidth: CGFloat = 643

    /// 建表时的六列宽度与下限（与 `Coordinator.makeColumns()` 同一张表）。
    private let defaultWidths: [CGFloat] = [84, 98, 96, 104, 138.8515625, 221]
    private let minimumWidths: [CGFloat] = [84, 70, 78, 74, 50, 82]

    private func makeStore() -> (RuleStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        store.rules = []
        return (store, url)
    }

    private func rule(named name: String, points: [GesturePoint] = []) -> Rule {
        Rule(
            name: name,
            description: "",
            template: GestureTemplate(points: points, name: name),
            action: .text("x"),
            note: ""
        )
    }

    @MainActor
    private func makeTable(width: CGFloat)
        -> (RulesTable.Coordinator, NSTableView, RulesTableScrollView, URL) {
        let (store, url) = makeStore()
        store.rules = [
            rule(named: "plain"),
            rule(named: "drawn", points: (0..<20).map {
                GesturePoint(x: Double($0) * 2, y: Double($0) * 2)
            }),
        ]
        let table = RulesTable.makeTable()
        let coordinator = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table

        let scroll = RulesTableScrollView(table: table)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        scroll.layoutSubtreeIfNeeded()
        return (coordinator, table, scroll, url)
    }

    @MainActor
    private func column(_ identifier: String, in table: NSTableView) -> NSTableColumn {
        table.tableColumns.first { $0.identifier.rawValue == identifier }!
    }

    @MainActor
    private func cell(_ identifier: String, row: Int,
                      coordinator: RulesTable.Coordinator,
                      table: NSTableView) -> NSView {
        let column = column(identifier, in: table)
        let container = coordinator.tableView(table, viewFor: column, row: row)!
        // 表格给容器设帧这一步在离屏用例里手动补上；真页面上由 NSTableView 调。
        container.frame = NSRect(x: 0, y: 0, width: column.width, height: 84)
        return container
    }

    /// 分配算法本身：放得下等比分、触底的列钉在下限、再窄就整套最小值。
    func testColumnWidthAllocationRespectsMinimumsAndTotals() {
        // 真实可用宽度 = 视口 - AppKit 给六列固定留的 117pt。
        let shrunk = RulesTable.fittedColumnWidths(available: narrowTableWidth - 117,
                                                   defaults: defaultWidths,
                                                   minima: minimumWidths)
        XCTAssertEqual(shrunk.reduce(0, +), narrowTableWidth - 117, accuracy: 1,
                       "列宽总和没铺满可用宽度：右侧会空一条")
        for (width, minimum) in zip(shrunk, minimumWidths) {
            XCTAssertGreaterThanOrEqual(width, minimum - 0.5, "\(width) 低于下限 \(minimum)")
        }

        let floor = RulesTable.fittedColumnWidths(available: 400,
                                                  defaults: defaultWidths,
                                                  minima: minimumWidths)
        XCTAssertEqual(floor, minimumWidths, "比最小值之和还窄时不该继续压列")

        let grown = RulesTable.fittedColumnWidths(available: 1000,
                                                  defaults: defaultWidths,
                                                  minima: minimumWidths)
        XCTAssertEqual(grown.reduce(0, +), 1000, accuracy: 1,
                       "窗口变宽时六列没跟着铺满")
    }

    @MainActor
    func testShrinkingTheTableShrinksMoreThanTheLastColumn() {
        let (_, table, scroll, url) = makeTable(width: narrowTableWidth)
        defer { try? FileManager.default.removeItem(at: url) }

        let columns = table.tableColumns
        let viewport = scroll.contentSize.width
        XCTAssertEqual(table.frame.width, viewport, accuracy: 1,
                       "表格宽度没对上视口，右侧会空一条或多出一截")

        // 最后一列的绘制帧（含表头）必须留在视口内 —— 这才是「没被切掉」。
        let last = columns.count - 1
        XCTAssertLessThanOrEqual(table.rect(ofColumn: last).maxX, viewport + 0.5,
                                 "最后一列画到视口外：\(table.rect(ofColumn: last)) in \(viewport)")
        if let header = table.headerView {
            XCTAssertLessThanOrEqual(header.headerRect(ofColumn: last).maxX, viewport + 0.5,
                                     "最后一列表头被视口切掉：\(header.headerRect(ofColumn: last))")
        }

        let shrunk = zip(columns.map(\.width), defaultWidths).filter { $0 < $1 - 0.5 }.count
        XCTAssertGreaterThanOrEqual(shrunk, 3,
                                    "只收了一两列，其余列还是建表时的宽：\(columns.map(\.width))")

        // 描述列不该被最先压到下限 —— 六列一起分掉差额。
        XCTAssertGreaterThan(column("Note", in: table).width, 82)

        for column in columns {
            XCTAssertGreaterThanOrEqual(column.width, column.minWidth - 0.5,
                                        "\(column.identifier.rawValue) 被压到最小值以下")
        }
    }

    /// 默认窗口（900pt）下六列左右都留在视口里：这是窄窗问题的原始现场。
    @MainActor
    func testDefaultWindowKeepsTheLastHeaderInsideTheViewport() {
        let (_, table, scroll, url) = makeTable(width: defaultWindowTableWidth)
        defer { try? FileManager.default.removeItem(at: url) }

        let viewport = scroll.contentSize.width
        let last = table.tableColumns.count - 1
        XCTAssertLessThanOrEqual(table.rect(ofColumn: last).maxX, viewport + 0.5)
        if let header = table.headerView {
            let rect = header.headerRect(ofColumn: last)
            XCTAssertLessThanOrEqual(rect.maxX, viewport + 0.5,
                                     "默认窗口下描述列表头被切：\(rect) in \(viewport)")
        }
    }

    @MainActor
    func testAFilterFieldFillsItsColumnInsteadOfOverflowingIt() throws {
        let (coordinator, table, _, url) = makeTable(width: narrowTableWidth)
        defer { try? FileManager.default.removeItem(at: url) }

        let filterColumn = column("Filter", in: table)
        let container = cell("Filter", row: 0, coordinator: coordinator, table: table)
        let field = try XCTUnwrap(container.subviews.compactMap { $0 as? NSTextField }.first)

        XCTAssertEqual(field.frame.maxX, filterColumn.width - 2, accuracy: 1,
                       "文本框还按建表时的 160pt 画到列外：\(field.frame) in \(filterColumn.width)")
        XCTAssertGreaterThan(field.frame.width, 40,
                             "文本框被压到没法输入，等于这一列不能编辑")
    }

    @MainActor
    func testTheGestureThumbnailKeepsItsSquareInANarrowColumn() throws {
        let (coordinator, table, _, url) = makeTable(width: narrowTableWidth)
        defer { try? FileManager.default.removeItem(at: url) }

        let imageColumn = column("Gesture_Image", in: table)
        XCTAssertEqual(imageColumn.width, 84, accuracy: 0.5,
                       "手势图列低于 84pt，缩略图会被切掉一条")
        let container = cell("Gesture_Image", row: 1, coordinator: coordinator, table: table)
        let thumb = try XCTUnwrap(container.subviews.compactMap { $0 as? GestureThumbView }.first)

        XCTAssertEqual(thumb.frame.size.width, 84, accuracy: 0.5,
                       "缩略图跟着容器从零尺寸放大了一倍")
        XCTAssertEqual(thumb.frame.size.height, 84, accuracy: 0.5)
        XCTAssertEqual(thumb.frame.maxX, container.bounds.width, accuracy: 1,
                       "缩略图没在格子里对齐")
    }

    @MainActor
    func testExtremelyNarrowTableStopsAtColumnMinimums() {
        let (_, table, scroll, url) = makeTable(width: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        for column in table.tableColumns {
            XCTAssertGreaterThanOrEqual(column.width, column.minWidth - 0.5,
                                        "\(column.identifier.rawValue) 突破了最小值：控件会被裁")
        }
        let total = table.tableColumns.map(\.width).reduce(0, +)
        XCTAssertGreaterThan(total + 117, scroll.contentSize.width,
                             "窄到放不下时应该横向滚（表格宽于视口），而不是继续压列")
    }
}
