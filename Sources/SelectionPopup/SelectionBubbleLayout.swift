//
//  SelectionBubbleLayout.swift
//
//  气泡的尺子：胶囊多大、摆在鼠标点的哪一边。纯函数，屏幕坐标进、矩形出。
//
//  坐标一律是 AppKit 那套（原点在主屏左下角，y 向上），和 `NSEvent.mouseLocation`、
//  `NSScreen.visibleFrame`、`NSWindow.setFrame` 同一空间，中间不翻转，免得翻转做两次
//  就成了「气泡跑到屏幕外」。
//
//  为什么贴着鼠标点而不是框住那段文字：无障碍接口给的是选区的**字符范围**和整个控件的
//  位置尺寸，独独不给「被选中那一段」在屏幕上的矩形（要自己按行盒算，而 WebArea 那套行盒
//  又拿不全）。所以一期只做到「不压住刚选的字」，不承诺框住它。
//

import AppKit
import CoreGraphics

enum SelectionBubbleLayout {
    /// 一格：34 宽 30 高，和截图注解条的格子同一量级（那儿的 32x30 已经装机验证过手感）。
    static let cellSize = CGSize(width: 34, height: 30)
    /// 胶囊两端留白：图标不贴圆弧。
    static let edgePadding: CGFloat = 8
    /// 气泡离鼠标点的缝：贴着摆会让人以为气泡是从指针上长出来的，也挡住所指的行。
    static let gap: CGFloat = 14
    /// 离屏边至少留这么多：完全贴边会被 Dock 和菜单栏挤掉一格。
    static let screenMargin: CGFloat = 8

    static func capsuleWidth(cellCount: Int) -> CGFloat {
        max(0, CGFloat(cellCount)) * cellSize.width + edgePadding * 2
    }

    static func capsuleSize(cellCount: Int) -> CGSize {
        CGSize(width: capsuleWidth(cellCount: cellCount), height: cellSize.height)
    }

    /// 第 `index` 格在视图坐标里的位置。视图是 flipped 的（和注解条一致），所以 y 从顶部算。
    static func cellFrame(index: Int, cellCount: Int) -> NSRect {
        let size = capsuleSize(cellCount: cellCount)
        return NSRect(x: edgePadding + CGFloat(index) * cellSize.width,
                      y: (size.height - cellSize.height) / 2,
                      width: cellSize.width, height: cellSize.height)
    }

    /// 气泡整扇窗的位置。首选摆在鼠标点**上方**：划完词手要往回挪去点格子，气泡压在刚选的那
    /// 一行上就等于自己挡自己。上方放不下（贴着菜单栏）就翻到下方；横向钳在屏内。
    ///
    /// 返回的矩形永远不含 `anchor`（这一条有取证的用例盯着，见 M36）。
    static func panelFrame(anchor: CGPoint, cellCount: Int, visible: NSRect) -> NSRect {
        let size = capsuleSize(cellCount: cellCount)
        var y = anchor.y + gap
        if y + size.height > visible.maxY - screenMargin {
            y = anchor.y - gap - size.height
        }
        let x = clampedX(center: anchor.x, width: size.width, in: visible)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 横向居中后钳进屏内。`max(..., visible.minX + screenMargin)` 那一层是给窄屏留的：
    /// 上下界反过来时（右界 < 左界）不加这层就会算出一个负 x，气泡整个跑到屏幕左边外。
    static func clampedX(center: CGFloat, width: CGFloat, in visible: NSRect) -> CGFloat {
        let left = visible.minX + screenMargin
        let right = max(visible.maxX - screenMargin - width, left)
        return min(max(center - width / 2, left), right)
    }
}
