//
//  SelectedTextReaderTests.swift
//  SelectionPopupTests
//
//  无障碍那一层的取证做三件事：**错误码分类**、**读不上来之后的补救次序**、**不许挂住**。
//  真读一段别人的字在 `swift test` 里做不了 —— 那要有辅助功能授权、要有个真在前台并且
//  真选中了什么的 App，而「那台机器上此刻谁在前台、选了啥」正是判据不能取自的东西。
//  补救这一段是纯次序（先重读哪一份、要不要请对方开接口、每个属性只写一遍），所以把「读一个来源」
//  和「写开关」抽成接缝，用脚本答复来验 —— 内容层面只有一个 smoke 用例：调一次真接口，
//  断言它**在超时之前答了**，不断言答了什么。
//
//  「Chrome 里划词永远不弹」那个坏（旧代码只写 `AXManualAccessibility`，被拒之后 pid 就永久进了
//  名单）由 `testChromeShapeWritesTheSecondSwitchAfterTheFirstIsRejected` 咬住。
//
//  装机第二轮（2026-10-21）又暴露一档：Chrome 和邮件里接口已经开上了，焦点元素也拿到了，
//  但焦点是**容器**（`AXWebArea`、`AXRow`），它自己不应 `kAXSelectedTextAttribute`（-25212），
//  选区在子树里。旧代码在这一档什么都不做就直接返回 —— 日志里那一句「该控件不支持选中文字属性」
//  还把 -25205（真不支持，修不了）和 -25212（能绕）混成同一个说法，归因直接指错方向。
//  这一档由 `testTheFocusedContainerIsWorkedAroundUnderTheCursor` 那组用例咬住。
//

import ApplicationServices
import Storage
import XCTest
@testable import SelectionPopup

final class SelectedTextReaderTests: XCTestCase {
    /// 装机时真会碰到的五个码，每个都得有一个明确说法。
    /// 界面上都是「没弹」，日志里分不出为什么的话，用户报「Chrome 里不弹、TextEdit 里弹」
    /// 就只能靠猜。
    func testKnownErrorCodesGetTheirOwnReason() {
        XCTAssertEqual(AXSelectedTextReader.classify(-25211, focusedElementStage: true),
                       .accessibilityNotEnabled, "对方没开无障碍接口（Chromium 那一类）")
        XCTAssertEqual(AXSelectedTextReader.classify(-25204, focusedElementStage: true), .timedOut)
        XCTAssertEqual(AXSelectedTextReader.classify(-25204, focusedElementStage: false), .timedOut)
        XCTAssertEqual(AXSelectedTextReader.classify(-25202, focusedElementStage: false),
                       .noFocusedElement, "焦点元素已经作废：切 App 那一瞬最容易撞上")
        // 其余的码原样带出来，装机时按码分类。
        XCTAssertEqual(AXSelectedTextReader.classify(-25200, focusedElementStage: true), .apiError(-25200))
        XCTAssertEqual(AXSelectedTextReader.classify(0, focusedElementStage: true), .apiError(0))
    }

    /// 同一个码在两步里含义不同 —— 这一条是整个分类里最容易写反的地方。
    /// -25205 在「取焦点元素」这一步是「这个 App 现在没有焦点对象」，
    /// 在「读选中文字」那一步是「这个控件压根不支持选中文字」（SwiftUI 的文本框、密码框）。
    /// 两步共用一个答案，日志里就只能报错误的那个。
    func testTheSameCodeMeansDifferentThingsAtTheTwoSteps() {
        for code in [-25205, -25208] {
            XCTAssertEqual(AXSelectedTextReader.classify(code, focusedElementStage: true), .noFocusedElement,
                           "码 \(code) 在读焦点元素这一步该算没焦点")
            XCTAssertEqual(AXSelectedTextReader.classify(code, focusedElementStage: false),
                           .selectedTextUnsupported, "码 \(code) 在读选中文字这一步该算控件不支持")
        }
    }

    /// **-25212（NoValue）和 -25205（AttributeUnsupported）必须分开。**
    /// 装机第一轮把两个码并成一句「该控件不支持选中文字属性」，归因直接指错方向：
    /// 前者是「元素在、属性也在、只是这一格不持有选区」（焦点给的是 `AXWebArea`/`AXRow` 那种容器，
    /// 选区在子树里），能靠「读鼠标点命中的元素」绕；后者是压根不实现，绕不了。
    /// Chrome 与邮件里每次划词报的都是 -25212。
    func testNoValueIsNotTheSameAsAttributeUnsupported() {
        XCTAssertEqual(AXSelectedTextReader.classify(-25212, focusedElementStage: false), .noSelectedTextValue,
                       "-25212 是「属性在但当前没值」，不是「控件不支持」")
        XCTAssertEqual(AXSelectedTextReader.classify(-25212, focusedElementStage: true), .noFocusedElement)
        XCTAssertNotEqual(AXSelectedTextReader.classify(-25212, focusedElementStage: false),
                          AXSelectedTextReader.classify(-25205, focusedElementStage: false),
                          "并成同一档就没法分「能绕」和「绕不了」")
        XCTAssertEqual(AXSelectedTextReader.classify(-25205, focusedElementStage: false), .selectedTextUnsupported)
    }

    /// 每一种结果都要能进日志，而且每一种「读不到」的说法各不相同。
    /// 都写成「读不到」的话，装机清单第 3 条就没法按原因分类统计。
    /// 「该控件没有选中文字属性」和「焦点元素当前没有选区」那两句尤其不能串：
    /// 前者要放弃、后者要改读鼠标点那棵树，装机时看的是同一句「不弹」，修法完全两样。
    func testEveryOutcomeHasItsOwnLogLine() {
        let cases: [(SelectedTextResult, String)] = [
            (.text("abcd"), "读到 4 个字符"),
            (.nothingSelected, "选区为空"),
            (.unavailable(.accessibilityNotEnabled), "该 App 未启用无障碍接口"),
            (.unavailable(.noFocusedElement), "取不到焦点元素"),
            (.unavailable(.selectedTextUnsupported), "该控件没有选中文字属性"),
            (.unavailable(.noSelectedTextValue), "焦点元素当前没有选区（选区可能在它的子树里）"),
            (.unavailable(.noElementUnderCursor), "鼠标点没命中这个 App 的元素"),
            (.unavailable(.timedOut), "无障碍调用超时"),
            (.unavailable(.apiError(-25200)), "无障碍调用失败 code=-25200"),
        ]
        var reasons: [String] = []
        for (result, expected) in cases {
            XCTAssertEqual(result.logReason, expected)
            reasons.append(result.logReason)
        }
        XCTAssertEqual(Set(reasons).count, reasons.count, "几种读不到的说法串了线")
    }

    /// `.string` 只有 `.text` 那一支拿得到：判定层靠它区分「有字」和「有结果但没字」。
    func testOnlyTheTextBranchYieldsAString() {
        XCTAssertEqual(SelectedTextResult.text("hi").string, "hi")
        XCTAssertNil(SelectedTextResult.nothingSelected.string)
        XCTAssertNil(SelectedTextResult.unavailable(.timedOut).string)
        // 空串也是「没字」：`string` 返回 "" 而不是 nil，是判定层要自己拦的那一层。
        XCTAssertEqual(SelectedTextResult.text("").string, "")
    }

    /// 读回来的那段字有两种写法：`CFString`（纯文本控件）和 `CFAttributedString`
    /// （TextEdit 那一类富文本）。只认前者的话，在富文本里划词永远不弹 —— 而日志里连一行
    /// 错误都不会有，因为调用本身是 `.success`，只是我们没接住返回值。
    /// 反向变异 M46：摘掉富文本那一支，这条红。
    func testBothFlavoursOfTheAttributeValueBecomeAString() throws {
        XCTAssertEqual(AXSelectedTextReader.string(from: "划词 copy" as CFString), "划词 copy")
        let rich = try XCTUnwrap(CFAttributedStringCreate(nil, "富文本 选区" as CFString, nil))
        XCTAssertEqual(AXSelectedTextReader.string(from: rich as CFTypeRef), "富文本 选区",
                       "富文本控件给的是 CFAttributedString，这一支不认就是永远不弹")
        XCTAssertEqual(AXSelectedTextReader.string(from: NSAttributedString(string: "OC 富文本") as CFTypeRef),
                       "OC 富文本")
        // 空串原样带出去：判空是判定层的事，这里只做类型分派。
        XCTAssertEqual(AXSelectedTextReader.string(from: "" as CFString), "")
        // 不相干的返回值一律 nil：宁可不弹，也不要把一个数字当成选中的字念出来。
        XCTAssertNil(AXSelectedTextReader.string(from: NSNumber(value: 42) as CFTypeRef))
    }

    // MARK: - 读不上来之后要不要再试一手

    /// 八种「读不到」里该再补救的和不该补救的，逐个点名。
    /// 超时那一档必须挡掉：装机日志里 Chrome 卡住的时候，第二次、第三次还是等满 0.6s，
    /// 一笔划词排三次队，后台队列会被拖出一串空转的读取。
    /// `noElementUnderCursor` 也挡掉：那一手本身就是「在鼠标点探测」，探测失败再探测一次还是打不中。
    func testOnlyTheRecoverableFailuresAreWorthAnotherTry() {
        for reason in [SelectedTextResult.Unavailable.accessibilityNotEnabled,
                       .noFocusedElement, .selectedTextUnsupported, .noSelectedTextValue] {
            XCTAssertTrue(AXSelectedTextReader.shouldAskAgain(reason), "\(reason) 这一档该再试")
        }
        XCTAssertFalse(AXSelectedTextReader.shouldAskAgain(.timedOut), "对方没答话：再问两次还是白等")
        XCTAssertFalse(AXSelectedTextReader.shouldAskAgain(.apiError(-25200)), "没归类的码不猜原因，也就无从补救")
        XCTAssertFalse(AXSelectedTextReader.shouldAskAgain(.noElementUnderCursor), "探测没打中，再探测一次也一样")
    }

    /// 「请对方开无障碍接口」只该给那两种「对方压根没把接口打开」的外观。
    /// 控件不支持选中文字、焦点元素是容器都不在里面：焦点元素已经拿到手了，说明接口是开着的，
    /// 再请一次不会给它凭空长出一个属性，白让人家多维护一棵树（Chromium 那一棵是几百个节点）。
    func testOnlyTheNoAccessibilityFailuresAskTheAppToOpenItsInterface() {
        XCTAssertTrue(AXSelectedTextReader.shouldRequestAccessibility(.accessibilityNotEnabled))
        XCTAssertTrue(AXSelectedTextReader.shouldRequestAccessibility(.noFocusedElement))
        XCTAssertFalse(AXSelectedTextReader.shouldRequestAccessibility(.selectedTextUnsupported),
                       "控件不给选区不是「没开接口」，请它开接口是白折腾")
        XCTAssertFalse(AXSelectedTextReader.shouldRequestAccessibility(.noSelectedTextValue),
                       "焦点元素都给出来了，接口就是开着的")
        XCTAssertFalse(AXSelectedTextReader.shouldRequestAccessibility(.timedOut))
    }

    /// 系统级那一份只补「拿不到焦点元素」这一档。焦点元素在、只是不给选区时，
    /// `AXUIElementCreateSystemWide()` 解析回来的就是**同一个元素**，再读一次纯属多花 0.6s。
    func testTheSystemWideFallbackIsNotWastedOnAnElementWeAlreadyHold() {
        XCTAssertTrue(AXSelectedTextReader.shouldRetrySystemWide(.noFocusedElement))
        XCTAssertTrue(AXSelectedTextReader.shouldRetrySystemWide(.accessibilityNotEnabled))
        for reason in [SelectedTextResult.Unavailable.selectedTextUnsupported, .noSelectedTextValue] {
            XCTAssertFalse(AXSelectedTextReader.shouldRetrySystemWide(reason),
                           "焦点元素已经拿到手，换来源读到的还是它")
        }
    }

    /// 「改读鼠标松手那个点命中的元素」只上场在那两种「焦点元素拿到了、但它自己不持有选区」的档次。
    /// 这一条是装机第二轮（邮件、Chrome）唯一缺的那一手：焦点给的是容器（`AXWebArea`、`AXRow`），
    /// 选区在子树里的某个孩子身上，旧代码在这一档**什么都不做**就直接返回「不弹」。
    /// 请开接口和换系统级都补不了它（一个接口本来就开着，一个换过去还是同一个元素），
    /// 只有按位置命中元素、再往父级上溯才对得上。
    func testOnlyTheContainerShapedFailuresAreProbedUnderTheCursor() {
        XCTAssertTrue(AXSelectedTextReader.shouldProbeUnderTheCursor(.noSelectedTextValue),
                      "-25212：属性在、这一格不持有选区，正是要往下找的形状")
        XCTAssertTrue(AXSelectedTextReader.shouldProbeUnderTheCursor(.selectedTextUnsupported),
                      "-25205：容器也可能压根不应这个属性，值得一试")
        for reason in [SelectedTextResult.Unavailable.accessibilityNotEnabled,
                       .noFocusedElement, .timedOut, .noElementUnderCursor] {
            XCTAssertFalse(AXSelectedTextReader.shouldProbeUnderTheCursor(reason), "\(reason) 不该去探测")
        }
        XCTAssertFalse(AXSelectedTextReader.shouldProbeUnderTheCursor(.apiError(-25200)))
    }

    // MARK: - 开接口那一步（「很多软件里没效果」的头一条真因）

    /// 两个开关属性的**顺序**：便宜的在前。
    /// `AXManualAccessibility` 只是请对方把无障碍接口打开；`AXEnhancedUserInterface` 是让对方
    /// 以为屏幕上正有个辅助工具在跑（VoiceOver 用的那一条，焦点行为都可能跟着变，代价更贵）。
    /// 顺序换过去，凡是吃第一条的 App 都白挨一次贵的。
    func testTheCheaperEnableAttributeIsTriedFirst() {
        XCTAssertEqual(AXSelectedTextReader.accessibilityAttributes,
                       ["AXManualAccessibility", "AXEnhancedUserInterface"],
                       "第一个是请对方开接口，第二个是让对方以为有辅助工具在跑：贵的不能在前")
        XCTAssertEqual(Set(AXSelectedTextReader.accessibilityAttributes).count, 2, "两个名字不能写成同一个")
    }

    /// **回归用例**：旧代码把「试过了」记在**进程**这一档，于是 Chrome 被 `AXManualAccessibility`
    /// 拒掉（本机实测 -25205）之后，那个 pid 永远进名单，第二条 `AXEnhancedUserInterface`
    /// （Chrome 实测吃它，写返回 0）再也没有机会被写 —— 表现就是「Chrome 里划词永远不弹」。
    /// 名单要按（进程 × 属性）记，同一个进程的第二个属性是全新的一次机会。
    func testARejectedAttributeDoesNotBlockTheNextOneOnTheSameProcess() {
        let pid: pid_t = 900_111
        XCTAssertTrue(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXManualAccessibility"))
        XCTAssertFalse(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXManualAccessibility"),
                       "同一个进程的同一个属性不该写第二遍")
        XCTAssertTrue(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXEnhancedUserInterface"),
                      "第一条被拒之后第二条必须还有机会：这就是 Chrome 不弹的那一条")
        XCTAssertFalse(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXEnhancedUserInterface"))
        // 别的进程不受这个进程的名单影响
        XCTAssertTrue(AXSelectedTextReader.markAttempt(pid: 900_112, attribute: "AXManualAccessibility"))
    }

    /// 关掉总开关时，那份「试过了」的名单要一起清掉。
    /// 不清的话，用户把功能关一会儿再打开，各家 App 的接口一次也请不动了 —— 表现是
    /// 「重装之后头一次好用，关掉再打开就再也不弹」，比原来的 bug 更难查。
    /// 这一条靠 `releaseRequestedAccessibility()` 里那两行 `removeAll`。
    func testTurningTheFeatureOffResetsTheEnableBookkeeping() {
        let pid: pid_t = 900_113
        XCTAssertTrue(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXManualAccessibility"))
        XCTAssertTrue(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXEnhancedUserInterface"))
        XCTAssertFalse(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXManualAccessibility"))
        AXSelectedTextReader.releaseRequestedAccessibility()
        XCTAssertTrue(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXManualAccessibility"),
                      "关过一次之后重新打开，还要能再请各家开一次接口")
    }

    // MARK: - 补救的次序（走接缝，不碰真进程）

    /// Chrome 那一档的形状：首读报「取不到焦点元素」→ 请开接口，第一条 `AXManualAccessibility`
    /// 被拒（本机实测 -25205）→ **还要写第二条** `AXEnhancedUserInterface` → 写上之后重读那一棵，中了。
    /// 这就是「很多软件里没效果」的头一条真因，也是旧代码坏在哪：只写第一条，而且第一条被拒之后
    /// 那个 pid 永久进了「试过了」的名单，第二次划词连试都不试。
    func testChromeShapeWritesTheSecondSwitchAfterTheFirstIsRejected() {
        let pid: pid_t = 910_001
        let script = Script(app: [.unavailable(.noFocusedElement), .text("Chrome 的选区")],
                            enable: [false, true])
        let reader = wiredReader(pid: pid, script)
        XCTAssertEqual(reader.read(), .text("Chrome 的选区"))
        XCTAssertEqual(script.writes, ["AXManualAccessibility", "AXEnhancedUserInterface"],
                       "第一条被拒就必须试第二条，且贵的（Enhanced）不能先写")
        XCTAssertEqual(script.reads, ["app", "app"], "开成接口之后重读的是那一棵，不是系统级那份")
    }

    /// 两笔开关都被拒（对方压根不吃这两条）→ 换「整个系统当前关注的元素」再读一次。
    /// 这一手是给那些「App 元素上不答焦点、系统级那一份却有」的桥接层留的。
    func testBothSwitchesRejectedFallsBackToTheSystemWideElement() {
        let pid: pid_t = 910_002
        let script = Script(app: [.unavailable(.noFocusedElement)],
                            system: [.text("系统级读到的")],
                            enable: [false, false])
        let reader = wiredReader(pid: pid, script)
        XCTAssertEqual(reader.read(), .text("系统级读到的"))
        XCTAssertEqual(script.writes.count, 2, "两个属性都该试一遍")
        XCTAssertEqual(script.reads, ["app", "system"])
    }

    /// 系统级那一份也读不到时，报**第一次**的错。
    /// 装机日志按原因分档统计的是「在这个 App 里划词为什么不弹」，不是「在系统级元素上读为什么不弹」；
    /// 让第二次的错盖掉第一次，Chrome 那一条就会从「取不到焦点元素」变成查不出来的「超时」。
    func testTheSystemWideFallbackDoesNotStealTheBlame() {
        let pid: pid_t = 910_003
        let script = Script(app: [.unavailable(.noFocusedElement)],
                            system: [.unavailable(.timedOut)],
                            enable: [false, false])
        let reader = wiredReader(pid: pid, script)
        XCTAssertEqual(reader.read(), .unavailable(.noFocusedElement), "失败要按第一次归因")
        XCTAssertEqual(script.reads, ["app", "system"])
    }

    /// 请开接口**写成功**了、树却还没建起来（本机实测过：写成功那一句立刻重读还是失败，
    /// 6 秒后下一次划词才成）→ 用第二次的错，并且**不要**再去读系统级：
    /// 对方连树都还没建，换一份来源读到的还是「没有焦点元素」，白排一次队。
    func testAJustOpenedInterfaceRereadsItsOwnTreeAndStopsThere() {
        let pid: pid_t = 910_004
        let script = Script(app: [.unavailable(.noFocusedElement), .unavailable(.accessibilityNotEnabled)],
                            enable: [true])
        let reader = wiredReader(pid: pid, script)
        XCTAssertEqual(reader.read(), .unavailable(.accessibilityNotEnabled), "要报重读那一次的错")
        XCTAssertEqual(script.reads, ["app", "app"], "开接口成功这一支不再读系统级")
    }

    /// 「控件压根不给选区」那一档**只**上场鼠标点那一手：不请对方开接口（接口是开着的，
    /// 焦点元素都拿到手了），也不换系统级那一份（解析回来还是同一个元素，白排一次队）。
    /// 装机第一轮在这条上写的是「什么都不做」，于是 -25205 那批 SwiftUI 文本框和 -25212 那批
    /// 容器一起变成「就是不存在」；现在探测一手，剩下的两手还是不许上。
    func testAnElementThatAlreadyRefusesSelectionGetsNoEnableOrSystemWideRetry() {
        let pid: pid_t = 910_005
        let script = Script(app: [.unavailable(.selectedTextUnsupported)])
        let reader = wiredReader(pid: pid, script, anchor: CGPoint(x: 640, y: 400))
        XCTAssertEqual(reader.read(), .unavailable(.selectedTextUnsupported))
        XCTAssertEqual(script.reads, ["app", "点"], "只多一手探测，不许再换来源：\(script.reads)")
        XCTAssertTrue(script.writes.isEmpty, "不该请对方开接口：\(script.writes)")
    }

    // MARK: - 鼠标点那一手（装机第二轮：焦点是容器）
    //
    // 这一手能验的是**次序与边界**：什么档次才上场、拿到的是哪个点、几手都不中时报谁的错、
    // 没有坐标时压根不许上。「往上溯到第几格、命中的是不是别人家的元素」在
    // `readAtPoint` 里，那一段要真元素树，`swift test` 演不出来 —— 装机清单里按 role 那一行日志核。

    /// 邮件/Chrome 那一档的形状：焦点元素给了容器（`AXWebArea`、`AXRow`），它自己不应选区
    /// （-25212）→ 改读「松手那一点命中的元素」→ 它的祖先里有一格答上来了 → 弹。
    /// 这一条就是装机第二轮报的「邮件里也没效果」：旧代码在这里直接返回不弹。
    func testTheFocusedContainerIsWorkedAroundUnderTheCursor() {
        let pid: pid_t = 910_008
        let anchor = CGPoint(x: 640, y: 420)
        let script = Script(app: [.unavailable(.noSelectedTextValue)],
                            atPoint: [.text("邮件正文里划的那段")])
        let reader = wiredReader(pid: pid, script, anchor: anchor)
        XCTAssertEqual(reader.read(), .text("邮件正文里划的那段"))
        XCTAssertEqual(script.reads, ["app", "点"])
        XCTAssertEqual(script.points, [anchor], "探测用的必须是松手那一点，不是别的坐标")
        XCTAssertTrue(script.writes.isEmpty, "接口开着，不该再去写开关：\(script.writes)")
        XCTAssertEqual(reader.answeredFrom, .atPoint(pid, anchor),
                       "成功那行日志要说清是哪一手答上来的，否则下一次不知道该修哪一档")
    }

    /// 探测用的是**松手那一点**，不是按下点、也不是 .zero：拿错了坐标就打到窗口标题栏或者
    /// 桌面上，表现是「在正文里划词不弹、在别处划反而弹」，最难归因。
    func testTheProbeUsesTheReleasedPointNotSomewhereElse() {
        let pid = scriptPid()
        let anchor = CGPoint(x: 1_024, y: 300)
        let script = Script(app: [.unavailable(.noSelectedTextValue)], atPoint: [.text("对的位置")])
        _ = wiredReader(pid: pid, script, anchor: anchor).read()
        XCTAssertEqual(script.points, [anchor], "读到的点必须只有一个，就是松手那一点")
    }

    /// 没有坐标（快捷键那一路压根没有拖动）时不许凭空探测 —— `.zero` 是屏幕左下角，
    /// 在那儿命中一个元素再把它家的选区弹到用户眼前，既读错人也白排一次队。
    func testTheProbeIsSkippedWhenThereIsNoPointToHitTest() {
        let pid: pid_t = 910_009
        let script = Script(app: [.unavailable(.noSelectedTextValue)], atPoint: [.text("不该被读到")])
        let reader = wiredReader(pid: pid, script)
        XCTAssertEqual(reader.read(), .unavailable(.noSelectedTextValue))
        XCTAssertEqual(script.reads, ["app"], "没坐标就没有这一手：\(script.reads)")
        XCTAssertTrue(script.points.isEmpty)
    }

    /// 往上溯也没人答选区时，报**第一次**的错。
    /// 装机统计的是「在这个 App 里划词为什么不弹」，第一次那一句带着焦点元素的 role
    /// （`role=AXWebArea 不给选中文字`），比「鼠标点没命中」有信息量；
    /// 让探测那一手的错盖掉它，Chrome 那一条就变成查不出来的「这一格没有选区」。
    func testTheProbeDoesNotStealTheBlameEither() {
        let pid: pid_t = 910_010
        let script = Script(app: [.unavailable(.selectedTextUnsupported)],
                            atPoint: [.unavailable(.noElementUnderCursor)])
        let reader = wiredReader(pid: pid, script, anchor: CGPoint(x: 100, y: 700))
        XCTAssertEqual(reader.read(), .unavailable(.selectedTextUnsupported), "失败要按第一次归因")
        XCTAssertEqual(script.reads, ["app", "点"])
        XCTAssertNil(reader.answeredFrom, "没读到字就不许记来源")
    }

    /// 快捷键那一条（`.systemWide`）不许跟着探测：它读的就是系统级焦点，没有「刚才在哪个进程里
    /// 松手」这件事，也没有 pid 可以核对命中元素归属 —— 少了 pid 这一道闸，打到的可能就是
    /// 我们那枚还没收掉的气泡，念出来的会是 MacStroke 自己的字。
    func testTheSystemWideScopeNeverProbesUnderTheCursor() {
        let script = Script(app: [], system: [.unavailable(.noSelectedTextValue)])
        let reader = AXSelectedTextReader(scope: .systemWide, anchor: CGPoint(x: 500, y: 400))
        reader.readSourceOverride = { script.read($0) }
        XCTAssertEqual(reader.read(), .unavailable(.noSelectedTextValue))
        XCTAssertEqual(script.reads, ["system"], "系统级那一条一次都不探测：\(script.reads)")
    }

    /// App 焦点那一手自己就答上来了，探测一次都不许多做。
    /// 这一条是给「把探测无条件插进主路径」那种改法准备的：正常档位（TextEdit、Notes）
    /// 每划一次词多两趟跨进程调用，白等。
    func testASuccessfulFirstReadSkipsTheProbe() {
        let pid: pid_t = 910_011
        let script = Script(app: [.text("普通文本框里的字")])
        let reader = wiredReader(pid: pid, script, anchor: CGPoint(x: 300, y: 300))
        XCTAssertEqual(reader.read(), .text("普通文本框里的字"))
        XCTAssertEqual(script.reads, ["app"])
        XCTAssertEqual(reader.answeredFrom, .application(pid))
    }

    /// 探测那一手读到「选区是空的」（命中了同一个 App 的空白处）—— 这是**答复**，不是失败，
    /// 不许再拿第一次的错盖掉它。否则在正文里划完词又点了空白，日志报的是「该控件不支持」，
    /// 而真相是「这次确实没选中东西」。
    func testAnEmptySelectionFromTheProbeIsAnAnswerNotAFailure() {
        let pid: pid_t = 910_012
        let script = Script(app: [.unavailable(.noSelectedTextValue)], atPoint: [.nothingSelected])
        let reader = wiredReader(pid: pid, script, anchor: CGPoint(x: 800, y: 200))
        XCTAssertEqual(reader.read(), .nothingSelected, "探测答了空，就按「没选中内容」报，别报成读失败")
        XCTAssertEqual(script.reads, ["app", "点"])
        XCTAssertNil(reader.answeredFrom, "空选区不是「读到字」，不许记来源")
    }

    /// 每种来源在日志里要有自己的说法（`answeredFrom` 只进成功那一行）。
    /// 都写成「读到了」的话，装机时看不出这次是靠哪一手成的 —— 而下一轮要收窄的正是那一手。
    /// 第四档「代按 ⌘C 取回」是最新加的那一手，也是邮件正文唯一能成的一手：
    /// 它要是和「App 焦点元素」串了线，装机就再也分不出「无障碍修好了」和「靠粘贴板兜住了」。
    func testEveryAnsweringSourceHasItsOwnLogLabel() {
        let labels = [AXSelectedTextReader.Scope.application(1).logLabel,
                      AXSelectedTextReader.Scope.systemWide.logLabel,
                      AXSelectedTextReader.Scope.atPoint(1, CGPoint(x: 1, y: 1)).logLabel,
                      AXSelectedTextReader.Scope.viaCopy(1).logLabel]
        XCTAssertEqual(Set(labels).count, labels.count, "四档来源的说法串了线")
        for label in labels { XCTAssertFalse(label.isEmpty) }
        // 「代按」这一档必须说清是粘贴板那一路，不然装机看到「App 焦点元素」会以为无障碍修好了。
        XCTAssertTrue(AXSelectedTextReader.Scope.viaCopy(nil).logLabel.contains("⌘C"),
                      "日志里要能一眼看出这一趟的字是代按来的")
    }

    /// 超时那一档一次都不补救（对方压根没答话，再问两次还是等满两个超时）。
    func testATimeoutIsNotPokedAgain() {
        let pid: pid_t = 910_006
        let script = Script(app: [.unavailable(.timedOut)])
        let reader = wiredReader(pid: pid, script)
        XCTAssertEqual(reader.read(), .unavailable(.timedOut))
        XCTAssertEqual(script.reads, ["app"])
        XCTAssertTrue(script.writes.isEmpty)
    }

    /// 同一个进程的同一个属性，第二次划词不许再写一遍开关。
    /// 但「试过了」的名单不能挡掉补救本身：第二笔还是要去读系统级那一份。
    func testTheSecondDragInOneProcessDoesNotWriteTheSwitchAgain() {
        let pid: pid_t = 910_007
        let first = Script(app: [.unavailable(.noFocusedElement)], system: [.unavailable(.noFocusedElement)],
                           enable: [false, false])
        XCTAssertEqual(wiredReader(pid: pid, first).read(), .unavailable(.noFocusedElement))
        XCTAssertEqual(first.writes.count, 2)
        let second = Script(app: [.unavailable(.noFocusedElement)], system: [.unavailable(.noFocusedElement)])
        XCTAssertEqual(wiredReader(pid: pid, second).read(), .unavailable(.noFocusedElement))
        XCTAssertTrue(second.writes.isEmpty, "开关每个属性只写一遍：\(second.writes)")
        XCTAssertEqual(second.reads, ["app", "system"], "名单只挡写开关，不挡换来源再读")
    }

    /// 失败那一条路上读几次，要等于那个预算常量。
    /// 这条断言是让那个数**真的在管代码**：预算改成 1，这里读到的是 1 次而常量还是 2，红；
    /// 有人往里加一手补救而不加格数，那一手永远轮不到，也是这里先红。
    /// 第三档脚本就是加进来的一手探测 —— 它上场时同样只多一格，不会连着再换系统级。
    func testTheRecoveryStopsAtTheDocumentedNumberOfReads() {
        for script in [
            Script(app: [.unavailable(.noFocusedElement), .unavailable(.noFocusedElement)], enable: [true]),
            Script(app: [.unavailable(.noFocusedElement)], system: [.unavailable(.noFocusedElement)],
                   enable: [false, false]),
            Script(app: [.unavailable(.noSelectedTextValue)], atPoint: [.unavailable(.noSelectedTextValue)]),
        ] {
            let pid = scriptPid()
            _ = wiredReader(pid: pid, script, anchor: CGPoint(x: 200, y: 200)).read()
            XCTAssertEqual(script.reads.count, AXSelectedTextReader.maximumReadAttemptsOnTheFailurePath,
                           "读到的回数 \(script.reads) 和预算 \(AXSelectedTextReader.maximumReadAttemptsOnTheFailurePath) 不是同一个数")
        }
    }

    /// 快捷键那一条（`.systemWide`）没有补救：它读的就是系统级那一份，再往系统级读一遍还是同一个元素。
    func testTheSystemWideScopeReadsExactlyOnce() {
        let script = Script(app: [.text("不该被读到")], system: [.unavailable(.noFocusedElement)])
        let reader = AXSelectedTextReader(scope: .systemWide)
        reader.readSourceOverride = { script.read($0) }
        XCTAssertEqual(reader.read(), .unavailable(.noFocusedElement))
        XCTAssertEqual(script.reads, ["system"], "系统级那一条只读一次，没有第二手：\(script.reads)")
    }

    // MARK: - 真接口 smoke

    /// 调一次真无障碍调用，只断言「它在超时之前答了」。
    ///
    /// 不断言内容：这台机器上此刻谁在前台、选中了什么，是环境不是被测对象 —— 拿它当判据
    /// 会做出一个「今天绿、明天红」的用例。这一条要钉的只有一件事：
    /// `AXUIElementSetMessagingTimeout` 真的生效了，对方卡住 / 压根没接口时我们**不挂着**。
    /// 挂住才是这条功能最坏的失败模式：后台线程一堵，读回来的那一句永远不上屏，
    /// 而日志里一行都没有。
    func testRealAccessibilityCallAnswersBeforeTheTimeout() {
        let reader = AXSelectedTextReader(scope: .application(getpid()), timeout: 0.2)
        let started = Date()
        let box = ReadBox()
        let expectation = XCTestExpectation(description: "真接口答话")
        DispatchQueue.global(qos: .userInitiated).async {
            box.result = reader.read()
            expectation.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed,
                       "真无障碍调用挂住了 —— 消息超时没生效")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3, "答得太慢，等于没有超时这一档：\(elapsed)s")
        NSLog("%@", "[SelectionPopup] smoke：读到自己（pid=\(getpid())）→ \(box.result?.logReason ?? "nil")")
    }

    /// 一次读取的结果盒：主线程断言、后台线程写，值类型传不过去。
    private final class ReadBox {
        var result: SelectedTextResult?
    }

    // MARK: - 脚本用的假读取

    /// 按脚本答复，并把「读了哪几份来源、写了哪几个属性」记下来。
    /// 补救的次序是这一段唯一的被测对象，而它在真进程上一次也演不出来：那要有辅助功能授权、
    /// 要有个真在前台并且真选中了什么的 App。判据只能取自己摆的脚本。
    private final class Script {
        private var app: [SelectedTextResult]
        private var system: [SelectedTextResult]
        private var atPoint: [SelectedTextResult]
        private var enable: [Bool]
        private(set) var reads: [String] = []
        private(set) var writes: [String] = []
        /// 鼠标点那一手收到的坐标，逐个记下来。
        /// 不记的话「控制器把松手点传丢了」在假件上照样答得上来 —— 只有装机才发现，
        /// 而真 AX 调用在 `swift test` 里演不出来。
        private(set) var points: [CGPoint] = []

        init(app: [SelectedTextResult], system: [SelectedTextResult] = [],
             atPoint: [SelectedTextResult] = [], enable: [Bool] = []) {
            self.app = app
            self.system = system
            self.atPoint = atPoint
            self.enable = enable
        }

        func read(_ source: AXSelectedTextReader.Scope) -> SelectedTextResult {
            switch source {
            case .application:
                reads.append("app")
                return app.isEmpty ? .unavailable(.noFocusedElement) : app.removeFirst()
            case .systemWide:
                reads.append("system")
                return system.isEmpty ? .unavailable(.noFocusedElement) : system.removeFirst()
            case .atPoint(_, let point):
                reads.append("点")
                points.append(point)
                // 没排脚本就答「往上溯也没人持有选区」：这是一次**失败**，
                // 于是没预期这一手的旧用例仍按「报第一次的错」收尾，不会被探测结果悄悄改写。
                return atPoint.isEmpty ? .unavailable(.noSelectedTextValue) : atPoint.removeFirst()
            case .viaCopy:
                // 这一档**不是无障碍来源**（字是从粘贴板拿回来的），真实现里也压根不会走到这里。
                // 写开这一支只为两件事：`Scope` 加了档而这里漏加会编译不过；
                // 万一有人把它当成初始 scope 用，这里记一笔，用例就能看见「链子被绕过了」。
                reads.append("代按")
                return .unavailable(.noSelectedTextValue)
            }
        }

        /// 脚本没排到就答「写不进去」：默认按最坏的那一档（对方两条都不吃）。
        func write(_ name: String) -> Bool {
            writes.append(name)
            return enable.isEmpty ? false : enable.removeFirst()
        }
    }

    /// 每个用例自己一批进程号：那份「已经试过了」的名单是**静态的（进程 × 属性）**，
    /// 几个用例共用一个 pid 的话，后一个会被前一个的名单挡掉 —— 表现成「昨天还绿的用例今天红」，
    /// 而红的原因和被测的代码没有半点关系。
    private func wiredReader(pid: pid_t, _ script: Script, anchor: CGPoint? = nil) -> AXSelectedTextReader {
        let reader = AXSelectedTextReader(scope: .application(pid), anchor: anchor, timeout: 0.05)
        reader.readSourceOverride = { script.read($0) }
        reader.enableOverride = { _, name in script.write(name) }
        return reader
    }

    /// 用例内递增的假进程号（起点离真进程远一点，别撞上 smoke 那条用的 `getpid()`）。
    private var nextScriptPid: pid_t = 920_000
    private func scriptPid() -> pid_t {
        nextScriptPid += 1
        return nextScriptPid
    }

    /// **弹出来的那一条**的最坏耗时 = 读取延迟 + 一次消息超时。
    /// 有人把 0.6s 改成 5s，表现就是「划完词卡一下才弹」甚至整条链路像坏了，而从界面上看不出原因。
    ///
    /// 读不上来那一条不是这个判据：它最坏 = 首读一笔 + **上场的那一手**。三手里最贵的是
    /// 鼠标点那一手（一次命中 + 每格一次选区读 + 每格一次父级读），但它用的是短超时，
    /// 总账由 `worstCaseWaitSeconds()` 一个人算 —— 判据钉那个函数，两个常量谁被改大都会在这里先红。
    /// 那一段跑在后台队列上，而且走到那里就没打算弹任何东西，慢不慢用户看不见 ——
    /// 手势的 HID 回调也不在那条队列上，这是这条功能划的死线。
    /// 两档分开写，是因为合成的一档是手感，败的一档只是不弹。
    func testWorstCaseLatencyStaysUnderASinglePerceptibleBeat() {
        let defaultDelay = TimeInterval(StorageDefaults.selectionPopupReadDelay) / 1_000
        let perCall = SelectionBubbleSettings.messagingTimeout
        XCTAssertEqual(defaultDelay + perCall, 0.85, accuracy: 0.001)
        XCTAssertLessThan(defaultDelay + perCall, 1, "弹出来的那一档要留在 1 秒内，不然就像卡住了")
        XCTAssertLessThanOrEqual(AXSelectedTextReader.worstCaseWaitSeconds(includesCopyHand: false), 2.0,
                                 "补救那一手加上鼠标点那几趟之后，最坏也不能变成「划完词卡半天」还没弹")
        // 代按 ⌘C 那一手加进来的只有一段**轮询上限**，不是一次跨进程往返：
        // 它单独一档算进来，就是要让人看见「这一手上场会让不弹的那一条多等多少」。
        XCTAssertEqual(AXSelectedTextReader.worstCaseWaitSeconds()
                        - AXSelectedTextReader.worstCaseWaitSeconds(includesCopyHand: false),
                       SelectionCopyReader.pollTimeoutCeiling, accuracy: 0.0001,
                       "这一手的等待要么整段算进来，要么整段不算 —— 掺一半最坏情况就没人说得准了")
        // 那个数必须是**算出来的**，不是抄的：常量各改各的、这里还是 2.0 的话，等于没钉。
        XCTAssertGreaterThan(AXSelectedTextReader.worstCaseWaitSeconds(), perCall,
                             "失败那一条最坏该比一次读取久，否则这一手压根没算进补救")
        XCTAssertEqual(AXSelectedTextReader(scope: .systemWide).timeout, perCall,
                       "默认超时是从偏好常量来的，不是两处各写一个 0.6")
    }

    /// 鼠标点那一手用的是**短超时**。
    /// 它是白捡的补救，不是主读：对方慢就放弃。跟着主读那 0.6s 走的话，
    /// 上溯三格 + 两次问父级 = 一趟划词排五六回队，「不弹」就变成「划完词卡半天」。
    func testTheCursorProbeIsGivenAShorterTimeoutThanTheMainRead() {
        XCTAssertLessThan(AXSelectedTextReader.hitTestProbeTimeout,
                          SelectionBubbleSettings.messagingTimeout,
                          "探测的超时不能追上主读，否则最坏那一档直接翻倍")
        XCTAssertLessThanOrEqual(AXSelectedTextReader.maximumElementsProbedAtThePoint, 3,
                                 "往上走一格就是两趟跨进程调用，再多就是拿超时换概率")
        XCTAssertGreaterThan(AXSelectedTextReader.maximumElementsProbedAtThePoint, 1,
                             "只读命中的那一格等于白读：正文里打中的是 AXStaticText，管选区的是祖先")
    }

    /// AppKit 的鼠标坐标原点在**主屏左下角**，`AXUIElementCopyElementAtPosition` 要的是
    /// CG 那套原点在左上角、y 往下的坐标。翻写反的表现是「永远打不中」，
    /// 而这一档在 `swift test` 里没法拿真坐标验 —— 只能把纯函数钉住。
    /// 反向变异：`y` 不翻 / 翻成 `anchor.y - height` / x 也跟着翻，都在这条红。
    func testThePointIsFlippedIntoCoreGraphicsCoordinates() {
        let height: CGFloat = 1_080
        XCTAssertEqual(AXSelectedTextReader.cgPoint(appKit: CGPoint(x: 640, y: 1_080), primaryHeight: height),
                       CGPoint(x: 640, y: 0), "主屏最上面一行（AppKit y=height）在 CG 里是 y=0")
        XCTAssertEqual(AXSelectedTextReader.cgPoint(appKit: CGPoint(x: 640, y: 0), primaryHeight: height),
                       CGPoint(x: 640, y: 1_080), "主屏最底下（AppKit y=0）在 CG 里是 y=height")
        XCTAssertEqual(AXSelectedTextReader.cgPoint(appKit: CGPoint(x: 120, y: 700), primaryHeight: height).x, 120,
                       "x 不跟着翻：那是横轴")
        XCTAssertEqual(AXSelectedTextReader.cgPoint(appKit: CGPoint(x: 300, y: 900), primaryHeight: 2_000).y, 1_100,
                       "按传进来的主屏高度翻，不是按副屏")
    }

    /// 「命中元素属于谁家」这一道闸的前提：`AXUIElementGetPid` 真能拿到 pid。
    /// 拿不到的话上溯那一手就会读别人的元素（我们那枚还没收掉的气泡就在同一行字上面）。
    /// 这里只验取 pid 这个原语本身，不碰选区，所以不需要任何授权。
    func testTheOwnerOfAnElementIsReadable() {
        XCTAssertEqual(AXSelectedTextReader.pid(of: AXUIElementCreateApplication(getpid())), getpid(),
                       "自己建的 App 元素当然该报出自己的 pid")
    }
}
