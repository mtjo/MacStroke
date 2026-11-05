//
//  WheelRuleGestureGlyphTests.swift
//  MacStroke
//
//  issue #78 第 2 条的**界面侧**取证：规则页那一格滚轮手势（图标 + 读法）与
//  「绘制手势」面板底部那一栏的滚轮格子。
//
//  为什么要像素：这一条能力的全部意义是「用户看得出这格规则是上滚还是下滚」。
//  箭头画反（AppKit 原点在设计左下角，把 maxY 当成「下」是最顺手的一种写错）、
//  两档渲成同一个形状、图标压根没画只剩文字 —— 这三种坏在「读视图自己的状态」的
//  判据下全是绿的，因为只有画出来那一层能分辨。这里比的是**位图**：
//  先证明这一带确实有墨（渲染吃到了被测的档位），再看上下两档的墨在胶囊上下两半
//  怎么分布 —— 上滚的箭尖在上半、下滚在下半，这个不对称必须**翻号**。
//  带子与阈值全是从 1x 离屏位图**实测**出来的（分带数，不按整格差 —— 整格差会被
//  胶囊轮廓和那行文字盖掉，M52 那一回就是这么逃过的）。
//
//  纯函数那几条（胶囊取位、箭尖 y、图标区与文字行的分割）钉的是几何口径；视图那几条
//  钉的是「双击能开面板」「格子报得出自己是谁」。
//

import XCTest
import AppKit
import Storage
import RuleEngine
@testable import Preferences
@testable import GestureEngine

final class WheelRuleGestureGlyphTests: XCTestCase {
    private static let exportDir = "/tmp/macstroke-wheel-rule-glyph-check"
    /// 规则页手势格的尺寸（行高 84，列宽 84，见 `RulesTable.makeColumns`）。
    private static let cellSide: CGFloat = 84

    // MARK: - 几何口径（纯函数）

    /// 胶囊必须**居中且不超出格子**：贴边会被行边框切掉，偏右会压到下一列。
    func testCapsuleIsCentredAndNeverBiggerThanTheCell() {
        for side in [CGFloat(24), 42, 56, 84, 200] {
            let rect = NSRect(x: 0, y: 0, width: side, height: side)
            let capsule = WheelGestureGlyph.capsuleRect(in: rect)
            XCTAssertTrue(rect.contains(capsule), "\(side) 边长的格子里胶囊 \(capsule) 溢出了")
            XCTAssertEqual(capsule.midX, rect.midX, accuracy: 0.001, "\(side)：左右没居中")
            XCTAssertEqual(capsule.midY, rect.midY, accuracy: 0.001, "\(side)：上下没居中")
        }
        // 高大于宽：胶囊跟着变高，但宽度不跟着变宽（鼠标胶囊不该画成正圆）。
        let wide = WheelGestureGlyph.capsuleRect(in: NSRect(x: 0, y: 0, width: 200, height: 60))
        let tall = WheelGestureGlyph.capsuleRect(in: NSRect(x: 0, y: 0, width: 60, height: 200))
        XCTAssertGreaterThan(tall.height, wide.height)
        XCTAssertLessThanOrEqual(wide.width, wide.height, "扁格子里画出一个横着的胶囊")
    }

    /// 箭尖的 y：上滚在胶囊上半、下滚在下半（AppKit 原点在设计左下角，y 越大越靠上）。
    /// 这一条写反就是「界面上写着上滚、按下去走的是下滚」，而只有画出来才看得出。
    func testArrowTipIsTheUpperHalfForUpAndTheLowerHalfForDown() {
        let rect = NSRect(x: 0, y: 0, width: 84, height: 84)
        let capsule = WheelGestureGlyph.capsuleRect(in: rect)
        let up = WheelGestureGlyph.arrowTipY(.wheelUp, in: rect)
        let down = WheelGestureGlyph.arrowTipY(.wheelDown, in: rect)
        XCTAssertGreaterThan(up, capsule.midY, "上滚的箭尖掉到了下半：箭头朝下")
        XCTAssertLessThan(down, capsule.midY, "下滚的箭尖跑到了上半：箭头朝上")
        XCTAssertGreaterThan(up, down)
        // 两档对称：箭尖到中线的距离必须一样，否则一格看起来「箭头更靠边」。
        XCTAssertEqual(up - capsule.midY, capsule.midY - down, accuracy: 0.001)
        // 箭尖必须在胶囊里面（留 inset），不然头会戳到胶囊外。
        XCTAssertLessThan(up, capsule.maxY)
        XCTAssertGreaterThan(down, capsule.minY)
    }

    /// 图标与读法**各占一格的一部分、互不重叠、都不出界**：重叠时字压着图标，
    /// 出界时被行边框裁掉 —— 两种都是「用户只看到半截」。
    func testGlyphAndLabelSplitTheCellWithoutOverlapping() {
        let bounds = NSRect(x: 0, y: 0, width: Self.cellSide, height: Self.cellSide)
        let glyph = WheelGestureGlyph.cellGlyphRect(in: bounds)
        let label = WheelGestureGlyph.cellLabelRect(in: bounds)

        XCTAssertTrue(bounds.contains(glyph), "图标区 \(glyph) 超出格子 \(bounds)")
        XCTAssertTrue(bounds.contains(label), "文字行 \(label) 超出格子 \(bounds)")
        XCTAssertFalse(glyph.intersects(label),
                       "图标区 \(glyph) 与文字行 \(label) 重叠：字会压在图标上")
        XCTAssertLessThan(label.minY, glyph.minY, "文字行不在图标下面：这一格的排版被换了一头")
        XCTAssertEqual(label.width, bounds.width, "文字行不整宽：读法长了会截尾")
    }

    /// 五档的读法必须**取自文案表且互不相同**：这里不走 `L()` 的兜底链
    /// （桩件里 `L()` 只吃英文表），key 本身不同是最小判据，同不同名由文案表那条用例兜。
    func testEveryDirectionReadsItsOwnKey() {
        XCTAssertEqual(InstantGesture.wheelUp.locKey, "Wheel Gesture up row")
        XCTAssertEqual(InstantGesture.wheelDown.locKey, "Wheel Gesture down row")
        XCTAssertEqual(InstantGesture.middleClick.locKey, "Middle Button")
        XCTAssertEqual(InstantGesture.backClick.locKey, "Back Button")
        XCTAssertEqual(InstantGesture.forwardClick.locKey, "Forward Button")
        XCTAssertEqual(Set(InstantGesture.allCases.map(\.locKey)).count, InstantGesture.allCases.count,
                       "有两档读法取到了同一个 key：界面上分不出是哪一档")
    }

    /// 侧键箭尖的 x：后退在胶囊左端、前进攻在右端，且都在胶囊里面（留 inset）。
    /// 写反就是「图标画着后退、按下去走的是前进」，只有画出来才看得出。
    func testSideButtonArrowTipsSitAtOppositeEndsOfTheCapsule() throws {
        let rect = NSRect(x: 0, y: 0, width: 84, height: 84)
        let capsule = WheelGestureGlyph.capsuleRect(in: rect)
        let back = try XCTUnwrap(WheelGestureGlyph.horizontalArrowTipX(.backClick, in: rect))
        let forward = try XCTUnwrap(WheelGestureGlyph.horizontalArrowTipX(.forwardClick, in: rect))

        XCTAssertLessThan(back, capsule.midX, "后退的箭尖不在左半边：箭头画反了")
        XCTAssertGreaterThan(forward, capsule.midX, "前进的箭尖不在右半边：箭头画反了")
        XCTAssertGreaterThan(back, capsule.minX, "后退箭尖戳到胶囊外了")
        XCTAssertLessThan(forward, capsule.maxX, "前进箭尖戳到胶囊外了")
        // 两档对称：箭尖到中线的距离必须一样。
        XCTAssertEqual(capsule.midX - back, forward - capsule.midX, accuracy: 0.001)

        // 没有水平箭头的三档不给 x —— 给了就成了「滚轮也画了个横向箭头」。
        XCTAssertNil(WheelGestureGlyph.horizontalArrowTipX(.wheelUp, in: rect))
        XCTAssertNil(WheelGestureGlyph.horizontalArrowTipX(.wheelDown, in: rect))
        XCTAssertNil(WheelGestureGlyph.horizontalArrowTipX(.middleClick, in: rect))
    }

    // MARK: - 离屏像素：两档渲出来必须不一样

    /// 墨在胶囊**上半 / 下半**的分布：上滚头在上、下滚头在下，不对称必须翻号。
    ///
    /// 实测（1x、84×84）：胶囊占 y 32…66（AppKit 坐标， bitmap 行 18…52），
    /// 图标带取 0.20…0.60 这一段（bitmap 行 16…50），中线在 0.40（行 33）——
    /// 上半带 = 0.20…0.40，下半带 = 0.40…0.60，两带等高，胶囊轮廓与杆子在两带里对称，
    /// 唯一不对称的就是那三笔箭头的头。
    ///
    /// 本机实测（1x、84×84）：上滚 94 对 72（差 +22），下滚 74 对 92（差 −18），
    /// 两档整带像素差 52；同一档渲两次差 0（那 52 不是抗锯齿噪声）。
    /// 阈值取实测的一半上下：不同机器与外观留有余量，又远大于「两半对称」该有的 0。
    @MainActor
    func testWheelUpAndDownRenderWithTheArrowHeadOnOppositeHalves() throws {
        let up = try render(.wheelUp, name: "rule-cell-up")
        let down = try render(.wheelDown, name: "rule-cell-down")

        let upper = 0.20 ... 0.40
        let lower = 0.40 ... 0.60

        // 先自证渲染吃到了档位：两档在这一带都得有墨，而且墨量在同一量级
        // （差得远说明其中一格压根没画图标）。
        let upUpper = try ink(up, band: upper)
        let upLower = try ink(up, band: lower)
        let downUpper = try ink(down, band: upper)
        let downLower = try ink(down, band: lower)
        XCTAssertGreaterThan(upUpper + upLower, 40, "上滚这格在图标带里没墨：图标没画出来")
        XCTAssertGreaterThan(downUpper + downLower, 40, "下滚这格在图标带里没墨：图标没画出来")

        // 不对称必须翻号：上滚的墨偏上半，下滚的墨偏下半。
        XCTAssertGreaterThan(upUpper - upLower, 8,
                             "上滚这格上下带墨量差 \(upUpper - upLower)：箭尖不在上半，箭头画反了")
        XCTAssertLessThan(downUpper - downLower, -8,
                          "下滚这格上下带墨量差 \(downUpper - downLower)：箭尖不在下半")
        // 两档之间确有像素差（把两档画成同一个形状就是这一条红）。
        XCTAssertGreaterThan(try changedPixels(up, down, band: 0.18 ... 0.62), 20,
                             "上滚与下滚渲成同一个图标")
    }

    /// 反向对照：同一档渲两次必须**没有**差 —— 上面那条差值不是噪声做出来的。
    @MainActor
    func testTheSameDirectionRendersIdenticallyTwice() throws {
        let a = try render(.wheelUp, name: "rule-cell-up-repeat-a")
        let b = try render(.wheelUp, name: "rule-cell-up-repeat-b")
        XCTAssertEqual(try changedPixels(a, b, band: 0.00 ... 1.00), 0,
                       "同一档两次渲出不一样：上面的差值判据不作数")
    }

    /// 后退 / 前进：水平箭头，墨必须偏各自的箭尖那一侧（左 / 右），翻号。
    ///
    /// 带子取胶囊左右两半（bitmap 列 0.33…0.50 / 0.50…0.66，胶囊横跨 30…54，
    /// 中线 42 = 0.50），纵向仍是图标带 0.20…0.60。两半对称的胶囊轮廓与杆子抵消，
    /// 唯一不对称的是箭头那三笔 —— 与上下两档同一条思路。
    @MainActor
    func testBackAndForwardRenderWithTheArrowHeadOnOppositeSides() throws {
        let back = try render(.backClick, name: "rule-cell-back")
        let forward = try render(.forwardClick, name: "rule-cell-forward")

        let vertical = 0.20 ... 0.60
        let left = 0.33 ... 0.50
        let right = 0.50 ... 0.66

        let backLeft = try ink(back, band: vertical, columns: left)
        let backRight = try ink(back, band: vertical, columns: right)
        let forwardLeft = try ink(forward, band: vertical, columns: left)
        let forwardRight = try ink(forward, band: vertical, columns: right)
        XCTAssertGreaterThan(backLeft + backRight, 40, "后退这格在图标带里没墨：图标没画出来")
        XCTAssertGreaterThan(forwardLeft + forwardRight, 40, "前进这格在图标带里没墨：图标没画出来")

        XCTAssertGreaterThan(backLeft - backRight, 8,
                             "后退这格左半 \(backLeft) 右半 \(backRight)：箭尖不在左边，箭头画反了")
        XCTAssertLessThan(forwardLeft - forwardRight, -8,
                          "前进这格左半 \(forwardLeft) 右半 \(forwardRight)：箭尖不在右边")

        XCTAssertGreaterThan(try changedPixels(back, forward, band: 0.18 ... 0.62), 20,
                             "后退与前进渲成同一个图标")
    }

    /// 水平箭头的两撇必须朝**尾端**张开：箭尖在胶囊端点，撇要落在箭尖内侧；
    /// 撇画到箭尖外侧（胶囊外面）就是箭头看着指反了 —— 而左右两半的墨量差照样翻号，
    /// 所以上一条判据看不见这一种坏（反向变异 G10 就是这么逃过的）。
    ///
    /// 取撇端点附近两个小窗：内侧必须有墨（先证这一格真画了箭头），外侧必须一个墨点都没有。
    /// 窗子与胶囊弧线留了 0.9pt 余量（弧线在 dy≈4 处还在窗子右边 0.9pt 以外）。
    @MainActor
    func testSideButtonArrowWingsOpenTowardTheTail() throws {
        let bounds = NSRect(x: 0, y: 0, width: Self.cellSide, height: Self.cellSide)
        let glyph = WheelGestureGlyph.cellGlyphRect(in: bounds)
        let capsule = WheelGestureGlyph.capsuleRect(in: glyph)

        for (gesture, name, outward) in [
            (InstantGesture.backClick, "rule-cell-back-wings", CGFloat(-1)),
            (InstantGesture.forwardClick, "rule-cell-forward-wings", CGFloat(1)),
        ] {
            let rep = try render(gesture, name: name)
            let tip = try XCTUnwrap(WheelGestureGlyph.horizontalArrowTipX(gesture, in: glyph))
            let wingY = capsule.midY + 3.4
            let size: CGFloat = 2.0

            let inner = NSRect(x: tip - outward * 4 - size / 2, y: wingY, width: size, height: 1.2)
            let outer = NSRect(x: tip + outward * 4 - size / 2, y: wingY, width: size, height: 1.2)
            XCTAssertGreaterThan(try inkInViewRect(rep, inner, in: bounds), 0,
                                 "\(gesture) 箭尖内侧没墨：这一格压根没画箭头，下面的判据不作数")
            XCTAssertEqual(try inkInViewRect(rep, outer, in: bounds), 0,
                           "\(gesture) 的两撇画到了箭尖外侧：箭头看着指反了")
        }
    }

    /// 中键的实心药丸与两种箭头必须**画得出像素差**：中键按下去是滚轮本身，
    /// 画成箭头就会与「上滚/后退」混成同一格。另反证同一档重复渲染为 0。
    @MainActor
    func testMiddleClickRendersDifferentlyFromBothArrowGlyphs() throws {
        let middle = try render(.middleClick, name: "rule-cell-middle")
        let up = try render(.wheelUp, name: "rule-cell-up-vs-middle")
        let back = try render(.backClick, name: "rule-cell-back-vs-middle")

        XCTAssertGreaterThan(try changedPixels(middle, up, band: 0.18 ... 0.62), 20,
                             "中键画成了上滚的竖直箭头")
        XCTAssertGreaterThan(try changedPixels(middle, back, band: 0.18 ... 0.62), 20,
                             "中键画成了侧键的水平箭头")
        let repeated = try render(.middleClick, name: "rule-cell-middle-repeat")
        XCTAssertEqual(try changedPixels(middle, repeated, band: 0.00 ... 1.00), 0,
                       "中键两次渲出不一样：上面的差值判据不作数")
    }

    // MARK: - 规则页那一格：交互

    /// 双击这格要能重新打开选择面板（轨迹格那一条早就有这手）。只认双击、
    /// 单击不响应是原版的口径：单击是给选行的，弹面板会把行选中态打断。
    @MainActor
    func testDoubleClickOpensThePickerAndSingleClickDoesNot() throws {
        let thumb = InstantGestureThumbView(gesture: .wheelUp, frame: NSRect(x: 0, y: 0, width: 84, height: 84))
        var opened = 0
        thumb.onDoubleClick = { opened += 1 }

        thumb.mouseDown(with: try mouseEvent(.leftMouseDown, clickCount: 1))
        XCTAssertEqual(opened, 0, "单击就弹面板：行选不上了")

        thumb.mouseDown(with: try mouseEvent(.leftMouseDown, clickCount: 2))
        XCTAssertEqual(opened, 1, "双击没开选择面板：这格改不了")

        thumb.mouseDown(with: try mouseEvent(.leftMouseDown, clickCount: 2))
        XCTAssertEqual(opened, 2, "第二次双击没反应")
    }

    /// 格子**装进真表格之后**几何必须不变：单格离屏渲染全绿、真机图标却顶到格子上沿
    /// 只剩一半 —— 根因是容器交回表格后被 AppKit 从零尺寸改成 84×84，子视图带
    /// `[.width, .height]` 比例自适应会被连带放大一倍（2026-11-03 实测：
    /// 容器 84×84、格子被放大成 168×168）。这一条用**生产路径**（Coordinator 的
    /// viewFor → 真 NSTableView）起 rowView 再量帧，不重现造一个理想容器
    /// （重现造的容器没经历那次改尺寸，假绿）。
    @MainActor
    func testTableHostedThumbKeepsItsCellGeometry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        store.rules = [Rule(
            name: "下滚", description: "",
            template: GestureTemplate(points: [] as [GesturePoint], name: ""),
            action: .text(""), instantGesture: InstantGesture.wheelDown)]
        let coordinator = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })

        let table = NSTableView()
        table.rowHeight = 84
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Gesture_Image"))
        column.width = 84
        table.addTableColumn(column)
        table.dataSource = coordinator
        table.delegate = coordinator

        let box = WhiteBox(frame: NSRect(x: 0, y: 0, width: 84, height: 84))
        box.addSubview(table)
        table.frame = box.bounds
        let window = NSWindow(contentRect: box.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = box
        window.layoutIfNeeded()

        let rowView = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true),
                                    "表格没起 rowView：这一条判据压根没跑")
        let container = try XCTUnwrap(rowView.subviews.first)
        let thumb = try XCTUnwrap(container.subviews.first as? InstantGestureThumbView,
                                  "这一格不是滚轮档手势格")
        XCTAssertEqual(thumb.frame, NSRect(x: 0, y: 0, width: 84, height: 84),
                       "格子被表格改尺寸连带着缩放：图标与读法都会顶出格外")
        let label = try XCTUnwrap(thumb.subviews.first { $0 is NSTextField })
        XCTAssertEqual(label.frame, WheelGestureGlyph.cellLabelRect(in: thumb.bounds),
                       "读法行的位置没跟着格子走")

        // 导一张位图供人工核对：图标应居中偏上、读法在正下方。
        box.needsDisplay = true
        let rep = try XCTUnwrap(box.bitmapImageRepForCachingDisplay(in: box.bounds))
        box.cacheDisplay(in: box.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(Self.exportDir)/table-hosted-cell.png"))
    }

    /// 这格必须**报得出自己是谁**：无障碍标签是 VoiceOver 用户唯一的入口，
    /// 而标签取的是 `L(gesture.locKey)` —— 接错档位就是「读上滚、按下滚」。
    @MainActor
    func testThumbViewShowsItsOwnDirectionText() throws {
        let up = InstantGestureThumbView(gesture: .wheelUp, frame: NSRect(x: 0, y: 0, width: 84, height: 84))
        let down = InstantGestureThumbView(gesture: .wheelDown, frame: NSRect(x: 0, y: 0, width: 84, height: 84))

        let upLabel = try XCTUnwrap(labelText(of: up))
        let downLabel = try XCTUnwrap(labelText(of: down))
        XCTAssertEqual(upLabel, L(InstantGesture.wheelUp.locKey), "上滚这格的字不是文案表里那一句")
        XCTAssertEqual(downLabel, L(InstantGesture.wheelDown.locKey), "下滚这格的字接错了档位")
        XCTAssertNotEqual(upLabel, downLabel, "两档显示同一句：用户读不出区别")

        // 文字行在格子的下半（上面那条几何判据是纯函数，这一条钉的是**装出来的视图**）。
        let field = try XCTUnwrap(up.subviews.first { $0 is NSTextField })
        XCTAssertLessThan(field.frame.midY, up.bounds.midY)
    }

    // MARK: - 面板里那一栏的格子

    @MainActor
    func testPickerCellCarriesItsDirectionToPointerAndReader() throws {
        let up = InstantGestureCell(gesture: .wheelUp, frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        let down = InstantGestureCell(gesture: .wheelDown, frame: NSRect(x: 0, y: 0, width: 56, height: 56))

        XCTAssertEqual(up.gesture, .wheelUp)
        XCTAssertEqual(down.gesture, .wheelDown)
        let tip = try XCTUnwrap(up.toolTip)
        XCTAssertEqual(tip, L(InstantGesture.wheelUp.locKey), "悬停提示没取自己那一档的文案")
        XCTAssertNotEqual(tip, down.toolTip, "两档悬停提示同一个词")
        XCTAssertEqual(up.accessibilityLabel(), L(InstantGesture.wheelUp.locKey))
        XCTAssertNotEqual(Set([up, down].map { $0.accessibilityLabel() }).count, 1,
                          "读屏里两档同名：按下去才知道换了")
        XCTAssertFalse(up.acceptsFirstResponder, "格子抢焦点：Tab 走位会停在一格图标上")
    }

    /// 点一格 = 选中并关面板（`target`/`action` 由面板接）。这根线断了的话，
    /// 那一栏就成了一排看得到点不动的图标。
    @MainActor
    func testPickerCellFiresItsActionOnMouseDown() throws {
        let cell = InstantGestureCell(gesture: .wheelDown, frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        let handler = ClickHandler()
        cell.target = handler
        cell.action = #selector(ClickHandler.hit(_:))

        cell.mouseDown(with: try mouseEvent(.leftMouseDown, clickCount: 1))

        let sender = try XCTUnwrap(handler.lastSender, "点这一格没送出 action")
        XCTAssertTrue(sender === cell, "送出去的不是被点的那格")
    }

    // MARK: - 脚手架

    private final class WhiteBox: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            dirtyRect.fill()
        }
    }

    private final class ClickHandler: NSObject {
        var lastSender: AnyObject?
        @objc func hit(_ sender: InstantGestureCell) { lastSender = sender }
    }

    private func mouseEvent(_ type: NSEvent.EventType, clickCount: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         eventNumber: 0, clickCount: clickCount, pressure: 1),
                      "造不出鼠标事件：这一条判据压根没跑")
    }

    /// 把规则页那一格（含它自己的文字行）渲进白底，导 PNG 供人工核对。
    @MainActor
    private func render(_ gesture: InstantGesture, name: String) throws -> NSBitmapImageRep {
        let side = Self.cellSide
        let box = WhiteBox(frame: NSRect(x: 0, y: 0, width: side, height: side))
        let thumb = InstantGestureThumbView(gesture: gesture, frame: box.bounds)
        thumb.autoresizingMask = [.width, .height]
        box.addSubview(thumb)

        let window = NSWindow(contentRect: box.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = box
        window.layoutIfNeeded()
        box.needsDisplay = true

        let rep = try XCTUnwrap(box.bitmapImageRepForCachingDisplay(in: box.bounds),
                                "渲不出位图：视图没挂上窗口")
        box.cacheDisplay(in: box.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: Self.exportDir,
                                                withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(Self.exportDir)/\(name).png"))
        return rep
    }

    /// `band` 是**位图高度比例**区间（写死像素换台机器带子就飘，本机 backingScale 1.0、
    /// Retina 上是 2.0）。列带同理，默认整宽。
    private func rows(of band: ClosedRange<Double>, in rep: NSBitmapImageRep) -> (Int, Int) {
        (Int(band.lowerBound * Double(rep.pixelsHigh)),
         min(Int(band.upperBound * Double(rep.pixelsHigh)), rep.pixelsHigh))
    }

    private func columns(of band: ClosedRange<Double>, in rep: NSBitmapImageRep) -> (Int, Int) {
        (Int(band.lowerBound * Double(rep.pixelsWide)),
         min(Int(band.upperBound * Double(rep.pixelsWide)), rep.pixelsWide))
    }

    /// 这一带有墨的点：非白且 alpha 有效。
    private func ink(_ rep: NSBitmapImageRep, band: ClosedRange<Double>,
                     columns columnBand: ClosedRange<Double> = 0.00 ... 1.00) throws -> Int {
        let (lo, hi) = rows(of: band, in: rep)
        let (xLo, xHi) = columns(of: columnBand, in: rep)
        var count = 0
        for y in lo..<max(hi, lo) {
            for x in xLo..<max(xHi, xLo) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.05, color.brightnessComponent < 0.85 { count += 1 }
            }
        }
        return count
    }

    /// 以视图坐标（84×84 的格子）数一个小矩形里的墨点。位图行自上而下，这里翻一次；
    /// 边界按 floor/ceil 取整（盒子往往只有一两个像素宽，截断会把整条撇漏掉）。
    private func inkInViewRect(_ rep: NSBitmapImageRep, _ r: NSRect,
                               in bounds: NSRect) throws -> Int {
        let scale = Double(rep.pixelsWide) / Double(bounds.width)
        let x0 = max(0, Int(floor(Double(r.minX) * scale)))
        let x1 = min(rep.pixelsWide, Int(ceil(Double(r.maxX) * scale)))
        let rowScale = Double(rep.pixelsHigh) / Double(bounds.height)
        let y0 = max(0, Int(floor(Double(bounds.height - r.maxY) * rowScale)))
        let y1 = min(rep.pixelsHigh, Int(ceil(Double(bounds.height - r.minY) * rowScale)))
        var count = 0
        for y in y0..<max(y1, y0) {
            for x in x0..<max(x1, x0) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.05, color.brightnessComponent < 0.85 { count += 1 }
            }
        }
        return count
    }

    private func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                               band: ClosedRange<Double>,
                               columns columnBand: ClosedRange<Double> = 0.00 ... 1.00) throws -> Int {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh)
        let (lo, hi) = rows(of: band, in: a)
        let (xLo, xHi) = columns(of: columnBand, in: a)
        var count = 0
        for y in lo..<max(hi, lo) {
            for x in xLo..<max(xHi, xLo) {
                guard let left = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let right = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(left.redComponent - right.redComponent),
                                abs(left.greenComponent - right.greenComponent),
                                abs(left.blueComponent - right.blueComponent))
                if delta > 0.03 { count += 1 }
            }
        }
        return count
    }

    /// 从这格视图里读它自己写出来的那句字（取视图的子视图，不取 `gesture` 字段 ——
    /// 后者是被测对象自己的说法，判据要落在画面上）。
    private func labelText(of view: NSView) -> String? {
        (view.subviews.first { $0 is NSTextField } as? NSTextField)?.stringValue
    }

    private struct StubFailure: Error { let message: String }
}
