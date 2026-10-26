// issue #22：「手势动作应打到光标下的窗口，而不是当前活跃窗口」。
//
// 这一手分三段，前两段是纯函数，第三段是次序 —— 三段都必须钉住，因为它们在真机上的
// 症状完全一样（「动作跑到了隔壁窗口」），肉眼复现不了：
//
// 1. `CursorTarget.attribute` —— 给一张手工构造的窗口表和一个点，得出「归谁」加「为什么」。
//    为什么把「为什么」也做成返回值：六档失败在界面上是同一个样子（什么都没发生），
//    装机统计全靠日志把它们分开。
// 2. `StrokeRouter.route` —— 挪不挪焦点、投完还给谁。这里钉的是**默认关**这条底线
//    （关着时归属性完全等于老行为）与「还焦要有对象」这类边角。
// 3. `StrokeRouter.execute` —— 用假 `FocusControlling` 记下调用序列，钉「挪焦点排在投动作
//    **之前**、还焦排在之后」。次序反了等于白跳：注入的那一发还是打进原来那家。
//
// 全程不碰真系统：不抓窗口表、不挪焦点、不注键。`SystemFocusControl` 那一手只有装了
// 辅助功能授权的常驻进程才做得成，交装机清单实测。
import XCTest
import AppKit
@testable import RuleEngine

final class CursorTargetTests: XCTestCase {

    // MARK: - 造数据用的小工具

    private let own: pid_t = 900
    private let front: pid_t = 100
    private let other: pid_t = 200

    private let point = CGPoint(x: 500, y: 400)

    /// 一扇够格的普通窗（层 0、不透明、普通 App、有 bundleId）。
    private func win(pid: pid_t, bundle: String = "com.example.app", name: String = "某应用",
                     bounds: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800),
                     layer: Int = 0, alpha: Double = 1.0, regular: Bool = true) -> CursorWindowRecord {
        CursorWindowRecord(pid: pid, bundleID: bundle, ownerName: name, globalBounds: bounds,
                           layer: layer, alpha: alpha, isRegularApp: regular)
    }

    private let on = StrokeTargetSettings(enabled: true, restoresFocus: true)
    private let off = StrokeTargetSettings(enabled: false, restoresFocus: true)
    /// 谁都不过滤（白名单模式 / 没配黑名单时就是这个）。
    private let allowAll: (String) -> Bool = { _ in true }

    private func attribute(_ windows: [CursorWindowRecord],
                           settings: StrokeTargetSettings = StrokeTargetSettings(enabled: true),
                           frontPID: pid_t? = 100, allowed: ((String) -> Bool)? = nil)
        -> (CursorTarget.Attribution, CursorTarget.Reason) {
        let isAppAllowed: (String) -> Bool = allowed ?? { _ in true }
        return CursorTarget.attribute(at: point, windows: windows, frontPID: frontPID,
                                      ownPID: own, settings: settings, isAppAllowed: isAppAllowed)
    }

    // MARK: - 一：默认必须是关的

    func testDefaultsKeepOldBehaviour() {
        XCTAssertFalse(StrokeTargetSettings.defaults.enabled,
                       "总开关默认关：开着它会改「动作落到哪家」这条所有老规则都依赖的语义")
        XCTAssertTrue(StrokeTargetSettings.defaults.restoresFocus,
                      "默认还焦：不还的话画一次手势等价于点一下那个窗口")
        // 关着的时候连「为什么」都不必写日志 —— 那一档的笔数是绝大多数。
        XCTAssertFalse(CursorTarget.Reason.disabled.isWorthLogging)
    }

    func testDisabledIgnoresWindowUnderCursor() {
        let (attribution, reason) = attribute([win(pid: other)], settings: off)
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .disabled)
    }

    /// 「关着就别抓窗口表」这条只能钉在判定层。`attribute` 第一行就退回前台，所以**行为**上
    /// 抓不抓都一样 —— 症状只有「抬手慢了一点」，界面上看不出来，装机清单也不会专门去量它。
    /// 于是调用点必须读这个口子（`main.swift` 用 `settings.needsWindowProbe`），坏法才有地方红。
    /// 识别与抬手响应是这条功能的死线（issue #43/#68 量过一遍）。
    func testClosedSwitchDoesNotAskForTheWindowList() {
        XCTAssertFalse(StrokeTargetSettings.defaults.needsWindowProbe,
                       "默认关 = 一次 CGWindowListCopyWindowInfo 都不做")
        XCTAssertFalse(StrokeTargetSettings(enabled: false, restoresFocus: true).needsWindowProbe,
                       "还焦那一档不该把抓表带出来：关着就是关着")
        XCTAssertFalse(StrokeTargetSettings(enabled: false, restoresFocus: false).needsWindowProbe)
        XCTAssertTrue(StrokeTargetSettings(enabled: true, restoresFocus: false).needsWindowProbe,
                      "开着却不抓表：归因永远算成「没有窗」，这功能等于没做")
        XCTAssertTrue(StrokeTargetSettings(enabled: true, restoresFocus: true).needsWindowProbe)
    }

    // MARK: - 二：归给谁

    func testAttributesToOtherAppWindow() {
        let (attribution, reason) = attribute([win(pid: other, bundle: "com.apple.SafariView", name: "浏览器")])
        XCTAssertEqual(attribution, .cursorWindow(pid: other, bundleID: "com.apple.SafariView", ownerName: "浏览器"))
        XCTAssertEqual(reason, .attributed)
        XCTAssertTrue(reason.isWorthLogging, "归因行必须进日志，装机按这一行统计命中与不命中")
    }

    func testCursorWindowSameAsFrontNeedsNoJump() {
        // 最常见的一档：光标就压在正在用的那家上。这时候一分钱都不该花。
        let (attribution, reason) = attribute([win(pid: front)])
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .sameAsFront)
    }

    func testOwnWindowIsSkippedAndTheAppBelowWins() {
        // 我们自己的透明画布正压在指针上（抬手那一刻还没收），不能把动作投给自己。
        let (attribution, reason) = attribute([win(pid: own, bundle: "com.mtjo.MacStroke"),
                                               win(pid: other, bundle: "com.example.editor")])
        XCTAssertEqual(attribution, .cursorWindow(pid: other, bundleID: "com.example.editor", ownerName: "某应用"))
        XCTAssertEqual(reason, .attributed)
    }

    func testOnlyOwnWindowUnderCursorReportsWhy() {
        let (attribution, reason) = attribute([win(pid: own, bundle: "com.mtjo.MacStroke")])
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .onlyOwnWindow)
    }

    func testNonLayerZeroWindowsAreNotTargets() {
        // 菜单栏 24／程序坞 20／我们的画布（CGShielding）都不是「一扇能被打字的窗」。
        let (attribution, reason) = attribute([win(pid: other, layer: 24)])
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .noWindowUnderCursor)
    }

    func testTranslucentWindowIsNotTarget() {
        // 半透明的东西（悬浮提示、遮罩）后面那扇才是用户真正压着的位置。
        let (attribution, reason) = attribute([win(pid: other, alpha: 0.4), win(pid: front, bundle: "com.example.front")])
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .sameAsFront, "跳过半透明那扇后命中前台那家")
    }

    func testAccessoryAppIsNotTarget() {
        let (attribution, reason) = attribute([win(pid: other, regular: false)])
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .notRegularApp, "往 agent 身上跳焦点等于白闪一下")
    }

    func testWindowWithoutBundleIDIsNotTarget() {
        let (attribution, reason) = attribute([win(pid: other, bundle: "")])
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .missingBundleID, "没有 bundleId 规则没法按它匹配，跳过去也白跳")
    }

    func testFilteredAppIsNotRetargeted() {
        // 黑名单的语义是「别在这家里动手」。光标压在被排除那家上时不许跳过去，
        // 否则等于用隔壁的规则往用户明确排除的窗口里注入键。
        let (attribution, reason) = attribute([win(pid: other, bundle: "com.example.blocked")],
                                              allowed: { $0 != "com.example.blocked" })
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .filteredApp)
    }

    func testFilteredAppDoesNotBlockTheWindowBelow() {
        // 「这一家被过滤」不等于「这一笔作废」：往下还有别家压着就用别家。
        let blocked = win(pid: 300, bundle: "com.example.blocked")
        let (attribution, reason) = attribute([blocked, win(pid: other, bundle: "com.example.editor")],
                                              allowed: { $0 != "com.example.blocked" })
        XCTAssertEqual(attribution, .cursorWindow(pid: other, bundleID: "com.example.editor", ownerName: "某应用"))
        XCTAssertEqual(reason, .attributed)
    }

    func testNothingUnderCursorReportsWhy() {
        // 桌面、屏外、或者别的屏（表里那些窗都不含这个点）。
        let (attribution, reason) = attribute([win(pid: other, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))])
        XCTAssertEqual(attribution, .front)
        XCTAssertEqual(reason, .noWindowUnderCursor)
    }

    func testEmptyWindowListReportsWhy() {
        let (_, reason) = attribute([])
        XCTAssertEqual(reason, .noWindowUnderCursor)
    }

    func testBottomRightEdgeIsNotInsideTheWindow() {
        // `CGRect.contains` 右、下两边是开区间。钉住它是因为差一个像素的口径就会在
        // 「贴着窗口边缘抬手」时判成「没有窗」，而那正好是用户最常 complain 的位置之一。
        let edge = CGPoint(x: 1000, y: 800)
        let (_, reason) = CursorTarget.attribute(at: edge, windows: [win(pid: other)], frontPID: front,
                                                 ownPID: own, settings: on, isAppAllowed: allowAll)
        XCTAssertEqual(reason, .noWindowUnderCursor)
        // 同一扇窗，往里一个像素就该命中。
        let inside = CGPoint(x: 999, y: 799)
        let (_, reason2) = CursorTarget.attribute(at: inside, windows: [win(pid: other)], frontPID: front,
                                                  ownPID: own, settings: on, isAppAllowed: allowAll)
        XCTAssertEqual(reason2, .attributed)
    }

    func testNilFrontPIDStillAttributes() {
        // 读不到前台（极端情况：前台是那扇压根没有 pid 的窗）。这时候「同家」判不出来，
        // 归给光标下那家仍然比归给一个未知前台好，且还焦会因为 restoreToPID = nil 而不做。
        let (attribution, reason) = attribute([win(pid: other)], frontPID: nil)
        XCTAssertEqual(attribution, .cursorWindow(pid: other, bundleID: "com.example.app", ownerName: "某应用"))
        XCTAssertEqual(reason, .attributed)
    }

    // MARK: - 三：规则按哪家匹配

    func testRuleBundleFollowsAttribution() {
        XCTAssertEqual(CursorTarget.ruleBundleID(.front, frontBundle: "com.example.front"),
                       "com.example.front")
        XCTAssertEqual(CursorTarget.ruleBundleID(.cursorWindow(pid: other, bundleID: "com.example.editor",
                                                               ownerName: "编辑器"),
                                                  frontBundle: "com.example.front"),
                       "com.example.editor",
                       "画在哪家上就用哪家的规则；用隔壁的规则往这家投快捷键解释不通")
    }

    // MARK: - 四：动作类型决定要不要挪焦点

    func testOnlyFocusDependentActionsNeedFocus() {
        for action in [RuleAction.keyPress("cmd-s"), RuleAction.shortcut(keyCode: 1, flags: 1048576),
                       RuleAction.text("hello"), RuleAction.password("s3cret"),
                       RuleAction.applescript("tell app \"System Events\" to keystroke \"s\"")] {
            XCTAssertTrue(action.needsCursorAppFocus, "\(action) 是投给活跃 App 的，必须跳")
        }
        for action in [RuleAction.mouseClick(x: 10, y: 10), RuleAction.copyToClipboard("字"),
                       RuleAction.screenshot, RuleAction.none] {
            XCTAssertFalse(action.needsCursorAppFocus, "\(action) 不看谁是前台，跳一下纯属白闪")
        }
    }

    func testScreenshotNeverMovesFocusEvenWhenAttributedElsewhere() {
        // 截图弹的是我们自己的全屏遮罩：遮罩摊开时延迟还焦会把焦点从截图窗抢走。
        let route = StrokeRouter.route(attribution: .cursorWindow(pid: other, bundleID: "com.example.editor",
                                                                  ownerName: "编辑器"),
                                       reason: .attributed, frontPID: front, frontBundle: "com.example.front",
                                       settings: on, needsFocus: RuleAction.screenshot.needsCursorAppFocus)
        XCTAssertFalse(route.willMoveFocus)
        XCTAssertNil(route.restoreToPID)
        XCTAssertEqual(route.bundleID, "com.example.editor", "规则仍然按光标下那家匹配")
    }

    // MARK: - 五：route 那张安排表

    private func route(settings: StrokeTargetSettings, needsFocus: Bool = true,
                       attribution: CursorTarget.Attribution? = nil) -> StrokeRoute {
        StrokeRouter.route(attribution: attribution ?? .cursorWindow(pid: other, bundleID: "com.example.editor",
                                                                      ownerName: "编辑器"),
                           reason: .attributed, frontPID: front, frontBundle: "com.example.front",
                           settings: settings, needsFocus: needsFocus)
    }

    func testRouteMovesAndSchedulesRestoreByDefault() {
        let r = route(settings: on)
        XCTAssertEqual(r.moveFocusToPID, other)
        XCTAssertEqual(r.restoreToPID, front, "还焦还给抬手那一刻那一家")
        XCTAssertEqual(r.restoreAfter, StrokeTargetSettings.restoreSettleSeconds)
        XCTAssertEqual(r.bundleID, "com.example.editor")
    }

    func testRouteWithoutRestoreSwitch() {
        let r = route(settings: StrokeTargetSettings(enabled: true, restoresFocus: false))
        XCTAssertEqual(r.moveFocusToPID, other)
        XCTAssertNil(r.restoreToPID, "「不还」那一档就是让手势等价于点一下那个窗口")
    }

    func testRouteCannotRestoreToUnknownFront() {
        // 抬手指不到前台 pid：还焦没有对象，只能不还（而不是还到一个猜出来的 pid）。
        let r = StrokeRouter.route(attribution: .cursorWindow(pid: other, bundleID: "com.example.editor",
                                                              ownerName: "编辑器"),
                                   reason: .attributed, frontPID: nil, frontBundle: "com.example.front",
                                   settings: on, needsFocus: true)
        XCTAssertEqual(r.moveFocusToPID, other)
        XCTAssertNil(r.restoreToPID)
    }

    func testRouteDoesNothingWhenAttributedToFront() {
        let r = route(settings: on, attribution: .front)
        XCTAssertFalse(r.willMoveFocus)
        XCTAssertNil(r.restoreToPID)
        XCTAssertEqual(r.bundleID, "com.example.front", "老行为：按前台那家匹配")
    }

    func testSettleCoversMeasuredDeliveryLatency() {
        // 实测（/tmp/xctstub/ax_key_latency.swift）：跳完焦点投 session 层，
        // Chrome 222ms、邮件 491ms 才把键变成可见动作。还焦早于这个数等于把自己
        // 刚投出去那一发也抢回自己家。
        XCTAssertGreaterThanOrEqual(StrokeTargetSettings.restoreSettleSeconds, 0.5,
                                    "延迟必须盖得住实测最慢那一档（491ms）")
        XCTAssertLessThanOrEqual(StrokeTargetSettings.activateBudgetSeconds, 0.25,
                                 "挪焦点的预算不许太长：这一段跑在手势的 HID 回调上")
    }

    // MARK: - 六：execute 的次序

    /// 记下调用序列的假焦点控制。还焦的 completion 立刻回，好让「次序」这一列读得直白。
    private final class FakeFocus: FocusControlling {
        var calls: [String] = []
        var activateResult = FocusMoveResult(ok: true, ms: 12, detail: "假的好")
        var restoreResult = FocusMoveResult(ok: true, ms: 7, detail: "假的好")
        var lastRestoreGuard: pid_t?
        var lastRestoreDelay: TimeInterval?

        func activate(pid: pid_t, budgetSeconds: TimeInterval) -> FocusMoveResult {
            calls.append("activate:\(pid)")
            return activateResult
        }

        func scheduleRestore(pid: pid_t, onlyIfFrontStill: pid_t?, after seconds: TimeInterval,
                             completion: @escaping (FocusMoveResult) -> Void) {
            calls.append("restore:\(pid)")
            lastRestoreGuard = onlyIfFrontStill
            lastRestoreDelay = seconds
            completion(restoreResult)
        }
    }

    func testActivateComesBeforeTheActionAndRestoreAfter() {
        let focus = FakeFocus()
        var logs: [String] = []
        let r = route(settings: on)
        StrokeRouter.execute(r, focus: focus, action: { focus.calls.append("action") },
                             log: { logs.append($0) })
        XCTAssertEqual(focus.calls, ["activate:\(other)", "action", "restore:\(front)"],
                       "次序反了等于白跳：注入那一发仍旧打进原来那家")
        XCTAssertEqual(focus.lastRestoreGuard, other, "还焦那道闸要盯「跳过去那一家」，不是盯自己")
        XCTAssertEqual(focus.lastRestoreDelay, StrokeTargetSettings.restoreSettleSeconds)
        XCTAssertTrue(logs.contains { $0.contains("已挪到") })
        XCTAssertTrue(logs.contains { $0.contains("还焦 已回") })
    }

    func testActionStillRunsWhenJumpFails() {
        // 跳转失败不许吞掉用户的动作：照样投（等于老行为），日志里写明没跳过去。
        let focus = FakeFocus()
        focus.activateResult = FocusMoveResult(ok: false, ms: 250, detail: "raise=-1 写 AXFrontmost=-1")
        var logs: [String] = []
        var ran = false
        StrokeRouter.execute(route(settings: on), focus: focus, action: { ran = true }, log: { logs.append($0) })
        XCTAssertTrue(ran)
        XCTAssertEqual(focus.calls.first, "activate:\(other)")
        XCTAssertTrue(logs.contains { $0.contains("没跳过去") }, "\(logs)")
    }

    func testNoJumpMeansNoActivateAndNoRestore() {
        let focus = FakeFocus()
        var ran = false
        let move = StrokeRouter.execute(route(settings: on, attribution: .front), focus: focus,
                                        action: { ran = true }, log: { _ in })
        XCTAssertNil(move, "没挪焦点就没有「挪的结果」可报")
        XCTAssertTrue(ran)
        XCTAssertEqual(focus.calls, [], "关着或与前台同家时一个焦点调用都不许发")
    }

    func testRestoreSkippedWhenRouteHasNoHome() {
        let focus = FakeFocus()
        StrokeRouter.execute(route(settings: StrokeTargetSettings(enabled: true, restoresFocus: false)),
                             focus: focus, action: { focus.calls.append("action") }, log: { _ in })
        XCTAssertEqual(focus.calls, ["activate:\(other)", "action"])
    }
}
