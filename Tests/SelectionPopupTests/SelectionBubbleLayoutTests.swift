//
//  SelectionBubbleLayoutTests.swift
//  SelectionPopupTests
//
//  气泡摆位的取证。全部是屏幕坐标（原点主屏左下角），和 `NSEvent.mouseLocation`、
//  `NSScreen.visibleFrame` 同一空间。
//
//  两条最贵的：
//  - **M36 不许压住鼠标点**：气泡盖在刚选的那一行上就等于自己挡自己，还顺手把「点别处收气泡」
//    变成「点自己」。这里用一张铺满可见区的锚点网格逐点验，不挑几个点意思意思。
//  - **M37 不许抢焦点、不许盖满屏**：那一档数值写错（`.floating` 换成 CGShieldingWindowLevel、
//    `.nonactivatingPanel` 掉了）在界面上是「点一下气泡，前台 App 的 ⌘C 就打到我们头上了」，
//    或者「整屏被压住」，都属于装机才发现的那类。
//

import AppKit
import XCTest
@testable import SelectionPopup

final class SelectionBubbleLayoutTests: XCTestCase {
    /// 一块 1920x1080 的可见区（顶部让出 25pt 菜单栏、底部让出 60pt Dock）。
    private let visible = NSRect(x: 0, y: 60, width: 1920, height: 995)
    private let cellCount = SelectionBubbleItem.defaultItems.count

    /// 胶囊宽度 = 格子数 × 34 + 两端留白。少算一格就多一块空白，多算一格就挤掉图标。
    func testCapsuleWidthScalesWithTheCellCount() {
        XCTAssertEqual(SelectionBubbleLayout.capsuleWidth(cellCount: 4), 4 * 34 + 2 * 8)
        XCTAssertEqual(SelectionBubbleLayout.capsuleSize(cellCount: 4),
                       CGSize(width: 152, height: 30))
        XCTAssertEqual(SelectionBubbleLayout.capsuleWidth(cellCount: 0), 16)
        // 负数格子不该算出负宽度（ CGRect 宽度为负会把取样点整个带偏，截图那条线见过）。
        XCTAssertEqual(SelectionBubbleLayout.capsuleWidth(cellCount: -3), 16)
    }

    /// 四格紧贴排开、都落在胶囊内、互不重叠 —— 有点重叠就是「点了左边那格执行了右边那件事」。
    func testCellsTileTheCapsuleWithoutOverlap() {
        let capsule = NSRect(origin: .zero, size: SelectionBubbleLayout.capsuleSize(cellCount: cellCount))
        var frames: [NSRect] = []
        for index in 0 ..< cellCount {
            let frame = SelectionBubbleLayout.cellFrame(index: index, cellCount: cellCount)
            XCTAssertTrue(capsule.contains(frame), "第 \(index) 格跑出胶囊了：\(frame)")
            XCTAssertEqual(frame.width, SelectionBubbleLayout.cellSize.width)
            XCTAssertEqual(frame.minX, 8 + CGFloat(index) * 34)
            for other in frames {
                XCTAssertFalse(other.intersects(frame), "第 \(index) 格和前一格重叠")
            }
            frames.append(frame)
        }
    }

    /// 中间位置：摆在鼠标点**上方**，缝 14pt。
    func testBubbleSitsAboveTheAnchorInTheMiddleOfTheScreen() {
        let anchor = CGPoint(x: 900, y: 500)
        let frame = SelectionBubbleLayout.panelFrame(anchor: anchor, cellCount: cellCount, visible: visible)
        XCTAssertEqual(frame.minY, anchor.y + SelectionBubbleLayout.gap)
        XCTAssertEqual(frame.midX, anchor.x, accuracy: 0.5, "横向以鼠标点居中")
    }

    /// 顶到菜单栏那一档：翻到下方，别把气泡推出屏外。
    func testBubbleFlipsBelowWhenTheTopEdgeIsTooClose() {
        let anchor = CGPoint(x: 900, y: visible.maxY - 5)
        let frame = SelectionBubbleLayout.panelFrame(anchor: anchor, cellCount: cellCount, visible: visible)
        XCTAssertLessThan(frame.maxY, anchor.y, "上方放不下就该翻到下面")
        XCTAssertEqual(frame.maxY, anchor.y - SelectionBubbleLayout.gap, accuracy: 0.001)
        XCTAssertFalse(frame.contains(anchor))
    }

    /// **M36**：一张铺满可见区的锚点网格，逐点确认矩形不含鼠标点。
    /// 只挑两三颗点的断言会被「刚好在那一档边界上」骗过去，网格才咬得住翻档那一条分支。
    func testTheBubbleNeverCoversTheAnchorAnywhereOnScreen() {
        var probes = 0
        for x in stride(from: visible.minX, through: visible.maxX, by: 51) {
            for y in stride(from: visible.minY, through: visible.maxY, by: 47) {
                let anchor = CGPoint(x: x, y: y)
                let frame = SelectionBubbleLayout.panelFrame(anchor: anchor, cellCount: cellCount, visible: visible)
                XCTAssertFalse(frame.contains(anchor), "气泡压住了鼠标点 (\(x), \(y))：\(frame)")
                // 顺手钉另一头：矩形整个落在可见区内。超出屏边那一档就是「气泡有一半看不见」，
                // 而 y 那一支没有任何钳制 —— 全靠「上方放不下才翻下方」这个顺序保证，所以值得逐点验。
                XCTAssertTrue(visible.contains(frame),
                              "气泡跑到可见区外了 (\(x), \(y))：\(frame)")
                probes += 1
            }
        }
        XCTAssertGreaterThan(probes, 400, "网格别退化成几个点")
    }

    /// 贴着左右屏边：横向钳进屏内，且钳完仍然不含锚点（y 那一档的分离是唯一的保证，
    /// x 钳过头也不会把气泡挪到指针底下，但这一条要看着它成立）。
    func testBubbleIsClampedHorizontallyAtTheScreenEdges() {
        let left = SelectionBubbleLayout.panelFrame(anchor: CGPoint(x: 2, y: 500),
                                                    cellCount: cellCount, visible: visible)
        XCTAssertEqual(left.minX, visible.minX + SelectionBubbleLayout.screenMargin)
        XCTAssertFalse(left.contains(CGPoint(x: 2, y: 500)))

        let width = SelectionBubbleLayout.capsuleWidth(cellCount: cellCount)
        let right = SelectionBubbleLayout.panelFrame(anchor: CGPoint(x: visible.maxX - 2, y: 500),
                                                     cellCount: cellCount, visible: visible)
        XCTAssertEqual(right.maxX, visible.maxX - SelectionBubbleLayout.screenMargin, accuracy: 0.001)
        XCTAssertEqual(right.width, width)
    }

    /// 窄屏（比胶囊还窄的可见区，外接屏竖着摆、或系统把可见区挤瘪了）：
    /// 上下界反过来时不加那一层 `max` 就会算出负 x，气泡整个跑到屏幕左边外。
    func testClampedXNeverGoesNegativeOnAnImpossiblyNarrowScreen() {
        let narrow = NSRect(x: 0, y: 0, width: 60, height: 400)
        let width: CGFloat = 152
        XCTAssertEqual(SelectionBubbleLayout.clampedX(center: 30, width: width, in: narrow), narrow.minX + 8)
        XCTAssertEqual(SelectionBubbleLayout.clampedX(center: 500, width: width, in: narrow), narrow.minX + 8)
        XCTAssertGreaterThanOrEqual(SelectionBubbleLayout.clampedX(center: -10_000, width: width, in: narrow), 0)

        let offscreen = NSRect(x: 1000, y: 0, width: 40, height: 400)
        XCTAssertEqual(SelectionBubbleLayout.clampedX(center: 0, width: width, in: offscreen), 1008,
                       "钳完至少落在那块屏自己的左沿内")
    }

    // MARK: - 浮窗档位（M37）

    /// 数值钉在常量上：`.floating` 而不是截图遮罩那档 `CGShieldingWindowLevel`。
    /// 气泡只要浮在内容上面就够，用遮罩那一档会把整屏压住。
    func testWindowConfigKeepsTheDocumentedWindowLevelAndMask() {
        XCTAssertEqual(SelectionBubbleWindowConfig.level, .floating)
        XCTAssertTrue(SelectionBubbleWindowConfig.styleMask.contains(.nonactivatingPanel),
                      "一激活就把焦点从那个文本 App 抢走")
        XCTAssertTrue(SelectionBubbleWindowConfig.styleMask.contains(.borderless))
        XCTAssertFalse(SelectionBubbleWindowConfig.styleMask.contains(.titled))
        XCTAssertEqual(SelectionBubbleWindowConfig.sharingType, .none, "气泡不进录屏和屏幕共享")
        XCTAssertTrue(SelectionBubbleWindowConfig.collectionBehavior.contains(.fullScreenAuxiliary),
                      "全屏 App 那一屏也要能弹，不然全屏读文档时功能是哑的")
        XCTAssertTrue(SelectionBubbleWindowConfig.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(SelectionBubbleWindowConfig.collectionBehavior.contains(.transient))
        XCTAssertFalse(SelectionBubbleWindowConfig.isOpaque)
        XCTAssertFalse(SelectionBubbleWindowConfig.hidesOnDeactivate)
    }

    /// 面板真的把上面那几项照抄了一遍 —— 常量对了但 init 里漏抄一项，界面上的表现和上面那条
    /// 断言毫无关系，所以这里连实例一起核。
    func testPanelCopiesEveryConfiguredWindowAttribute() {
        let panel = SelectionBubblePanel(cellCount: cellCount)
        XCTAssertEqual(panel.level, SelectionBubbleWindowConfig.level)
        XCTAssertEqual(panel.styleMask, SelectionBubbleWindowConfig.styleMask)
        XCTAssertEqual(panel.sharingType, SelectionBubbleWindowConfig.sharingType)
        XCTAssertEqual(panel.collectionBehavior, SelectionBubbleWindowConfig.collectionBehavior)
        XCTAssertEqual(panel.isOpaque, SelectionBubbleWindowConfig.isOpaque)
        XCTAssertEqual(panel.hidesOnDeactivate, SelectionBubbleWindowConfig.hidesOnDeactivate)
        XCTAssertFalse(panel.canBecomeKey, "抢了焦点，用户下一次 ⌘C 就打到我们头上了")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.contentView?.frame.size ?? .zero,
                       SelectionBubbleLayout.capsuleSize(cellCount: cellCount),
                       "窗尺寸跟胶囊尺寸同源，别一边写死")
    }

    /// **M38**：只读监听只收这三样左键事件。
    /// 多收一个（滚轮、右键、中键、mouseMoved）就是把手势那条线的邻居拖进这趟浑水；
    /// 少收一个 `.leftMouseDragged` 或 `.leftMouseUp`，判定那边永远只能看到单击。
    func testMonitorMaskIsExactlyTheThreeLeftButtonEvents() {
        let mask = SelectionBubbleController.monitorMask
        XCTAssertEqual(mask, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertTrue(mask.contains(.leftMouseUp), "松手那一笔必须收，不然永远只判定成没划过")
        XCTAssertTrue(mask.contains(.leftMouseDragged), "拖动那一笔必须收，不然永远只判定成单击")
        for extra: NSEvent.EventTypeMask in [.rightMouseDown, .rightMouseUp, .otherMouseDown,
                                             .otherMouseDragged, .scrollWheel, .mouseMoved, .keyDown] {
            XCTAssertFalse(mask.contains(extra),
                           "监听里多收了 \(extra.rawValue)，这一条会把无关事件拖进这条线")
        }
    }
}
