//
//  ScreenshotWindowProbe.swift
//  MacStroke
//
//  悬停吸附的数据来源：把「此刻屏上有哪些窗」列成遮罩视图坐标的矩形表。
//  QQ/微信截图划过屏幕时整块窗口被点亮、点一下就选中，靠的就是这张表。
//
//  表只在**定格那一帧时**取一次，之后不刷新：底图已经静止，窗口列表跟着一起静止
//  才不会错位（边划边刷会圈住一个早就关掉的窗）。
//
//  坐标系是这里唯一的坑，两种全局坐标不一样：
//  - CGWindowList 的 `kCGWindowBounds`：主屏**左上角**为原点，y 向下。
//  - 遮罩视图：当前那块屏的左上角为原点，y 向下（flipped NSView）。
//  副屏的 frame.origin 可正可负、还可能在主屏上方，所以既要减屏偏移、也要补主屏
//  高度差，见 viewRect(fromGlobalBounds:)。
//
//  抓取和筛选分成两层：`snapshotWindows()` 只负责问 WindowServer，`candidateRects`
//  是纯函数。筛选条件（自家窗、桌面层、半透明、太小的）要能被确定地取证 —— 真桌面上
//  「那个位置恰好有个别人的窗」会让断言变成误报。
//

import AppKit
import CoreGraphics

/// 一条来自 WindowServer 的窗口记录，已经抽掉「字典取值」这种不可控的部分。
struct ScreenshotProbeWindow {
    let globalBounds: CGRect
    let layer: Int
    let alpha: Double
    /// 自家进程的窗：画布、偏好窗这些吸附上去没意义。
    let isOwnProcess: Bool
}

public enum ScreenshotWindowProbe {
    /// 目标屏上可吸附的窗口，按**遮罩视图坐标**给出，顺序从最前台往后。
    public static func candidateRects(screenFrame: NSRect) -> [CGRect] {
        candidateRects(windows: snapshotWindows(), screenFrame: screenFrame,
                       mainTop: CGDisplayBounds(CGMainDisplayID()).height)
    }

    static func candidateRects(windows: [ScreenshotProbeWindow], screenFrame: NSRect,
                               mainTop: CGFloat) -> [CGRect] {
        let visible = CGRect(origin: .zero, size: screenFrame.size)
        return windows.compactMap { window -> CGRect? in
            // 只吸普通窗（layer 0）。实测本机 24 条在屏记录里：菜单栏项 25、菜单栏本体
            // 24、程序坞 20 —— 而程序坞那条是 1920×1080 的**整屏**矩形，排在所有普通窗
            // 前面。留着 layer > 0 就等于「鼠标停哪都吸附整屏」，等于没有吸附。
            guard !window.isOwnProcess, window.layer == 0, window.alpha >= 0.99 else { return nil }
            let rect = viewRect(fromGlobalBounds: window.globalBounds, screenFrame: screenFrame,
                                mainTop: mainTop)
            // 8px 以下的多半是阴影层、拖拽残影这类没内容的壳。
            guard rect.width >= 8, rect.height >= 8, rect.intersects(visible) else { return nil }
            return rect
        }
    }

    /// 鼠标所在处最前台的那个窗。没有就返回 nil —— 调用方据此落到「吸整块屏」那一路
    /// （见 ScreenshotSelectionView.pointerMoved），别在这里塞兜底矩形：候选表必须
    /// 只有真窗，否则「吸附到了窗」和「吸附到整屏」就分不出来了。
    static func rect(containing point: CGPoint, in candidates: [CGRect]) -> CGRect? {
        candidates.first { $0.contains(point) }
    }

    /// CGWindowList 的全局矩形 → 遮罩视图矩形。两个坐标都 y 向下，所以宽高不变，
    /// 只剩平移：x 去掉屏偏移，y 把「相对主屏顶」换成「相对本屏顶」。
    static func viewRect(fromGlobalBounds bounds: CGRect, screenFrame: NSRect, mainTop: CGFloat) -> CGRect {
        CGRect(x: bounds.minX - screenFrame.minX,
               y: bounds.minY + screenFrame.maxY - mainTop,
               width: bounds.width, height: bounds.height)
    }

    /// 在屏窗口的原始记录。顺序即前后顺序（CGWindowList 保证从最前台往后排）。
    /// 必须在遮罩开窗**之前**调用，否则这张表里会混进自家那层全屏遮罩。
    private static func snapshotWindows() -> [ScreenshotProbeWindow] {
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]]) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return infos.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return ScreenshotProbeWindow(globalBounds: bounds, layer: layer, alpha: alpha,
                                         isOwnProcess: pid == ownPID)
        }
    }
}
