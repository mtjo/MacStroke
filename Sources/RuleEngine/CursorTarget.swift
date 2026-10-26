//
//  CursorTarget.swift
//  MacStroke
//
//  issue #22：把手势「归给光标下的那一扇窗」，而不是归给当前前台。
//
//  老行为是抬手那一刻读 `NSWorkspace.frontmostApplication`，规则按那一家匹配、注入的键也
//  按那一家落地 —— 于是「光标停在浏览器上画手势，快捷键却打进 IDE」。这一层把归属改读
//  「鼠标松手那个点下面最靠前的窗」，并在投动作之前把焦点挪过去。
//
//  抓取与判定分两半，一半都不碰系统状态：
//  - `CursorWindowProbe.onScreenWindows()` 只问 WindowServer 和 `NSRunningApplication`；
//  - `CursorTarget.attribute(...)` 是纯函数，输入是一张窗口表和几个 pid，输出是「归给谁」
//    加上「为什么」。装机时日志里要能分清「这功能没开」「那个位置压根没窗」「是我们自己的窗」
//    「本来就是同一家」「那家不是可激活的普通 App」，这五种在界面上长得一模一样（什么都没发生）。
//
//  只挪焦点、不挪指针，也绝不在判定阶段造任何副作用：原版
//  `CanvasWindowController.m:155-157` 那套「模拟一次左键把焦点骗过去」的做法明确不采 ——
//  用户画完手势凭空多点一下，踩到的是别人家的按钮。
//
//  焦点跳转这一手在真机上量过（macOS 15.8.1，探针 `/tmp/xctstub/ax_focus_methods.swift`）：
//  `AXRaise` 单独做、写窗口 `AXMain` 都改不了前台；写 App 的 `AXFrontmost` 才生效，
//  61～94ms，配合 `AXRaise` 是 1～3ms。判定成没成功**不能**看 `NSWorkspace.frontmostApplication`
//  —— 实测它在同一瞬间还报旧家，得看目标自报 `AXFrontmost` 与 `NSRunningApplication.isActive`。
//

import AppKit

/// 一条「屏上某个窗」的记录，字段全部取自 WindowServer 与应用列表，可离线构造。
public struct CursorWindowRecord: Equatable {
    public let pid: pid_t
    public let bundleID: String
    public let ownerName: String
    /// 主屏左上为原点、y 向下的全局矩形（`kCGWindowBounds` 原样）。
    public let globalBounds: CGRect
    /// 0 = 普通窗。菜单栏 24／25、程序坞 20 这些都在 0 之外（同一口径见 ScreenshotWindowProbe）。
    public let layer: Int
    public let alpha: Double
    /// 只有 `.regular` 的 App 才谈得上「把焦点挪过去」：agent/accessory 没有可见的激活效果，
    /// 往它们身上跳等于白闪一下。
    public let isRegularApp: Bool

    public init(pid: pid_t, bundleID: String, ownerName: String, globalBounds: CGRect,
                layer: Int, alpha: Double, isRegularApp: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.ownerName = ownerName
        self.globalBounds = globalBounds
        self.layer = layer
        self.alpha = alpha
        self.isRegularApp = isRegularApp
    }
}

/// 问 WindowServer 拿表。顺序即前后顺序（CGWindowList 保证从最前台往后排）。
public enum CursorWindowProbe {
    /// 一次抬手一调，**只在功能开关开着时调**（关着的时候 App 层压根不走到这儿，
    /// 老路径的抬手响应一点没变 —— 识别与响应时间是这条功能的死线）。
    /// 一台机器几十到上百条窗口，`NSRunningApplication` 按 pid 缓存着问，
    /// 不然同一家 App 的七八扇窗要问七八次。
    public static func onScreenWindows(ownPID: pid_t = ProcessInfo.processInfo.processIdentifier)
        -> [CursorWindowRecord] {
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]]) ?? []
        var runningCache: [pid_t: NSRunningApplication?] = [:]
        func running(_ pid: pid_t) -> NSRunningApplication? {
            if let hit = runningCache[pid] { return hit }
            let found = NSRunningApplication(processIdentifier: pid)
            runningCache[pid] = found
            return found
        }
        return infos.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return nil }
            let app = running(pid)
            return CursorWindowRecord(
                pid: pid,
                bundleID: app?.bundleIdentifier ?? "",
                ownerName: (info[kCGWindowOwnerName as String] as? String) ?? app?.localizedName ?? "",
                globalBounds: bounds,
                layer: layer,
                alpha: alpha,
                isRegularApp: app?.activationPolicy == .regular
            )
        }
    }
}

/// 这组偏好的快照。规则同别的模块：读进来什么值就照什么值判，界面上没开就一切照旧。
public struct StrokeTargetSettings: Equatable {
    /// 总开关。**默认关**：开着它会改「动作落到哪家」这条所有老规则都依赖的语义，
    /// 也会让人看到焦点跳一下，不能替用户默认打开。
    public var enabled: Bool
    /// 投完动作要不要把焦点还给原来那家。默认还 —— 不还的话「画一个手势」等价于
    /// 「点一下那个窗口」，用户接下来的打字会打进被跳过去的 App。
    public var restoresFocus: Bool

    public init(enabled: Bool = false, restoresFocus: Bool = true) {
        self.enabled = enabled
        self.restoresFocus = restoresFocus
    }

    public static let defaults = StrokeTargetSettings()

    /// 键落地之后还要等一会儿才还焦。实测（`/tmp/xctstub/ax_key_latency.swift`）：
    /// 跳完焦点投 session 层，目标 App 真正把 ⌘N 变成一扇新窗要 222～491ms。
    /// 提前还焦等于把刚投出去的那一发又抢回自己家，所以这一档不给界面铺控件，钉成常量。
    public static let restoreSettleSeconds: TimeInterval = 0.6
    /// 挪焦点之后最多等多久认定「跳过去了」。实测 1～94ms，留 250ms 是给慢 App 的余量；
    /// 再长就是在手势的 HID 回调里干等。
    public static let activateBudgetSeconds: TimeInterval = 0.25
}

public extension StrokeTargetSettings {
    /// 抬手时要不要抓那张窗口表。App 层的调用点用它，别把条件抄在调用处。
    ///
    /// 为什么值得单独占一个可测的口子：「开关关着却仍然每笔手势抓一次 `CGWindowList`」这种坏法
    /// 在界面上完全看不出来 —— 行为照旧（`attribute` 第一行就退回前台），只是抬手慢一点，
    /// 而识别与抬手响应正是这条功能的死线（issue #43/#68 量过一遍的那些毫秒）。
    /// 判定放在这儿，`CursorTargetTests` 才咬得住；放在调用处就只有装机那趟清单能发现。
    var needsWindowProbe: Bool { enabled }
}

public enum CursorTarget {
    /// 这一笔手势归给谁。
    public enum Attribution: Equatable {
        /// 老行为：归给当前前台（功能没开、或者判定不出别家时都是它）。
        case front
        /// 归给光标下那扇窗的主人。
        case cursorWindow(pid: pid_t, bundleID: String, ownerName: String)
    }

    /// 为什么是这个归属。分开列是因为「什么都没发生」在界面上只有一种样子，
    /// 日志里却可能是六件事，装机统计全靠它。
    public enum Reason: String {
        case disabled = "功能没开"
        case noWindowUnderCursor = "松手点没有普通层窗口"
        case onlyOwnWindow = "松手点上只有我们自己的窗"
        case notRegularApp = "那家不是可激活的普通 App"
        case missingBundleID = "那家没有 bundleId，规则没法按它匹配"
        case filteredApp = "那家被黑白名单过滤掉了，按老行为投前台"
        case sameAsFront = "光标下本来就是前台那家，无需跳转"
        case attributed = "归给光标下的窗口"

        /// 要不要为这一档写日志。「功能没开」是绝大多数笔数，写出来会把有用的行埋掉。
        public var isWorthLogging: Bool { self != .disabled }
    }

    /// 纯判定。`windows` 必须按「从前到后」给（`CursorWindowProbe` 就是这个顺序）。
    ///
    /// 逐条往下找「第一个够格」的窗，而不是只看最上面那一扇：自家那层透明画布就压在指针上，
    /// 只看最上等于永远归给自家。够格的五条门槛都在下面，顺序不能调 ——
    /// `sameAsFront` 要在真正选中之后才说得出。
    ///
    /// `isAppAllowed` 是 App 层那条黑白名单（与 `shouldCaptureGesture` 同一个判据）。
    /// 为什么判定阶段就要问它：黑名单的语义是「别在这家里动手」，光标压在黑名单的 C 上、
    /// 前台是 A 时跳过去，等于用一条 A 的规则往用户明确排除的 C 里注入键。
    public static func attribute(at point: CGPoint,
                                 windows: [CursorWindowRecord],
                                 frontPID: pid_t?,
                                 ownPID: pid_t,
                                 settings: StrokeTargetSettings,
                                 isAppAllowed: (String) -> Bool)
        -> (attribution: Attribution, reason: Reason) {
        guard settings.enabled else { return (.front, .disabled) }

        var skippedOwnWindow = false
        var sawNonRegular = false
        var sawMissingBundle = false
        var sawFiltered = false

        for window in windows {
            guard window.globalBounds.contains(point) else { continue }
            // 自家窗（画布、气泡、提示、偏好窗）不抢焦点：抢了等于把动作往自己身上投。
            guard window.pid != ownPID else { skippedOwnWindow = true; continue }
            // 非普通层（菜单栏 24/25、程序坞 20、通知中心那类）压根不是「一扇能被打字的窗」。
            guard window.layer == 0, window.alpha >= 0.99 else { continue }
            guard window.isRegularApp else { sawNonRegular = true; continue }
            guard !window.bundleID.isEmpty else { sawMissingBundle = true; continue }
            guard isAppAllowed(window.bundleID) else { sawFiltered = true; continue }

            if window.pid == frontPID { return (.front, .sameAsFront) }
            return (.cursorWindow(pid: window.pid, bundleID: window.bundleID,
                                  ownerName: window.ownerName), .attributed)
        }

        // 一层都没命中：按「为什么没成」分档，优先说得出原因的那条。
        if skippedOwnWindow { return (.front, .onlyOwnWindow) }
        if sawNonRegular { return (.front, .notRegularApp) }
        if sawMissingBundle { return (.front, .missingBundleID) }
        if sawFiltered { return (.front, .filteredApp) }
        return (.front, .noWindowUnderCursor)
    }

    /// 规则按哪家匹配。
    ///
    /// 归给光标下的窗口时，**匹配也用那一家**：动作既然要落在那家，规则却按隔壁那家挑，
    /// 就成了「用 IDE 的规则往浏览器里投 IDE 的快捷键」。用户画在哪家上，用的就是哪家的规则，
    /// 这才解释得通。功能没开或判不出别家时 = 前台那家（老行为）。
    public static func ruleBundleID(_ attribution: Attribution, frontBundle: String) -> String {
        switch attribution {
        case .front: return frontBundle
        case .cursorWindow(_, let bundleID, _): return bundleID
        }
    }
}
