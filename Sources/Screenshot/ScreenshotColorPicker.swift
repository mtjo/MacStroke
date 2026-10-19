//
//  ScreenshotColorPicker.swift
//  MacStroke
//
//  调色板最后一格（那枚彩色块）唤出来的自定义取色（用户 2026-10-19：「点击彩色按钮
//  可以自定义颜色」）。
//
//  为什么单独一层协议：真正给用户选色的是系统的 `NSColorPanel`，它不在这个视图的
//  `draw(_:)` 里 —— 离屏取证拍不到它，但「挑回来的颜色进的是主色还是边框」必须能验。
//  所以面板只认这个接缝，测试换一个记账的替身进来，真机上用它下面那个 `SystemColorPicker`。
//
//  `SystemColorPicker` 里最要紧的是那一行 `level`：遮罩窗挂在 CGShieldingWindowLevel，
//  系统面板按默认等级弹会被整块压在遮罩底下 —— 用户看到的是「点了彩色块啥也没发生」。
//

import AppKit
import Storage

/// 一个自定义取色器。`show` 允许连着回吐多次（在色轮上拖动要实时变）。
public protocol ScreenshotColorPicking: AnyObject {
    /// 弹起来给用户挑色。`initial` 是当前落点上那枚颜色：已经自定义过红色的用户再点
    /// 彩色格，取色器该开在红上，不是开在默认黑上。
    func show(initial: NSColor, changed: @escaping (NSColor) -> Void)
    /// 收掉。面板收起、换工具、整次截图结束时都得有人喊它，不然取色面板会飘在那儿。
    func dismiss()
}

/// 系统 `NSColorPanel` 那一套。
final class SystemColorPicker: ScreenshotColorPicking {
    private var changed: ((NSColor) -> Void)?

    func show(initial: NSColor, changed handler: @escaping (NSColor) -> Void) {
        changed = handler
        let panel = NSColorPanel.shared
        panel.title = L("Screenshot Custom Color")
        // 注解颜色不要 alpha：alpha 走进成品图就是半透明一笔，条子上没有哪一格解释过它。
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        // 先挂 action 再设色：反过来会把这一句当成「用户挑了一次」记进回吐里。
        panel.color = initial
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        changed = nil
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        changed?(sender.color)
    }
}
