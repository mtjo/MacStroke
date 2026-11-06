//
//  ScreenshotWindowRaiser.swift
//  MacStroke
//
//  定格之前把「光标下那扇被压住的窗」提到最前（2026-11-05 用户要求，默认开）。
//
//  为什么非得在定格前：截图拍的是快捷键按下那一瞬的一帧，之后遮罩里的一切都是这张
//  静止图。定格后再提窗，画面不会跟着变，吸附框圈的还是原来的位置 —— 看起来像提了，
//  截出来照样只有露着的那半扇。
//
//  两条与 FocusMover 同源的实测规矩（那一段的注释里有探针数据，改这里前先读）：
//  1. 只 `AXRaise` 那扇窗改不了前台 —— 真正生效的是写应用元素的 `AXFrontmost`。
//     AXRaise 仍然要做：同一家 App 里可以精确把目标那扇抬到兄弟窗前面。
//  2. 成没成不能问 `NSWorkspace.frontmostApplication` / `isActive`：前者同一瞬还报
//     旧家，后者是异步通知喂的缓存。判据取窗口服务里「光标下第一个够格的窗」是不是
//     目标编号，且目标前面不再有同层相交的候选窗（isAheadOfSameLayerCovers）。
//     判据绿了还不够：前后顺序落进 CGWindowList 与它被合成到屏幕上不是同一刻，
//     所以确认后再让出 compositorSettle，否则抓帧抢在旧画面那帧上（装机实测）。
//
//  认窗按矩形对（AXPosition/AXSize 与 CGWindowBounds 都是主屏左上原点）。认不出就只
//  写 AXFrontmost 把整家提上来：单窗 App 这就够了，多窗 App 里至少能压过别家。没有
//  辅助功能权限时 AX 调用失败，整手静默跳过 —— 截图照常拍，不弹框、不报错。
//

import AppKit
import ApplicationServices
import CoreGraphics

enum ScreenshotWindowRaiser {
    /// 单次 AX 调用的上限。这一段就在快捷键回调上，目标进程卡住时这边不能跟着卡。
    static let messagingTimeout: Float = 0.15
    /// 从动手到放行抓帧的等待上限。FocusMover 实测跳转 1～94ms，150ms 足够；
    /// 超时就不再等 —— 宁可当没提成，也不能为了提窗把截图拖住。
    static let budget: TimeInterval = 0.15
    /// 轮询间隔：窗口服务的前后顺序是异步落下来的，5ms 一格够快也不至于问烦。
    static let pollIntervalMicroseconds: UInt32 = 5_000
    /// 顺序确认之后再放的这一小段。CGWindowList 里的前后顺序是当场就变的，但
    /// 屏幕上那帧要等窗口服务下一次合成才换 —— CGDisplayCreateImage 抓的是呈现出来的
    /// 帧，不是刚提交的顺序。2026-11-05 装机实测：新判据报「已到最前」，冻结画面里却
    /// 还是原来那半扇。60Hz 下 50ms 是 3 帧，足够让新顺序进到下一次呈现。
    static let compositorSettle: TimeInterval = 0.05
    /// 矩形配对余量。AX 与 CGWindowList 对阴影/边框的口径偶尔差一两点。
    static let frameTolerance: CGFloat = 4

    /// 提窗并等新的前后顺序落下来。返回 true = 已确认挡在目标前面的同层窗都没了。
    /// 失败不抛也不回滚：冻结帧拍原来的样子，等于这一手没发生。
    @discardableResult
    static func raise(_ target: ScreenshotProbeWindow, pointer: CGPoint) -> Bool {
        if target.isOwnProcess {
            raiseOwn(target)
        } else {
            // 没授权时 AX 调用只是静默返回错误，白白等满 150ms。这里先问一句，把
            // 原因写进日志：装机后「开关开了却没效果」第一个该排除的就是这条。
            guard AXIsProcessTrusted() else {
                NSLog("%@", "[Screenshot] 提窗：没有辅助功能权限，跳过（系统设置 → 隐私与安全性 → 辅助功能）")
                return false
            }
            raiseOther(target)
        }
        return waitUntilFront(target, pointer: pointer)
    }

    /// 自家窗不走 AX：同一进程里按 windowNumber 拿实例，直接激活 + 置前。
    private static func raiseOwn(_ target: ScreenshotProbeWindow) {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.windowNumber == target.windowNumber
        }) else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func raiseOther(_ target: ScreenshotProbeWindow) {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var raised: AXError?
        if let window = matchingWindow(app: app, bounds: target.globalBounds) {
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
            raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        let front = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        // 认不到那扇窗（raised 为 nil）时只剩 AXFrontmost 把整家提上来；单窗 App
        // 够用，多窗 App 可能提错窗 —— 两个错误码都留进日志，免得又变成「没效果」。
        if raised != .success || front != .success {
            let raiseText = raised.map { String($0.rawValue) } ?? "未认到窗"
            NSLog("%@", "[Screenshot] 提窗 pid \(target.pid)：AXRaise=\(raiseText) "
                  + "AXFrontmost=\(front.rawValue)")
        }
    }

    /// 在目标 App 的无障碍树里按全局矩形认那扇窗。认不出返回 nil（只靠 AXFrontmost）。
    private static func matchingWindow(app: AXUIElement, bounds: CGRect) -> AXUIElement? {
        guard let windows = copyValue(app, "AXWindows") as? [AXUIElement] else { return nil }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
            guard let position = pointValue(window, kAXPositionAttribute),
                  let size = sizeValue(window, kAXSizeAttribute) else { continue }
            let frame = CGRect(origin: position, size: size)
            if abs(frame.minX - bounds.minX) <= frameTolerance,
               abs(frame.minY - bounds.minY) <= frameTolerance,
               abs(frame.width - bounds.width) <= frameTolerance,
               abs(frame.height - bounds.height) <= frameTolerance {
                return window
            }
        }
        return nil
    }

    /// 等到目标前面不再有同层相交的候选窗。超时返回 false。
    ///
    /// 注意别退回「光标下第一个够格的窗是不是它」：目标被挑出来时那一条本来就成立，
    /// 提窗失败也成立，用它会把失败报成成功（见 isAheadOfSameLayerCovers 的注释）。
    private static func waitUntilFront(_ target: ScreenshotProbeWindow, pointer: CGPoint) -> Bool {
        let start = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000
        while true {
            let windows = ScreenshotWindowProbe.snapshot()
            if ScreenshotWindowProbe.frontmostCandidate(at: pointer, in: windows)?.windowNumber
                == target.windowNumber,
               ScreenshotWindowProbe.isAheadOfSameLayerCovers(target, in: windows) {
                // 顺序已经落了，但呈现还差一帧：见 compositorSettle。
                usleep(UInt32(compositorSettle * 1_000_000))
                return true
            }
            if Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000 - start >= budget * 1000 {
                return false
            }
            usleep(pollIntervalMicroseconds)
        }
    }

    private static func copyValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func pointValue(_ element: AXUIElement, _ key: String) -> CGPoint? {
        guard let raw = copyValue(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeValue(_ element: AXUIElement, _ key: String) -> CGSize? {
        guard let raw = copyValue(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
