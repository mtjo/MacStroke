//
//  WheelRuleGestureFlowTests.swift
//  MacStroke
//
//  issue #78 第 2 条的**接线侧**取证：面板里点了滚轮档之后，规则、表格、库这三处
//  必须同时改对，缺一处都是「看着配好了，实际没生效」。
//
//  三处各有自己的坏法：
//  - **规则**：`applyInstantGesture` 若清了档位没清轨迹点（或反过来把动作/note/过滤
//          一起清了），这条规则就变成「既不按滚轮也不按轨迹」的半死状态。
//          轨迹点尤其要清：`instant_gesture` 哪天被手工删掉，那条早就没人认的轨迹会静默复活。
//  - **表格**：换档后那一格要立刻重画。刷新走 `Coordinator.reloadIfNeeded()` 的签名比对，
//          签名里没计入 `instantGesture` 的话，面板点完、库改完，屏幕上还是「Draw Gesture」——
//          这条用**数 reloadData 被调了几次**来判，不读签名自己怎么说。
//  - **库**：改完要落盘并读得回来（偏好窗口一关就重建 store）。
//
//  判据一律取自接缝与外部后果（通知、reload 次数、重新加载的 store、送进
//  `onDrawGesture` 的行号），不取被测对象自己的状态字段。
//

import XCTest
import AppKit
import Storage
import RuleEngine
@testable import Preferences
@testable import GestureEngine

final class WheelRuleGestureFlowTests: XCTestCase {
    private func makeStore(rules: [Rule]) -> (RuleStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        store.rules = rules
        return (store, url)
    }

    /// 一条**已经画过轨迹**的规则：选滚轮档要把它整条换掉，不只是加一格。
    private func drawnRule(name: String = "滚轮待换") -> Rule {
        Rule(
            name: name,
            description: "旧说明",
            template: GestureTemplate(points: [GesturePoint(x: 0.1, y: 0.2),
                                               GesturePoint(x: 0.3, y: 0.4)],
                                      name: name),
            minSimilarityScore: 42,
            action: .text("要留住的文本"),
            note: "要留住的提示",
            isEnabled: true,
            triggerOnEveryMatch: true,
            filter: "com.example.*",
            filterType: "wildcard"
        )
    }

    // MARK: - A 选了滚轮档之后，那条规则本身

    /// 清轨迹 + 上档位：两件事必须同时发生。
    @MainActor
    func testPickingTheWheelTierSwapsTheGestureSourceAndClearsTheStroke() throws {
        let (store, url) = makeStore(rules: [drawnRule()])
        defer { try? FileManager.default.removeItem(at: url) }

        let applied = GestureRecordFlow.applyInstantGesture(.wheelDown,
                                                            toRuleNamed: "滚轮待换",
                                                            store: store)
        XCTAssertTrue(applied)
        let rule = try XCTUnwrap(store.rule(named: "滚轮待换"))
        XCTAssertEqual(rule.instantGesture, .wheelDown)
        XCTAssertTrue(rule.template.points.isEmpty,
                      "还留着 \(rule.template.points.count) 个轨迹点：删掉 instant_gesture 就复活成轨迹规则")
    }

    /// 除了手势来源，其余每格都要原样留着 —— 就地换档不等于重建一条规则。
    @MainActor
    func testPickingTheWheelTierKeepsEverythingElseAboutTheRule() throws {
        let old = drawnRule()
        let (store, url) = makeStore(rules: [old])
        defer { try? FileManager.default.removeItem(at: url) }

        _ = GestureRecordFlow.applyInstantGesture(.wheelUp, toRuleNamed: old.name, store: store)

        let rule = try XCTUnwrap(store.rule(named: old.name))
        XCTAssertEqual(rule.description, old.description)
        XCTAssertEqual(rule.minSimilarityScore, old.minSimilarityScore)
        XCTAssertEqual(rule.action, old.action, "动作被换档顶掉了")
        XCTAssertEqual(rule.note, old.note)
        XCTAssertEqual(rule.isEnabled, old.isEnabled)
        XCTAssertEqual(rule.triggerOnEveryMatch, old.triggerOnEveryMatch)
        XCTAssertEqual(rule.filter, old.filter, "按应用生效那条没留住：换档后这条规则变成全局的")
        XCTAssertEqual(rule.filterType, old.filterType)
    }

    /// 列表是**按行号**寻址的（原版语义）：换档只能就地替换，不能追加也不能重排。
    @MainActor
    func testTheWheelTierReplacesInPlaceWithoutGrowingTheList() throws {
        let (store, url) = makeStore(rules: [drawnRule(name: "第一条"),
                                             drawnRule(name: "第二条"),
                                             drawnRule(name: "第三条")])
        defer { try? FileManager.default.removeItem(at: url) }

        _ = GestureRecordFlow.applyInstantGesture(.wheelUp, toRuleNamed: "第二条", store: store)

        XCTAssertEqual(store.rules.count, 3, "名单变长了：换档成了追加")
        XCTAssertEqual(store.rules.map(\.name), ["第一条", "第二条", "第三条"])
        XCTAssertNil(store.rules[0].instantGesture)
        XCTAssertEqual(store.rules[1].instantGesture, .wheelUp)
        XCTAssertNil(store.rules[2].instantGesture)
    }

    /// 规则页靠这条通知重读名单；不发就是「面板点完什么都没发生」。
    @MainActor
    func testPickingTheWheelTierAnnouncesTheStoreChangeExactlyOnce() throws {
        let (store, url) = makeStore(rules: [drawnRule()])
        defer { try? FileManager.default.removeItem(at: url) }

        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .macStrokeRuleStoreDidChange, object: nil, queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = GestureRecordFlow.applyInstantGesture(.wheelUp, toRuleNamed: "滚轮待换", store: store)
        XCTAssertEqual(fired, 1, "换档后没通知（或通知了多次）：表格与运行时缓存会跟库不同步")
    }

    /// 名字查不到时必须**什么都不动**并返回 false：面板那头的 `guard applied else { return }`
    /// 靠这个决定是否弹「画好了」的提示。
    @MainActor
    func testAnUnknownRuleNameChangesNothingAndReportsFalse() throws {
        let (store, url) = makeStore(rules: [drawnRule()])
        defer { try? FileManager.default.removeItem(at: url) }

        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .macStrokeRuleStoreDidChange, object: nil, queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let applied = GestureRecordFlow.applyInstantGesture(.wheelUp,
                                                            toRuleNamed: "名单里没这条",
                                                            store: store)
        XCTAssertFalse(applied)
        XCTAssertEqual(fired, 0, "没改成任何东西却发了通知")
        let rule = try XCTUnwrap(store.rule(named: "滚轮待换"))
        XCTAssertNil(rule.instantGesture)
        XCTAssertEqual(rule.template.points.count, 2, "查不到名字把别人的轨迹清了")
    }

    /// 换档要落盘：偏好窗口一关就重建 store，读不回来等于没配。
    @MainActor
    func testTheWheelTierSurvivesReloadingTheStoreFromDisk() throws {
        let (store, url) = makeStore(rules: [drawnRule()])
        defer { try? FileManager.default.removeItem(at: url) }

        _ = GestureRecordFlow.applyInstantGesture(.wheelDown, toRuleNamed: "滚轮待换", store: store)

        let reloaded = RuleStore(storageURL: url)
        let rule = try XCTUnwrap(reloaded.rule(named: "滚轮待换"))
        XCTAssertEqual(rule.instantGesture, .wheelDown, "换档只在内存里，重开偏好窗口就没了")
        XCTAssertEqual(rule.action, .text("要留住的文本"))
    }

    // MARK: - D 起手键与瞬时档撞车

    /// 选中的瞬时档正好是配置的起手键：运行时起手键优先，这条规则现在按不出来，
    /// 必须当场提醒。规则仍要存下来（用户可能随后去换起手键），所以判据分两半：
    /// 提醒发了一次、且说了是哪一档；档位也确实落进了规则。
    @MainActor
    func testChoosingAnInstantTierThatIsAlsoTheTriggerWarns() throws {
        let (store, url) = makeStore(rules: [drawnRule()])
        defer { try? FileManager.default.removeItem(at: url) }
        let previousNumber = GestureRecordFlow.triggerButtonNumber
        let previousNotifier = GestureRecordFlow.conflictNotifier
        defer {
            GestureRecordFlow.triggerButtonNumber = previousNumber
            GestureRecordFlow.conflictNotifier = previousNotifier
        }
        GestureRecordFlow.triggerButtonNumber = { 2 }
        var messages: [String] = []
        GestureRecordFlow.conflictNotifier = { messages.append($0) }

        XCTAssertTrue(GestureRecordFlow.applyInstantGesture(.middleClick,
                                                            toRuleNamed: "滚轮待换", store: store))

        let message = try XCTUnwrap(messages.first,
                                    "中键既是起手键又被选成瞬时档，没给用户任何提醒")
        XCTAssertEqual(messages.count, 1, "同一件事提醒了 \(messages.count) 次")
        XCTAssertTrue(message.contains(L("Middle Button")),
                      "提醒里没说清是哪一档撞了：\(message)")
        XCTAssertEqual(store.rule(named: "滚轮待换")?.instantGesture, .middleClick,
                       "撞车时不该把用户选的档位丢掉：他可能正要回去换起手键")
    }

    /// 反证：不撞的那几档必须安静 —— 每选一次都弹提醒等于把提醒关掉了。
    @MainActor
    func testChoosingANonConflictingInstantTierStaysSilent() throws {
        let (store, url) = makeStore(rules: [drawnRule()])
        defer { try? FileManager.default.removeItem(at: url) }
        let previousNumber = GestureRecordFlow.triggerButtonNumber
        let previousNotifier = GestureRecordFlow.conflictNotifier
        defer {
            GestureRecordFlow.triggerButtonNumber = previousNumber
            GestureRecordFlow.conflictNotifier = previousNotifier
        }
        GestureRecordFlow.triggerButtonNumber = { 2 }
        var messages: [String] = []
        GestureRecordFlow.conflictNotifier = { messages.append($0) }

        // 滚轮两档没有按键编号，永不可能与起手键撞；侧键 3/4 也不是 2。
        for gesture in [InstantGesture.wheelUp, .wheelDown, .backClick, .forwardClick] {
            XCTAssertTrue(GestureRecordFlow.applyInstantGesture(gesture,
                                                                toRuleNamed: "滚轮待换", store: store))
        }
        XCTAssertTrue(messages.isEmpty, "没撞车却提醒了：\(messages)")
    }

    /// 一条**什么都没配**的规则：模板空、也没档位 —— 规则页这一格该是「Draw Gesture」按钮。
    private func blankRule(name: String) -> Rule {
        Rule(name: name, description: "", template: GestureTemplate(points: [], name: name),
             action: .text("x"), note: "")
    }

    // MARK: - B 规则页那一格：渲成图标，且换档后立刻重画

    /// 只数 `reloadData` 被调了几次的表格，用来看签名比对有没有真的动起来。
    private final class ReloadCountingTable: NSTableView {
        var reloadCount = 0
        override func reloadData() {
            reloadCount += 1
            super.reloadData()
        }
    }

    @MainActor
    private func makeCoordinator(rules: [Rule],
                                 drawRequests: @escaping (Int) -> Void)
        -> (RulesTable.Coordinator, ReloadCountingTable, RuleStore, URL) {
        let (store, url) = makeStore(rules: rules)
        let table = ReloadCountingTable(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let coordinator = RulesTable.Coordinator(store: store, onDrawGesture: drawRequests)
        table.dataSource = coordinator
        table.delegate = coordinator
        RulesTable.Coordinator.makeColumns().forEach(table.addTableColumn)
        coordinator.table = table
        return (coordinator, table, store, url)
    }

    private func imageColumn(in table: NSTableView) throws -> NSTableColumn {
        try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "Gesture_Image" },
                      "表里没有 Gesture_Image 这一列")
    }

    /// 滚轮档的规则画图标，**不是**「Draw Gesture」那颗按钮：空模板 + 有档位
    /// 走的是图标这一支，判反了用户会以为这条规则还没配手势。
    @MainActor
    func testTheWheelRuleRowRendersTheGlyphCellNotTheDrawButton() throws {
        let (sourceStore, sourceURL) = makeStore(rules: [drawnRule(name: "滚轮条")])
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        _ = GestureRecordFlow.applyInstantGesture(.wheelUp, toRuleNamed: "滚轮条", store: sourceStore)
        let wheel = try XCTUnwrap(sourceStore.rule(named: "滚轮条"))

        let (coordinator, table, _, url) = makeCoordinator(
            rules: [wheel, blankRule(name: "没配手势"), drawnRule(name: "有轨迹")],
            drawRequests: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }
        let column = try imageColumn(in: table)

        let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: column, row: 0))
        let thumb = try XCTUnwrap(cell.subviews.first { $0 is InstantGestureThumbView },
                                  "滚轮档那格没渲出图标：用户看到的还是「Draw Gesture」")
        XCTAssertTrue(thumb.frame.width > 0 && thumb.frame.height > 0, "图标格是个零尺寸的哑视图")
        XCTAssertFalse(cell.subviews.contains { subview in
            (subview as? NSButton)?.title == L("Draw Gesture")
        }, "图标和按钮同时都在：这一格到底改哪一头说不清")

        // 负向对照一：同样没有轨迹点，但没档位 —— 这一格必须是那颗按钮。
        let blankCell = try XCTUnwrap(coordinator.tableView(table, viewFor: column, row: 1))
        XCTAssertNil(blankCell.subviews.first { $0 is InstantGestureThumbView },
                     "没配手势的空规则也被渲成了滚轮图标")
        XCTAssertTrue(blankCell.subviews.contains { ($0 as? NSButton)?.title == L("Draw Gesture") },
                      "空轨迹规则那格连「Draw Gesture」都没了")

        // 负向对照二：画过轨迹的规则不许被这一档抢走（滚轮图标盖住轨迹 = 用户看不见画的什么）。
        let strokeCell = try XCTUnwrap(coordinator.tableView(table, viewFor: column, row: 2))
        XCTAssertNil(strokeCell.subviews.first { $0 is InstantGestureThumbView },
                     "有轨迹的规则也被换成了滚轮图标")
        XCTAssertNotNil(strokeCell.subviews.first { $0 is GestureThumbView },
                        "有轨迹的那格没画轨迹")
    }

    /// 双击图标格 = 重新打开选择面板，而且带的是**自己那一行**的行号。
    /// 行号写死或串到别处，改的就是另一条规则。
    @MainActor
    func testDoubleClickingTheWheelCellAsksToRedrawThatRow() throws {
        let (store, url) = makeStore(rules: [drawnRule(name: "第一条"), drawnRule(name: "第二条")])
        defer { try? FileManager.default.removeItem(at: url) }
        _ = GestureRecordFlow.applyInstantGesture(.wheelDown, toRuleNamed: "第二条", store: store)

        var requested: [Int] = []
        let (coordinator, table, _, tableURL) = makeCoordinator(rules: store.rules,
                                                                drawRequests: { requested.append($0) })
        defer { try? FileManager.default.removeItem(at: tableURL) }
        let column = try imageColumn(in: table)

        let row = 1
        let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: column, row: row))
        let thumb = try XCTUnwrap(cell.subviews.first { $0 is InstantGestureThumbView })
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                                     modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                     context: nil, eventNumber: 0,
                                                     clickCount: 2, pressure: 1))
        thumb.mouseDown(with: event)

        XCTAssertEqual(requested, [row], "双击这格送出去的点不是它自己那一行：改的是别的规则")
    }

    /// 面板点完（库里只有 `instantGesture` 变了）表格必须重画一次。
    /// 签名少计了这一格就是「库里改了、屏幕上还是老样子」，而这条判据不看签名本身，
    /// 只看 `reloadData` 真的被调了没有。
    @MainActor
    func testChangingOnlyTheInstantGestureTriggersAReload() throws {
        let (sourceStore, sourceURL) = makeStore(rules: [drawnRule()])
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let strokeRule = try XCTUnwrap(sourceStore.rule(named: "滚轮待换"))

        var requested: [Int] = []
        let (coordinator, table, store, url) = makeCoordinator(rules: [strokeRule],
                                                              drawRequests: { requested.append($0) })
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.reloadIfNeeded()
        XCTAssertEqual(table.reloadCount, 1, "起手没建表：后面的计数没有基准")

        coordinator.reloadIfNeeded()
        XCTAssertEqual(table.reloadCount, 1, "名单一个字没变也重建：下面的计数不作数")

        _ = GestureRecordFlow.applyInstantGesture(.wheelUp, toRuleNamed: "滚轮待换", store: store)
        coordinator.reloadIfNeeded()
        XCTAssertEqual(table.reloadCount, 2,
                       "只换了滚轮档没让表格重建：签名里没计入 instantGesture")

        _ = GestureRecordFlow.applyInstantGesture(.wheelDown, toRuleNamed: "滚轮待换", store: store)
        coordinator.reloadIfNeeded()
        XCTAssertEqual(table.reloadCount, 3, "上滚换下滚不重建：屏幕上还是上一个方向的图标")
        XCTAssertTrue(requested.isEmpty)
    }

    /// 就地改名字（走 `controlTextDidEndEditing` 这条真委派，不直接调内部的 copying）
    /// 之后，滚轮档必须还在。`Rule.copying` 的 `instantGesture` 入参默认是 nil，
    /// 少透传一次就等于「改个名字把这条规则退回成轨迹规则」，而名单上看不出来。
    @MainActor
    func testRenamingAWheelRuleFromTheTableKeepsTheWheelTier() throws {
        let (sourceStore, sourceURL) = makeStore(rules: [drawnRule(name: "滚轮条")])
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        _ = GestureRecordFlow.applyInstantGesture(.wheelUp, toRuleNamed: "滚轮条", store: sourceStore)
        let wheel = try XCTUnwrap(sourceStore.rule(named: "滚轮条"))

        let (coordinator, _, store, url) = makeCoordinator(rules: [wheel], drawRequests: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        field.identifier = NSUserInterfaceItemIdentifier("Gesture")
        field.tag = 0
        field.stringValue = "改过名"
        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field))

        let edited = try XCTUnwrap(store.rule(named: "改过名"))
        XCTAssertEqual(edited.name, "改过名", "改动压根没落地：后面的判据不作数")
        XCTAssertEqual(edited.instantGesture, .wheelUp, "改个名字把滚轮档顶掉了")
        XCTAssertTrue(edited.template.points.isEmpty, "改名把旧轨迹又带回来了")
        XCTAssertEqual(RuleStore(storageURL: url).rule(named: "改过名")?.instantGesture, .wheelUp,
                       "档位只在内存里留住，重开偏好窗口就退成轨迹规则")
    }

    /// 就地换动作类型（Type 那一列的下拉）同样不许把滚轮档顶掉 —— 这一格是「手势来源」
    /// 与「动作」两件事，改一头不该动另一头。
    @MainActor
    func testSwitchingTheActionTypeOfAWheelRuleKeepsTheWheelTier() throws {
        let (sourceStore, sourceURL) = makeStore(rules: [drawnRule(name: "滚轮条")])
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        _ = GestureRecordFlow.applyInstantGesture(.wheelDown, toRuleNamed: "滚轮条", store: sourceStore)
        let wheel = try XCTUnwrap(sourceStore.rule(named: "滚轮条"))

        let (coordinator, table, store, url) = makeCoordinator(rules: [wheel], drawRequests: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }
        let column = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "Type" },
                                  "表里没有 Type 这一列")

        let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: column, row: 0))
        let combo = try XCTUnwrap(cell.subviews.compactMap { $0 as? CallbackComboBox }.first,
                                  "Type 那一格没放下拉：换动作类型的链路压根不在")
        let volumeUpIndex = try XCTUnwrap(RulesTable.Coordinator.typeTitles.firstIndex(of: L("Volume Up")),
                                          "动作类型菜单里没有音量增这一档")
        combo.onSelectionChange?(volumeUpIndex)

        let edited = try XCTUnwrap(store.rule(named: "滚轮条"))
        XCTAssertEqual(edited.action, .volumeUp, "换了动作类型却没换成功：后面的判据不作数")
        XCTAssertEqual(edited.instantGesture, .wheelDown, "换成音量档把滚轮档顶掉了")
        XCTAssertEqual(edited.filter, wheel.filter, "换动作类型顺手改了按应用生效那条")
    }

    // MARK: - C 面板底部那一栏

    /// 这一栏给全部五档：滚轮两档 + 中键、后退、前进攻。顺序就是面板里从左到右的顺序。
    func testTheInstantBandOffersEveryInstantGesture() {
        XCTAssertEqual(PresetGesturePickerPanel.instantGestures,
                       [.wheelUp, .wheelDown, .middleClick, .backClick, .forwardClick])
    }

    /// 那一栏的两格要**真在窗口里、真按档位排好、各自报得出自己是谁**：
    /// 格子建出来了却没进视图树、或者两格都接成同一档，离线看代码都是绿的。
    @MainActor
    func testThePickerWindowShowsOneCellPerWheelDirection() throws {
        let window = PresetGesturePickerPanel().makeWindow(entries: [
            (name: "M", stroke: Stroke(points: [GesturePoint(x: 0.1, y: 0.1),
                                                GesturePoint(x: 0.6, y: 0.6)])),
        ])
        let content = try XCTUnwrap(window.contentView)
        let band = try XCTUnwrap(
            content.subviews.first { $0.identifier?.rawValue == "InstantGestureBand" },
            "面板里没有滚轮那一栏")
        let cells = band.subviews.compactMap { $0 as? InstantGestureCell }
        XCTAssertEqual(cells.count, PresetGesturePickerPanel.instantGestures.count,
                       "栏里 \(cells.count) 格，档位有 \(PresetGesturePickerPanel.instantGestures.count) 档")
        XCTAssertEqual(cells.map(\.gesture), PresetGesturePickerPanel.instantGestures)
        XCTAssertEqual(Set(cells.compactMap { $0.toolTip }).count, cells.count,
                       "两格悬停提示同名：用户不知道该点哪一个")
        XCTAssertTrue(content.bounds.contains(band.frame),
                      "滚轮那一栏 \(band.frame) 超出了内容区 \(content.bounds)：格子画在窗口外")

        // 那一栏的标题与说明要取自文案表（露 key 原文是最常见的一种坏）。
        let texts = content.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(texts.contains(L("Wheel Rule Gesture Header")))
        XCTAssertTrue(texts.contains(L("Wheel Rule Gesture Hint")))
        XCTAssertFalse(texts.contains("Wheel Rule Gesture Header"),
                       "标题没查到文案，页面上露出 key 原文")
        XCTAssertFalse(texts.contains("Wheel Rule Gesture Hint"),
                       "说明没查到文案，页面上露出 key 原文")
    }

    /// 点了下面那一栏的格子，面板交出去的 choice 要**带上这一格自己的档位**、
    /// 名字取自己那行文案、并且不带轨迹。
    ///
    /// 这一手是 #75 那条 P2（binding 串线）的同类：格子建的时候档位是对的、上面那格
    /// 也读得出方向，唯独点下去的那一手把 `instant` 写成 nil 或写死成另一档 —— 离线看
    /// 上一节的两条判据都还是绿的。所以这里发的是**那颗格子真的挂着的那个 action**，
    /// 判的是面板真的交出去的那个 choice。
    @MainActor
    func testClickingABandCellHandsOverItsOwnDirection() throws {
        let panel = PresetGesturePickerPanel()
        let window = panel.makeWindow(entries: [
            (name: "M", stroke: Stroke(points: [GesturePoint(x: 0.1, y: 0.1),
                                                GesturePoint(x: 0.6, y: 0.6)])),
        ])
        let content = try XCTUnwrap(window.contentView)
        let band = try XCTUnwrap(
            content.subviews.first { $0.identifier?.rawValue == "InstantGestureBand" })
        let cells = band.subviews.compactMap { $0 as? InstantGestureCell }
        XCTAssertEqual(cells.count, PresetGesturePickerPanel.instantGestures.count,
                       "五档都在才谈得上各送各的档位")

        for (index, gesture) in PresetGesturePickerPanel.instantGestures.enumerated() {
            let cell = cells[index]
            panel.choice = nil
            XCTAssertNotNil(cell.target, "格子没挂 target：点下去什么都不发生")
            let action = try XCTUnwrap(cell.action, "格子没挂 action")
            XCTAssertTrue(NSApp.sendAction(action, to: cell.target, from: cell),
                          "那颗 action 在这台机器上没人接：用户点了没反应")
            let choice = try XCTUnwrap(panel.choice, "点了滚轮档，面板交出的 choice 是 nil")
            XCTAssertEqual(choice.instant, gesture, "第 \(index) 格交出的档位不是它自己那一档")
            XCTAssertNil(choice.stroke, "选了滚轮档还带着一条轨迹：规则成了两头都占的半死状态")
            XCTAssertEqual(choice.name, L(gesture.locKey))
        }
    }

    /// 上面那一栏不能把预设轨迹网格顶出窗口：加了整栏之后，窗口高度必须跟着长。
    @MainActor
    func testTheInstantBandDoesNotPushThePresetGridOutOfTheWindow() throws {
        let window = PresetGesturePickerPanel().makeWindow(entries: GestureTemplateProvider.shared.presetPickerEntries)
        let content = try XCTUnwrap(window.contentView)
        let grid = try XCTUnwrap(content.subviews.first { $0.identifier?.rawValue == "PresetGestureGrid" })
        let band = try XCTUnwrap(content.subviews.first { $0.identifier?.rawValue == "InstantGestureBand" })
        XCTAssertTrue(content.bounds.contains(grid.frame), "68 格预设网格被挤出窗口")
        XCTAssertTrue(content.bounds.contains(band.frame), "滚轮那一栏被挤出窗口")
        XCTAssertFalse(grid.frame.intersects(band.frame), "两栏重叠：点格子会点错")
    }
}
