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
//  抓取和筛选分成两层：`snapshot()` 只负责问 WindowServer，`candidateRects`
//  是纯函数。筛选条件（桌面层、半透明、太小的）要能被确定地取证 —— 真桌面上
//  「那个位置恰好有个别人的窗」会让断言变成误报。
//
//  同一张表还用来判「定格前要不要把那扇窗提到最前」：`raiseTarget` 是纯函数，
//  真动手在 ScreenshotWindowRaiser（AX）。两张判据共用 `isSnapCandidate`，所以
//  「能吸的窗」和「会提的窗」永远是同一批。
//
//  两条与自家关的规矩（2026-11-04 用户实测「偏好设置不能智能框选」「历史粘贴板
//  弹窗也不吸附」）：
//  - **自家窗不按 pid 筛**：偏好设置（layer 0）、贴图（3）、历史粘贴板（21）都是
//    用户想截的。别家仍只吸普通层，否则程序坞那条整屏矩形会让「停哪都吸整屏」。
//  - **只吸进得了冻结帧的窗**：自家的画布、截图遮罩、录屏描边/胶囊、划词气泡都
//    设了 `sharingType = .none`（不进采集），吸附上去只能圈到它们背后那层画面。
//    `NSWindow.sharingType` 是本进程的一手事实；`kCGWindowSharingState` 不可靠 ——
//    探测进程没有录屏权限时，连自家普通窗都报 0（2026-11-04 实测）。
//

import AppKit
import CoreGraphics

/// 一条来自 WindowServer 的窗口记录，已经抽掉「字典取值」这种不可控的部分。
struct ScreenshotProbeWindow {
    let globalBounds: CGRect
    let layer: Int
    let alpha: Double
    /// 自家进程的窗。**不按 pid 筛**：只用来放宽层级门槛（自家浮窗也要能吸）。
    let isOwnProcess: Bool
    /// 这扇窗会不会出现在冻结帧里。别家的窗一律视为可见；自家窗按
    /// `NSWindow.sharingType != .none` 判定（见文件头）。
    let isCapturable: Bool
    /// 提窗要按 pid 找应用、按编号在自家 `NSApplication.windows` 里认窗。
    let pid: pid_t
    let windowNumber: Int
}

public enum ScreenshotWindowProbe {
    /// 一条吸附候选：绘制要的视图矩形 + 提窗要的窗记录（编号/pid/全局矩形）。
    /// 两者必须成对发出去 —— 只给矩形的话，悬停时没法回答「吸到的是哪一扇」。
    struct SnapCandidate {
        let window: ScreenshotProbeWindow
        let rect: CGRect
    }

    /// 目标屏上可吸附的窗口，按**遮罩视图坐标**给出，顺序从最前台往后。
    public static func candidateRects(screenFrame: NSRect) -> [CGRect] {
        candidates(screenFrame: screenFrame,
                   mainTop: CGDisplayBounds(CGMainDisplayID()).height).map(\.rect)
    }

    static func candidateRects(windows: [ScreenshotProbeWindow], screenFrame: NSRect,
                               mainTop: CGFloat) -> [CGRect] {
        candidates(windows: windows, screenFrame: screenFrame, mainTop: mainTop).map(\.rect)
    }

    /// 带窗记录的候选表。悬停吸附要用它回答「吸到的是哪一扇」，提窗链路据此找编号。
    static func candidates(screenFrame: NSRect, mainTop: CGFloat) -> [SnapCandidate] {
        candidates(windows: snapshot(), screenFrame: screenFrame, mainTop: mainTop)
    }

    static func candidates(windows: [ScreenshotProbeWindow], screenFrame: NSRect,
                           mainTop: CGFloat) -> [SnapCandidate] {
        let visible = CGRect(origin: .zero, size: screenFrame.size)
        return windows.compactMap { window -> SnapCandidate? in
            guard isSnapCandidate(window) else { return nil }
            let rect = viewRect(fromGlobalBounds: window.globalBounds, screenFrame: screenFrame,
                                mainTop: mainTop)
            guard rect.intersects(visible) else { return nil }
            return SnapCandidate(window: window, rect: rect)
        }
    }

    /// 一扇窗够不够格进吸附表/参与提窗。**不**看它在哪块屏上、鼠标在不在里面 ——
    /// 那两件事由调用方补。冻结帧里没有的窗不能吸：自家画布/遮罩/描边/气泡是 `.none`，
    /// 圈上去只会截到它们背后那层画面。层级门槛见候选过滤的注释。
    static func isSnapCandidate(_ window: ScreenshotProbeWindow) -> Bool {
        guard window.isCapturable, window.alpha >= 0.99 else { return false }
        // 别家只吸普通窗（layer 0）。实测本机 24 条在屏记录里：菜单栏项 25、菜单栏本体 24、
        // 程序坞 20 —— 而程序坞那条是 1920×1080 的**整屏**矩形，排在所有普通窗前面，
        // 留着就等于「鼠标停哪都吸附整屏」。自家放宽到菜单栏之下：偏好设置 0、贴图 3、
        // 历史粘贴板 21 都要能吸；状态栏项 25、Toast 101 不吸。
        guard window.layer == 0 || (window.isOwnProcess && window.layer < 25) else { return false }
        // 8px 以下的多半是阴影层、拖拽残影这类没内容的壳。
        return window.globalBounds.width >= 8 && window.globalBounds.height >= 8
    }

    /// 光标下最前台的那扇**够格的**窗。没有就 nil（桌面、菜单栏、只在别的层上的浮层）。
    static func frontmostCandidate(at point: CGPoint, in windows: [ScreenshotProbeWindow]) -> ScreenshotProbeWindow? {
        windows.first { isSnapCandidate($0) && $0.globalBounds.contains(point) }
    }

    /// 定格**之前**该把哪扇窗提到最前；nil = 不动。
    ///
    /// 只看「光标下最前台的那一扇」，并且只在它被**同一层**的窗压住时才动：
    /// - 更前的那扇窗层级更高（贴图、面板这类浮窗）时，把普通窗提上来也压不过它 ——
    ///   那一帧里照样是浮窗在上，白切一次前台。
    /// - 自己没被压住时提窗只会把前台 App 无缘无故换一家，冻结帧一模一样。
    /// 坐标用 CGWindowList 的全局左上原点；调用方把 AppKit 的鼠标位置换算过来。
    static func raiseTarget(windows: [ScreenshotProbeWindow], point: CGPoint) -> ScreenshotProbeWindow? {
        guard let index = windows.firstIndex(where: {
            isSnapCandidate($0) && $0.globalBounds.contains(point)
        }) else { return nil }
        let target = windows[index]
        let covered = windows[..<index].contains {
            isSnapCandidate($0) && $0.layer == target.layer
                && $0.globalBounds.intersects(target.globalBounds)
        }
        return covered ? target : nil
    }

    /// 提窗之后这条才算数：目标前面不再有**同层**且与它相交的候选窗。
    ///
    /// 别拿「光标下第一个够格的窗是不是它」当成功判据 —— `raiseTarget` 挑中它的那一
    /// 刻这句就成立（压着它的那扇并不含光标点），提窗完全失败也照样成立，是自证的
    /// 假绿。2026-11-05 装机实测就是这么把「AX 没提起来」报成「已到最前」的。
    static func isAheadOfSameLayerCovers(_ target: ScreenshotProbeWindow,
                                         in windows: [ScreenshotProbeWindow]) -> Bool {
        guard let index = windows.firstIndex(where: {
            $0.windowNumber == target.windowNumber
        }) else { return false }
        return !windows[..<index].contains {
            isSnapCandidate($0) && $0.layer == target.layer
                && $0.globalBounds.intersects(target.globalBounds)
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
    static func snapshot() -> [ScreenshotProbeWindow] {
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]]) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // 自家特意不进采集的窗（画布、遮罩、描边、胶囊、气泡）。按 windowNumber 对，
        // 因为 CGWindowList 只给编号，拿不到 NSWindow 实例。用 `NSApplication.shared`
        // 而不是 `NSApp`：桩件里是裸进程，`NSApp` 可能是 nil。
        let uncapturable = Set(NSApplication.shared.windows
            .filter { $0.sharingType == .none }.map(\.windowNumber))
        return infos.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            let isOwn = pid == ownPID
            return ScreenshotProbeWindow(globalBounds: bounds, layer: layer, alpha: alpha,
                                         isOwnProcess: isOwn,
                                         isCapturable: !(isOwn && uncapturable.contains(number)),
                                         pid: pid, windowNumber: number)
        }
    }
}
