//
//  FocusMover.swift
//  MacStroke
//
//  把焦点挪到「光标下那扇窗的主人」，动作投完再决定还不还回去（issue #22）。
//
//  为什么非动焦点不可：注入的键走 session 层（`ActionExecutor` 里那两条注释说明了为什么不能
//  投 HID 层），而 session 层是按「谁是活跃 App」派发的 —— 焦点还在 IDE 时往 session 层投
//  ⌘S，保存的是 IDE。真机对照量过两条路（`/tmp/xctstub/ax_key_latency.swift`）：
//  跳完焦点再投，Chrome 222ms、邮件 491ms 就把键变成真动作；不跳焦点直接 `CGEventPostToPid`
//  也能落到目标（Chrome 1315ms、邮件 732ms），但那是「非活跃 App 自己收键」，逐家行为不一致，
//  输入文本要落在字段上还得靠 key window，所以这里只走「跳焦点」这一条。
//
//  三条从实测里钉下来的规矩，改这段代码前先读：
//  1. 只 `AXRaise` 或只写窗口 `AXMain` **都改不了前台**（两手的返回码都是 0，看着像成功）。
//     真正生效的是写 App 元素的 `AXFrontmost`。
//  2. 成没成不能问 `NSWorkspace.frontmostApplication`：实测它在同一瞬间还报旧家，
//     而 `NSRunningApplication.isActive` 是异步通知喂的缓存 —— 这一段跑在 HID 回调里，
//     回调没返回 runloop 就不转，缓存可以整段预算期都是旧的。判据只取「此刻的真实」两条：
//     目标自报的 `AXFrontmost` + 窗口服务里层 0 最前那扇窗的主人。
//  3. 还焦不能紧接着投完就做：键从 session 层走到目标 App 变成可见动作要 222～491ms，
//     提前把焦点抢回来等于把刚投出去那一发也抢回自己家。所以还焦走延迟队列，
//     延迟取 `StrokeTargetSettings.restoreSettleSeconds`，绝不在这里 sleep ——
//     这段代码跑在手势的 HID 回调上，睡多久用户就等多久。
//
//  4. 还焦还有一道闸：到点时前台已经不是我们跳过去那一家，说明用户自己动过了，这一手让位。
//     无脑抢回「抬手时那家」等于替用户做了一次他没做过的切换 —— 他正在隔壁窗口打字。
//
//  跳转失败不推翻用户的动作：照样投（等于老行为，动作落回原前台那家），只在日志里写明
//  「没跳过去、这一发按老行为投给了谁」。静默丢掉动作比跳错家更难查。
//

import AppKit

public struct FocusMoveResult: Equatable {
    public let ok: Bool
    /// 从动手到确认生效花了多少毫秒。装机取证要看这一列判「慢 App 会不会把回调拖死」。
    public let ms: Double
    /// 人话，进日志。
    public let detail: String

    public init(ok: Bool, ms: Double, detail: String) {
        self.ok = ok
        self.ms = ms
        self.detail = detail
    }
}

/// 焦点控制。留出这一层协议是为了让「挪焦点 → 投动作 → 还焦」的**次序**能被单测钉住：
/// 次序错了，真机上表现为「偶尔打进隔壁窗口」，那种问题不可能靠肉眼复现。
public protocol FocusControlling {
    func activate(pid: pid_t, budgetSeconds: TimeInterval) -> FocusMoveResult
    /// 延迟还焦。不许阻塞调用线程。
    ///
    /// `onlyIfFrontStill` = 还焦的前置条件：到点时前台仍然是这个 pid 才还，否则作罢。
    /// 为什么要这道闸：跳过去之后用户很可能自己点了第三家（或者已经点回原来那家），
    /// 到点无脑把焦点抢回「抬手时那家」，等于我们替他做了一次他没做过的切换 ——
    /// 正在隔壁窗口打字打到一半，输入光标被我们送回 IDE。
    func scheduleRestore(pid: pid_t, onlyIfFrontStill: pid_t?, after seconds: TimeInterval,
                         completion: @escaping (FocusMoveResult) -> Void)
}

/// 真系统那一手。
public final class SystemFocusControl: FocusControlling {
    public static let shared = SystemFocusControl()

    /// 单次 AX 调用的上限。目标是别的进程，它卡住时这边跟着卡；这一手跑在手势的 HID
    /// 回调上，宁可判「没跳成」也不要拖住手势。
    private let messagingTimeout: Float = 0.15
    /// 轮询间隔。实测跳转 1～94ms，5ms 一格既够快又不至于把窗口服务问烦。
    private let pollIntervalMicroseconds: UInt32 = 5_000

    public init() {}

    public func activate(pid: pid_t, budgetSeconds: TimeInterval) -> FocusMoveResult {
        let start = nowMs()
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            return FocusMoveResult(ok: false, ms: 0, detail: "目标进程已经不在了")
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        // 先抬窗：写 AXFrontmost 只换「谁是活跃 App」，不保证把那一扇提到最前面。
        // 抬失败不算事（有些 App 一扇窗都没有），下面的写入才是关键。
        // -1 = 压根没抬（这一家的窗一个都拿不到），其余是 AX 返回码原样。
        var raisedRaw: Int32 = -1
        if let windows = copyValue(appElement, "AXWindows") as? [AXUIElement], let win = windows.first {
            AXUIElementSetMessagingTimeout(win, messagingTimeout)
            raisedRaw = AXUIElementPerformAction(win, kAXRaiseAction as CFString).rawValue
        }
        let writeCode = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        // 验。判据只取「此刻的真实」两条：目标自报的 AXFrontmost、层 0 最前那扇窗的主人。
        // 不能只看 NSRunningApplication.isActive —— 它是异步通知喂进来的缓存，而这一段跑在
        // HID 回调里，回调没返回 runloop 就不会转，缓存可以整段预算期都是旧的。探针那
        // 1～94ms 是主循环转着量到的，产品路径没有这个条件。
        // 也不能把「刚写进去的值回读」当唯一判据：写 true 之后读回 true 有可能是回声，
        // 所以它只和窗口服务那条并列，两条里有一条说「是」才算跳成。
        var seen = readFrontmostSignals(pid)
        while !seen.isFrontmost, seen.topmostOwner != pid,
              nowMs() - start < budgetSeconds * 1000 {
            usleep(pollIntervalMicroseconds)
            seen = readFrontmostSignals(pid)
        }
        let confirmed = seen.isFrontmost || seen.topmostOwner == pid
        let ms = nowMs() - start
        return FocusMoveResult(
            ok: confirmed,
            ms: ms,
            detail: "raise=\(raisedRaw) 写 AXFrontmost=\(writeCode.rawValue) "
                + "目标自报=\(seen.isFrontmost) 层0最前=pid \(seen.topmostOwner.map(String.init(describing:)) ?? "无")"
        )
    }

    public func scheduleRestore(pid: pid_t, onlyIfFrontStill: pid_t?, after seconds: TimeInterval,
                                completion: @escaping (FocusMoveResult) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if let guardPID = onlyIfFrontStill {
                let owner = Self.topmostWindowOwnerPID()
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                // 到点时前台已经不是我们跳过去那一家：用户自己动过了，这一手让位。
                if owner != guardPID, front != guardPID {
                    completion(FocusMoveResult(ok: false, ms: 0,
                                               detail: "前台已经换到 pid \(owner.map(String.init(describing:)) ?? "无")，按闸不还"))
                    return
                }
            }
            completion(self.activate(pid: pid, budgetSeconds: StrokeTargetSettings.activateBudgetSeconds))
        }
    }

    /// 两个判据一次读回。isFrontmost 问目标自己那棵无障碍树（同步跨进程，不吃 runloop）；
    /// topmostOwner 问窗口服务的层 0 第一名（便宜，且我们的画布在 CGShielding 层，压根不参与）。
    private func readFrontmostSignals(_ pid: pid_t) -> (isFrontmost: Bool, topmostOwner: pid_t?) {
        var value: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                 kAXFrontmostAttribute as CFString, &value)
        let isFrontmost = (code == .success) && ((value as? Bool) ?? false)
        return (isFrontmost, Self.topmostWindowOwnerPID())
    }

    /// 层 0（普通窗）最靠前那扇窗的主人；一扇都没有返回 nil。
    static func topmostWindowOwnerPID() -> pid_t? {
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            return info[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    private func copyValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func nowMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000 }
}

/// 一笔手势的焦点安排。`StrokeRouter.route` 算出来，`execute` 消费。
public struct StrokeRoute: Equatable {
    /// 规则按哪家匹配（= `CursorTarget.ruleBundleID` 的产物，留着是为了日志能一行说清这一笔）。
    public let bundleID: String
    public let reason: CursorTarget.Reason
    /// 非 nil 表示投动作之前要把焦点挪到这个 pid。
    public let moveFocusToPID: pid_t?
    /// 非 nil 表示动作投完之后要把焦点还给这个 pid（= 抬手那一刻的前台）。
    public let restoreToPID: pid_t?
    public let restoreAfter: TimeInterval

    /// 这一笔到底要不要动焦点。
    public var willMoveFocus: Bool { moveFocusToPID != nil }
}

public extension RuleAction {
    /// 这一发动作是不是「打在哪家 App 上」有关系。
    ///
    /// 只有会往活跃 App 投东西的那几档需要挪焦点。剩下的按坐标或按服务走，跳一下纯属白闪：
    /// - `mouseClick`：本来就按坐标打，点哪家就是哪家（点下去那一下自己就会把它变前台）。
    /// - `copyToClipboard`：只写粘贴板，与谁是前台无关。
    /// - `screenshot`：**必须不跳**。这一档弹的是我们自己的全屏遮罩，遮罩正摊开时
    ///   延迟还焦那一手会把焦点从截图窗抢走；而且它压根不是「打进隔壁窗口」的动作。
    /// - `none`：没有动作。
    var needsCursorAppFocus: Bool {
        switch self {
        case .keyPress, .shortcut, .text, .password, .applescript:
            return true
        case .mouseClick, .copyToClipboard, .screenshot, .none:
            return false
        }
    }
}

public enum StrokeRouter {
    /// 第二步（纯判定）：动作定了之后，决定「投之前挪不挪焦点、投完还给谁」。
    ///
    /// 为什么不并进一步和 `CursorTarget.attribute` 一起算：归属在**匹配规则之前**就要定下来
    /// （规则按哪家匹配），而要不要挪焦点要等匹配出动作才知道。两步之间隔着一次 DTW。
    public static func route(attribution: CursorTarget.Attribution,
                             reason: CursorTarget.Reason,
                             frontPID: pid_t?,
                             frontBundle: String,
                             settings: StrokeTargetSettings,
                             needsFocus: Bool) -> StrokeRoute {
        guard case .cursorWindow(let pid, let bundleID, _) = attribution, needsFocus else {
            return StrokeRoute(bundleID: CursorTarget.ruleBundleID(attribution, frontBundle: frontBundle),
                               reason: reason, moveFocusToPID: nil, restoreToPID: nil, restoreAfter: 0)
        }
        return StrokeRoute(bundleID: bundleID, reason: reason, moveFocusToPID: pid,
                           restoreToPID: settings.restoresFocus ? frontPID : nil,
                           restoreAfter: StrokeTargetSettings.restoreSettleSeconds)
    }

    /// 按次序把三件事做完：挪焦点 → 执行动作 → 安排还焦。
    /// 动作本体是注进来的闭包，好让单测能证明「挪焦点确实排在投键之前」——
    /// 这两手反过来，注入的那一发就打进原来那家，真机上表现为「时对时错」。
    /// 日志闭包同样注入：这一层够不到 App 的日志口径，也不该自己造一个。
    @discardableResult
    public static func execute(_ route: StrokeRoute, focus: FocusControlling,
                               action: () -> Void, log: @escaping (String) -> Void) -> FocusMoveResult? {
        guard let targetPID = route.moveFocusToPID else {
            action()
            return nil
        }
        let move = focus.activate(pid: targetPID, budgetSeconds: StrokeTargetSettings.activateBudgetSeconds)
        if !move.ok {
            log("没跳过去（\(move.detail)），这一发按老行为投给抬手时的前台")
        } else {
            log("已挪到 pid \(targetPID)（\(String(format: "%.0f", move.ms)) ms）")
        }
        action()
        if let homePID = route.restoreToPID {
            focus.scheduleRestore(pid: homePID, onlyIfFrontStill: targetPID,
                                  after: route.restoreAfter) { back in
                log("还焦 \(back.ok ? "已回" : "没回")（\(String(format: "%.0f", back.ms)) ms，\(back.detail)）")
            }
        }
        return move
    }
}
