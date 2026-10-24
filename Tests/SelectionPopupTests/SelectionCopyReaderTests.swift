//
//  SelectionCopyReaderTests.swift
//  SelectionPopupTests
//
//  「无障碍读不到时，替用户按一次 ⌘C 把字从粘贴板取回来」这一手的取证。
//
//  这一手和别的模块不一样：**它写用户的粘贴板**。判据因此全是「次序」和「闸门」，而不是「算得对不对」：
//  - 次序错了（先写哨兵再抄快照）→ 用户刚才复制的东西被哨兵顶掉，永久丢失；
//  - 闸门漏一道（粘贴板是文件时还动手）→ 他刚才复制的文件贴不出来了；
//  - 还原写成五条 `return` 各补一句 → 迟早漏一条，漏的那条就是上面两种。
//  这些从界面上只看得到两件事：「邮件还是不弹」或者「我复制的东西不见了」。前者不伤人，后者伤人，
//  所以这一串的优先级排在「能不能弹出来」前面。
//
//  **跑不到的两段**（不是没写，是这一层演不出来，装机时按日志核）：
//  1. `postCopyKeysToSession` 真投键 —— 要有另一个 App 真在前台真选中了字，测试进程两样都没有。
//     这里只验「投键这一步被走到 / 没被走到」，靠 `postCopyKeys` 接缝。
//  2. `HistoryClipboard.handleTimer` 里「暂停窗口内不记历史」那一句 —— 它是 private、
//     读的是 `NSPasteboard.general`、要 0.5 秒的真计时器。这里只能验闸门本身的取值
//     （`isRecordingPaused` 的引用计数、宽限期、上限、复位），记账那一句归装机日志
//     「[HistoryClipboard] 暂停窗口内的一次粘贴板变化，不记入历史」。
//     反向变异 M110/M111 就是明写着这两条抓不到，不是漏了。
//
//  桩件说明：本机 CommandLineTools 从 2026-10-22 起不带 XCTest，这一批用例当前是用
//  `/tmp/xctstub` 那套桩件（按真签名复刻的 `XCTAssert*` + 手写调度）跑的，判据与真框架一致；
//  Xcode 装回来之后 `swift test` 一条不用改。
//

import AppKit
import Foundation
@testable import SelectionPopup
@testable import Storage
import XCTest

/// 假粘贴板：把每一次调用**按顺序**记下来。次序就是这一手的正确性。
final class ProbePasteboard: SelectionPasteboarding {
    var events: [String] = []
    /// `holdsFileURLs` 被读了几次 —— 动手前一次、拿到后一次，多的少的都是 bug。
    var fileURLChecks = 0
    var changeCountValue = 1
    var textValue: String?
    var filesValue = false
    var snapshotValue: [SelectionPasteboardContent] = []
    var sentinelResult = true
    var restoreResult = true
    /// 投完 ⌘C 之后粘贴板长成什么样（模拟对方 App 真的复制了）。
    var copyOutcome: ((ProbePasteboard) -> Void)?
    /// 还原时递进来的那一份，取证直接看它。
    var restoredWith: [SelectionPasteboardContent]?

    var changeCount: Int { changeCountValue }

    var holdsFileURLs: Bool {
        fileURLChecks += 1
        events.append("files?")
        return filesValue
    }

    func text() -> String? {
        events.append("text")
        return textValue
    }

    func snapshot() -> [SelectionPasteboardContent] {
        events.append("snapshot")
        if snapshotValue.isEmpty, let textValue {
            var content = SelectionPasteboardContent()
            content[.string] = Data(textValue.utf8)
            return [content]
        }
        return snapshotValue
    }

    func writeSentinel(_ text: String) -> Bool {
        events.append("sentinel(\(text.prefix(12)))")
        guard sentinelResult else { return false }
        textValue = text
        changeCountValue += 1
        return true
    }

    func restore(_ content: [SelectionPasteboardContent]) -> Bool {
        events.append("restore(\(content.count))")
        restoredWith = content
        textValue = content.first?[.string].flatMap { String(data: $0, encoding: .utf8) }
        changeCountValue += 1
        return restoreResult
    }

    /// 由 `postCopyKeys` 接缝调用：真 App 收到 ⌘C 之后写了自己的粘贴板。
    func appDidCopy() {
        events.append("copy")
        changeCountValue += 1
        copyOutcome?(self)
    }

    /// 只记主线（不含 `files?` / `text` 这类只读查询）。
    var mainOrder: [String] {
        events.filter { $0.hasPrefix("snapshot") || $0.hasPrefix("sentinel")
            || $0.hasPrefix("restore") || $0 == "copy" }
    }

    /// 有没有**动过**粘贴板。注意不能用 `events.isEmpty`：闸门里的 `holdsFileURLs` 是只读的，
    /// 它合法地会在「什么都没做」的那一条里留下一笔。
    var wroteAnything: Bool {
        events.contains { $0.hasPrefix("snapshot") || $0.hasPrefix("sentinel")
            || $0.hasPrefix("restore") || $0 == "copy" }
    }

    /// 还原回去的那段文本。
    var restoredText: String {
        restoredWith?.first?[.string].flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// 假「代按 ⌘C」：记每一次收到的 pid。
final class ProbeCopyReader: SelectionCopyReading {
    var result: SelectedTextResult = .unavailable(.copyBlocked)
    var calls: [pid_t?] = []

    func read(from pid: pid_t?) -> SelectedTextResult {
        calls.append(pid)
        return result
    }
}

/// 假读取（失败链那一段只要一个固定答复）。
final class ProbeTextReader: SelectionTextReading {
    let answer: SelectedTextResult

    init(_ answer: SelectedTextResult) { self.answer = answer }

    func read() -> SelectedTextResult { answer }
}

final class SelectionCopyReaderTests: XCTestCase {
    /// 装配一台「对方 App 在前台、粘贴板干净、投键就复制」的标准机器。
    /// `fresh` = 先把上一段留下的单飞占位清掉；测「两路撞车」那一条时传 false。
    private func makeReader(_ pb: ProbePasteboard, ownPID: pid_t = 100, frontmost: pid_t? = 200,
                            fresh: Bool = true) -> SelectionCopyReader {
        let reader = SelectionCopyReader()
        reader.pasteboard = pb
        reader.ownPID = { ownPID }
        reader.frontmostPID = { frontmost }
        reader.pollTimeout = 0.05
        reader.sleep = { _ in Thread.sleep(forTimeInterval: 0.005) }
        reader.postCopyKeys = { true }
        // 默认不许碰真闸门：用例里没写的那一条会读到上一个个用例留下的暂停状态。
        reader.beginSuppression = {}
        reader.endSuppression = {}
        if fresh { SelectionCopyReader.resetCopyHandForTesting() }
        return reader
    }

    /// 一条「对方真的复制了」的机器：投键之后粘贴板长出新内容。
    private func makeCopyingReader(_ pb: ProbePasteboard, copied: String) -> SelectionCopyReader {
        let reader = makeReader(pb)
        reader.postCopyKeys = {
            pb.textValue = copied
            pb.appDidCopy()
            return true
        }
        return reader
    }

    // MARK: A. 次序

    /// 先抄快照 → 写哨兵 → 投键 → 拿到字 → 还原。这一串换任何一步都会弄坏用户复制的东西。
    func testOrderIsSnapshotSentinelPostThenRestore() {
        let pb = ProbePasteboard()
        pb.textValue = "用户原来复制的东西"
        var suppressions: [String] = []
        let reader = makeCopyingReader(pb, copied: "选中的字")
        reader.beginSuppression = { suppressions.append("begin") }
        reader.endSuppression = { suppressions.append("end") }

        let result = reader.read(from: 200)

        XCTAssertEqual(result.string, "选中的字")
        XCTAssertEqual(pb.mainOrder,
                       ["snapshot", "sentinel(用户原来复制的东西)", "copy", "restore(1)"],
                       "次序：\(pb.events)")
        XCTAssertEqual(suppressions, ["begin", "end"], "历史闸门必须成对")
        XCTAssertEqual(pb.restoredWith?.count, 1)
        XCTAssertEqual(pb.restoredText, "用户原来复制的东西", "还原回去的是原文本，不是哨兵")
        XCTAssertEqual(pb.fileURLChecks, 2, "动手前判一次、拿到后再判一次")
    }

    // MARK: B. 每一支失败都要还原

    /// 五条失败出路都得把粘贴板放回去 —— 漏任何一条的表现都是「用户刚才复制的东西没了」。
    func testEveryFailureBranchStillRestoresThePasteboard() {
        let cases: [(String, (ProbePasteboard, SelectionCopyReader) -> Void, String)] = [
            ("对方没响应", { (_, r) in r.postCopyKeys = { true } }, "代按 ⌘C 后粘贴板没动"),
            ("拿回来没有文本", { (pb, r) in
                r.postCopyKeys = { pb.textValue = nil; pb.appDidCopy(); return true }
            }, "代按 ⌘C 拿回来的不是文字"),
            ("拿回来是文件", { (pb, r) in
                r.postCopyKeys = { pb.filesValue = true; pb.textValue = "/tmp/a.txt"; pb.appDidCopy(); return true }
            }, "代按 ⌘C 拿回来的不是文字"),
            ("哨兵写不上", { (pb, r) in pb.sentinelResult = false; r.postCopyKeys = { true } },
             "代按这一手被安全闸挡掉"),
            ("键投不出去", { (_, r) in r.postCopyKeys = { false } }, "代按这一手被安全闸挡掉"),
        ]
        for (label, setup, expected) in cases {
            let pb = ProbePasteboard()
            pb.textValue = "旧的复制"
            var suppressions: [String] = []
            let reader = makeReader(pb)
            reader.beginSuppression = { suppressions.append("begin") }
            reader.endSuppression = { suppressions.append("end") }
            setup(pb, reader)

            let result = reader.read(from: 200)

            XCTAssertTrue(pb.events.contains { $0.hasPrefix("restore") },
                          "\(label)：没还原粘贴板：\(pb.events)")
            XCTAssertEqual(suppressions, ["begin", "end"], "\(label)：闸门没成对关闭")
            XCTAssertEqual(result.logReason, expected, "\(label)：归因不对")
        }
    }

    /// 失败那两支里，只要**写过**哨兵，还原就必须把原文本搬回去。
    func testFailureBranchesBringBackTheOriginalText() {
        let pb = ProbePasteboard()
        pb.textValue = "旧的复制"
        let reader = makeReader(pb)
        reader.postCopyKeys = { pb.textValue = nil; pb.appDidCopy(); return true }
        _ = reader.read(from: 200)
        XCTAssertEqual(pb.restoredText, "旧的复制", "拿回来没有文本，也要把他原来那份放回去")
    }

    // MARK: C. 四道闸

    /// 闸 4（上半）：前台是我们自己 —— 偏好页里正划着字按下快捷键，不能把那个框抄进粘贴板。
    func testGateSkipsWhenFrontmostIsOurselves() {
        let pb = ProbePasteboard()
        pb.textValue = "正在编辑的框"
        let reader = makeReader(pb, ownPID: 100, frontmost: 100)
        let result = reader.read(from: 100)
        XCTAssertEqual(result.logReason, "前台已换人（或就是我们自己），没有代按")
        XCTAssertFalse(pb.wroteAnything, "一道都没过就不许动粘贴板：\(pb.events)")
    }

    /// 闸 4（下半）：字是刚才那个 App 的，键不能打到现在这个头上 —— 投错了收不回来。
    func testGateSkipsWhenFrontmostChangedAfterSelection() {
        let pb = ProbePasteboard()
        let reader = makeReader(pb, frontmost: 300)
        XCTAssertEqual(reader.read(from: 200).logReason, "前台已换人（或就是我们自己），没有代按")
        XCTAssertFalse(pb.wroteAnything)
    }

    /// 连前台是谁都认不出来：不做，别拿「大概是他」去投键。
    func testGateSkipsWhenFrontmostIsUnknown() {
        let pb = ProbePasteboard()
        let reader = makeReader(pb, frontmost: nil)
        XCTAssertEqual(reader.read(from: nil).logReason, "前台已换人（或就是我们自己），没有代按")
        XCTAssertFalse(pb.wroteAnything)
    }

    /// 闸 3（上半）：粘贴板上现在是文件。`public.file-url` 存的是资源描述符，
    /// 逐类型回放**不保证**还能贴出同一个文件 —— 宁可少弹一次也不弄坏他的文件复制。
    func testGateSkipsWhenPasteboardHoldsFiles() {
        let pb = ProbePasteboard()
        pb.filesValue = true
        pb.textValue = "/tmp/大文件.zip"
        let reader = makeReader(pb)
        XCTAssertEqual(reader.read(from: 200).logReason, "代按这一手被安全闸挡掉")
        XCTAssertFalse(pb.wroteAnything)
    }

    /// 单飞：两路同时在动粘贴板会互相踩（后一手把前一手抄的快照当成新内容还原回去）。
    /// 快速连划两下真能碰上：每次松手都排一次读取，而这一手要等 `pollTimeout`。
    func testSecondHandGivesUpWhileAnotherIsRunning() {
        XCTAssertTrue(SelectionCopyReader.claimCopyHand(), "没人跑时应该能占位")
        let pb = ProbePasteboard()
        let reader = makeReader(pb, fresh: false)
        XCTAssertEqual(reader.read(from: 200).logReason, "代按这一手被安全闸挡掉")
        XCTAssertFalse(pb.wroteAnything)
        // 挡下来之前只做过**只读**的那一下判断（是不是文件），一次写都没有。
        XCTAssertEqual(pb.events, ["files?"], "判据顺序：先判文件、再占位")
        SelectionCopyReader.releaseCopyHand()
        XCTAssertTrue(SelectionCopyReader.claimCopyHand(), "释放后要能再占上")
        SelectionCopyReader.releaseCopyHand()
    }

    // MARK: D. 判据是 changeCount，不是内容

    /// 对方压根没响应时，**不许**把用户十分钟前复制的东西当成「这次选中的字」读回来。
    /// 这就是「先写哨兵跳一格、再判比它大」那一手存在的唯一理由。
    func testNoResponseIsNotTheOldCopy() {
        let pb = ProbePasteboard()
        pb.textValue = "十分钟前复制的东西"
        let reader = makeReader(pb)
        let result = reader.read(from: 200)
        XCTAssertEqual(result.logReason, "代按 ⌘C 后粘贴板没动")
        XCTAssertNotEqual(result.string, "十分钟前复制的东西")
        XCTAssertEqual(pb.restoredText, "十分钟前复制的东西", "没读到也要还原")
    }

    // MARK: E. 纯函数

    /// 哨兵写**用户原来那份文本**，不写调试标记：万一他正好在这一秒里按 ⌘V，贴出来还是他自己的东西。
    func testSentinelKeepsTheUsersOwnText() {
        XCTAssertEqual(SelectionCopyReader.sentinelText(from: "他刚才复制的"), "他刚才复制的")
        XCTAssertEqual(SelectionCopyReader.sentinelText(from: nil), SelectionCopyReader.sentinelMarker)
        XCTAssertEqual(SelectionCopyReader.sentinelText(from: ""), SelectionCopyReader.sentinelMarker,
                       "空串也算没文本")
    }

    /// 只有**单纯** ⌘C 才算自激。加任何一个别的修饰键都不算：那一档不会命中我们自己的快捷键监听。
    func testOnlyPlainCommandCCollidesWithTheCopyHand() {
        XCTAssertTrue(SelectionBubbleSettings.isPlainCommandC("keyCode=8, flags=1048576"))
        XCTAssertFalse(SelectionBubbleSettings.isPlainCommandC("keyCode=8, flags=1310720"), "⌃⌘C 不算")
        XCTAssertFalse(SelectionBubbleSettings.isPlainCommandC("keyCode=7, flags=1048576"), "⌘X 不算")
        XCTAssertFalse(SelectionBubbleSettings.isPlainCommandC("keyCode=11, flags=1310720"), "默认 ⌃⌘B 不算")
        XCTAssertFalse(SelectionBubbleSettings.isPlainCommandC(""), "录坏了也不许炸")
    }

    private func snapshot(enabled: Bool = true, fallback: Bool = true,
                          shortcut: String = "keyCode=11, flags=1310720",
                          actions: [SelectionBubbleAction] = SelectionBubbleAction.allCases)
        -> SelectionBubbleSettings {
        SelectionBubbleSettings(enabled: enabled, shortcut: shortcut, readDelay: 0.25,
                               actions: actions, copyFallbackEnabled: fallback)
    }

    /// 五档取值。自激那一条用纯函数挡死，比「加个冷却时间」准 —— 冷却只把环变慢，没拆掉。
    func testCanUseCopyFallbackHasFiveGates() {
        XCTAssertTrue(snapshot().canUseCopyFallback)
        XCTAssertFalse(snapshot(enabled: false).canUseCopyFallback, "总开关关掉")
        XCTAssertFalse(snapshot(fallback: false).canUseCopyFallback, "这一手自己那颗开关关掉")
        XCTAssertFalse(snapshot(shortcut: "keyCode=8, flags=1048576").canUseCopyFallback, "录成 ⌘C")
        XCTAssertFalse(snapshot(actions: []).canUseCopyFallback, "四格全关：读上来也没地方摆")
    }

    // MARK: F. 接进失败链

    /// 无障碍读得到就**绝不**出这一手，一次粘贴板都不碰。
    func testAccessibilitySuccessNeverTouchesThePasteboard() {
        let fake = ProbeCopyReader()
        fake.result = .text("不该被用到")
        var reads = 0
        let reader = AXSelectedTextReader(scope: .application(200))
        reader.readSourceOverride = { _ in reads += 1; return .text("无障碍读到的") }
        reader.copyFallback = fake
        XCTAssertEqual(reader.read().string, "无障碍读到的")
        XCTAssertEqual(fake.calls.count, 0, "成功那一条不许出这一手")
        XCTAssertEqual(reads, 1)
    }

    /// 失败链最后一手拿到字：来源要记成「代按 ⌘C」，日志那行才说得出这次是哪一路。
    func testCopyHandIsTheLastResortAndRecordsItsSource() {
        let fake = ProbeCopyReader()
        fake.result = .text("从粘贴板拿回来的")
        let reader = AXSelectedTextReader(scope: .application(200))
        reader.readSourceOverride = { _ in .unavailable(.noSelectedTextValue) }
        reader.copyFallback = fake
        XCTAssertEqual(reader.read().string, "从粘贴板拿回来的")
        XCTAssertEqual(reader.answeredFrom, .viaCopy(200))
        XCTAssertEqual(fake.calls, [200], "pid 要传过去，不能让它自己猜前台")
    }

    /// 加了这一手**不该**改变无障碍那几手的回数：它是「失败之后」，不是「多试一遍」。
    func testCopyHandDoesNotChangeTheAccessibilityReadCount() {
        var withHand = 0
        let a = AXSelectedTextReader(scope: .application(200))
        a.readSourceOverride = { _ in withHand += 1; return .unavailable(.noSelectedTextValue) }
        let fake = ProbeCopyReader()
        fake.result = .text("拿回来的")
        a.copyFallback = fake
        _ = a.read()

        var withoutHand = 0
        let b = AXSelectedTextReader(scope: .application(200))
        b.readSourceOverride = { _ in withoutHand += 1; return .unavailable(.noSelectedTextValue) }
        _ = b.read()

        XCTAssertEqual(withHand, withoutHand, "这一手不该挤掉也不该增加无障碍那几手")
    }

    /// 没有这一手的时候，报的是无障碍那一次的错，不是「粘贴板读不到」。
    func testWithoutCopyHandTheAccessibilityFailureIsReported() {
        let reader = AXSelectedTextReader(scope: .application(200))
        reader.readSourceOverride = { _ in .unavailable(.noSelectedTextValue) }
        XCTAssertEqual(reader.read().logReason, "焦点元素当前没有选区（选区可能在它的子树里）")
    }

    /// 这一手白跑（没选中东西）时，日志仍按**第一次**的失败归因：那才是真原因。
    func testWhiteRunKeepsTheFirstAttribution() {
        let fake = ProbeCopyReader()
        fake.result = .unavailable(.copyNothingCopied)
        let reader = AXSelectedTextReader(scope: .application(200))
        reader.readSourceOverride = { _ in .unavailable(.selectedTextUnsupported) }
        reader.copyFallback = fake
        XCTAssertEqual(reader.read().logReason, "该控件没有选中文字属性")
    }

    /// 「压根没选中」是一个**答复**，不是失败：不该再往下找、也不该报安全闸。
    func testNothingSelectedFromCopyHandIsAcceptedAsAnAnswer() {
        let fake = ProbeCopyReader()
        fake.result = .nothingSelected
        let reader = AXSelectedTextReader(scope: .application(200))
        reader.readSourceOverride = { _ in .unavailable(.noSelectedTextValue) }
        reader.copyFallback = fake
        XCTAssertEqual(reader.read().logReason, "选区为空")
    }

    /// 超时与原始错误码**不上**这一手：超时是对方卡住（再投一次键只会更卡），
    /// 错误码说明这条属性压根不该读 —— 这两种都该照原样报出去。
    func testTimeoutAndAPIErrorDoNotUseTheCopyHand() {
        for reason: SelectedTextResult.Unavailable in [.timedOut, .apiError(-25204)] {
            let fake = ProbeCopyReader()
            fake.result = .text("不该被用到")
            let reader = AXSelectedTextReader(scope: .application(200))
            reader.readSourceOverride = { _ in .unavailable(reason) }
            reader.copyFallback = fake
            let answer = reader.read()
            XCTAssertEqual(fake.calls.count, 0, "\(reason.logReason) 那一档不许出这一手")
            XCTAssertEqual(answer.logReason, reason.logReason, "\(reason)：归因被这一手盖掉了")
        }
        // 反向对照：系统级那一条的超时同样不上这一手（不是「只有 application 那一条有闸」）。
        let fakeWide = ProbeCopyReader()
        let readerWide = AXSelectedTextReader(scope: .systemWide)
        readerWide.readSourceOverride = { _ in .unavailable(.timedOut) }
        readerWide.copyFallback = fakeWide
        _ = readerWide.read()
        XCTAssertEqual(fakeWide.calls.count, 0)
    }

    /// 快捷键那一路（`.systemWide`）也能上这一手，但 pid 要传 nil：
    /// 它读的是系统级焦点，本来就只认「此刻前台是谁」，传一个按下那一刻的 pid 反而是错的。
    func testSystemWideAlsoUsesTheCopyHandWithNilPID() {
        let fake = ProbeCopyReader()
        fake.result = .text("键盘选字拿回来的")
        let reader = AXSelectedTextReader(scope: .systemWide)
        reader.readSourceOverride = { _ in .unavailable(.noSelectedTextValue) }
        reader.copyFallback = fake
        XCTAssertEqual(reader.read().string, "键盘选字拿回来的")
        XCTAssertEqual(fake.calls, [nil], "系统级那一条要传 nil")
        XCTAssertEqual(reader.answeredFrom, .viaCopy(nil))
    }

    /// 手感预算：出这一手最坏多等 `pollTimeout` 那么多；不含它的弹得出来那一档仍在一拍之内。
    func testWorstCaseWaitGrowsByExactlyThePollCeiling() {
        let withHand = AXSelectedTextReader.worstCaseWaitSeconds()
        let withoutHand = AXSelectedTextReader.worstCaseWaitSeconds(includesCopyHand: false)
        XCTAssertEqual(withHand - withoutHand, SelectionCopyReader.pollTimeoutCeiling, accuracy: 0.0001,
                       "多等的就该只有这一手的轮询上限，别把无障碍那几手也算重了")
        XCTAssertEqual(withHand, 2.15, accuracy: 0.001)
        XCTAssertLessThanOrEqual(withoutHand, 2.0, "弹得出来的那一条不该被这一手拖慢")
    }

    // MARK: G. 粘贴板历史的闸门

    /// 这一手要写三次粘贴板（哨兵、⌘C、还原）。不给自家历史加闸门，历史里就多出三条用户没做过的复制。
    /// 引用计数是因为生产里监听实例不止一个（历史面板、偏好页各一只）。
    func testRecordingPauseIsReferenceCounted() {
        HistoryClipboardManager.resetRecordingPause()
        XCTAssertFalse(HistoryClipboardManager.isRecordingPaused)

        HistoryClipboardManager.beginRecordingPause()
        XCTAssertTrue(HistoryClipboardManager.isRecordingPaused)
        HistoryClipboardManager.beginRecordingPause()
        HistoryClipboardManager.endRecordingPause()
        XCTAssertTrue(HistoryClipboardManager.isRecordingPaused, "两层里退掉一层仍然挡着")
        HistoryClipboardManager.endRecordingPause()
        XCTAssertTrue(HistoryClipboardManager.isRecordingPaused, "退到底还有宽限一跳：还原那一写不该记账")

        XCTAssertGreaterThan(HistoryClipboardManager.recordingPauseGrace, 0.5,
                             "宽限期必须比一个 tick(0.5s) 长，否则还原那一写还是会记进历史")
        XCTAssertGreaterThanOrEqual(HistoryClipboardManager.recordingPauseCeiling, 5,
                                    "必须有上限，否则漏一次 end 就永远不记历史了")

        HistoryClipboardManager.resetRecordingPause()
        XCTAssertFalse(HistoryClipboardManager.isRecordingPaused, "复位要能清干净（异常恢复的口子）")
    }

    /// 宽限期一过必须放开：否则用户自己的复制会被白白漏记。
    func testRecordingPauseReleasesAfterTheGraceWindow() {
        HistoryClipboardManager.resetRecordingPause()
        HistoryClipboardManager.beginRecordingPause()
        HistoryClipboardManager.endRecordingPause()
        XCTAssertTrue(HistoryClipboardManager.isRecordingPaused)
        Thread.sleep(forTimeInterval: HistoryClipboardManager.recordingPauseGrace + 0.15)
        XCTAssertFalse(HistoryClipboardManager.isRecordingPaused, "过了宽限期还不放开就是漏记")
        HistoryClipboardManager.resetRecordingPause()
    }

    /// 一次没有配对的 `end`（异常路径、或者将来有人误调）不该开出一个宽限窗口：
    /// 代价是那 0.6 秒里用户的真复制被白白漏记一条。这一条是桩件跑出来的**真缺陷**，已修。
    func testStrayEndDoesNotOpenTheGate() {
        HistoryClipboardManager.resetRecordingPause()
        HistoryClipboardManager.endRecordingPause()
        XCTAssertFalse(HistoryClipboardManager.isRecordingPaused, "没人 begin 时 end 不该把闸门打开")
        HistoryClipboardManager.resetRecordingPause()
    }

    // MARK: H. 控制器：开关决定第三个参数

    /// 开关怎么摆，决定控制器往读取器里递不递这一手。四种「不递」在界面上长得一模一样
    /// （读不到就不弹），只有这一格能把它们分开。
    func testControllerPassesTheCopyHandOnlyWhenAllowed() {
        func thirdArg(_ settings: SelectionBubbleSettings) -> (called: Bool, value: SelectionCopyReading?) {
            var captured: [SelectionCopyReading?] = []
            let controller = SelectionBubbleController(
                readerFactory: { _, _, copy in
                    captured.append(copy)
                    return ProbeTextReader(.unavailable(.noSelectedTextValue))
                },
                frontmostApp: { nil },
                isAppAllowed: { _ in true },
                settings: settings)
            controller.showSelection(at: CGPoint(x: 400, y: 400))
            return (captured.first != nil, captured.first ?? nil)
        }

        XCTAssertTrue(thirdArg(snapshot()).value != nil, "开关开着 → 递进来一个真的这一手")
        XCTAssertNil(thirdArg(snapshot(fallback: false)).value, "开关关掉 → 递 nil")
        XCTAssertNil(thirdArg(snapshot(shortcut: "keyCode=8, flags=1048576")).value,
                     "录成 ⌘C → 递 nil：自激那条路在这里堵死")
        XCTAssertFalse(thirdArg(snapshot(enabled: false)).called, "总开关关掉 → 连读都不读")
        XCTAssertFalse(thirdArg(snapshot(actions: [])).called, "格子全关 → 连读都不读")
    }

    /// 划词那一条（走 `application(pid)`）也照样把这一手递进去，不只是快捷键那一条有。
    func testAutoPopPathAlsoOffersTheCopyHand() {
        let probe = makeProbe(result: .unavailable(.noSelectedTextValue))
        probe.settle { probe.controller.evaluate(drag: armedDrag(end: CGPoint(x: 600, y: 500)), modifiers: []) }
        XCTAssertEqual(probe.reader.copyHands, [true], "松手那一次读取必须带着这一手")
        XCTAssertEqual(probe.reader.scopes, [.application(4321)], "自动弹仍然走 application(pid)")
    }

    /// 那颗开关关掉时，划词那一条递进去的必须是 nil（不是「递了但内部自己再判断」）。
    func testAutoPopPathStopsOfferingTheCopyHandWhenSwitchedOff() {
        let probe = makeProbe(result: .unavailable(.noSelectedTextValue), copyFallback: false)
        probe.settle { probe.controller.evaluate(drag: armedDrag(end: CGPoint(x: 600, y: 500)), modifiers: []) }
        XCTAssertEqual(probe.reader.copyHands, [false], "开关关掉就不能把这一手递进去")
    }

    /// 快捷键那一条也带这一手（`showForCurrentSelection` → `.systemWide`）。
    func testManualTriggerAlsoOffersTheCopyHand() {
        let probe = makeProbe(result: .unavailable(.noSelectedTextValue))
        probe.settle { probe.controller.showForCurrentSelection() }
        XCTAssertEqual(probe.reader.copyHands, [true])
        XCTAssertEqual(probe.reader.scopes, [.systemWide])
    }

    // MARK: I. 真粘贴板（只碰自建那一份）

    /// `SystemPasteboard` 的逐类型搬运。这里**不动用户的 `NSPasteboard.general`**：
    /// 往那上面写一次就把他刚复制的东西顶掉了，那是拿用户数据换覆盖率。
    func testSystemPasteboardRoundTripOnANamedBoard() {
        let named = NSPasteboard(name: NSPasteboard.Name("com.macstroke.probe.\(getpid())"))
        let pb = SystemPasteboard(pasteboard: named)

        XCTAssertTrue(pb.writeSentinel("探针一写"))
        XCTAssertEqual(pb.text(), "探针一写")
        let snap = pb.snapshot()
        XCTAssertEqual(snap.count, 1, "抄得下来")

        let firstCount = pb.changeCount
        XCTAssertTrue(pb.writeSentinel("探针二写"))
        XCTAssertEqual(pb.text(), "探针二写", "哨兵确实顶掉了旧的")
        XCTAssertGreaterThan(pb.changeCount, firstCount, "changeCount 会跳 —— 这一手的判据全靠它")

        XCTAssertTrue(pb.restore(snap))
        XCTAssertEqual(pb.text(), "探针一写", "还原回去了")
        XCTAssertFalse(pb.holdsFileURLs, "纯文本不该被判成文件")

        named.clearContents()
        XCTAssertTrue(pb.restore([]), "空快照 = 原来就是空的：只清，别拿 writeObjects([]) 去报错")
        XCTAssertNil(pb.text())
    }

    // MARK: - 自动贴那一手的本体

    /// 第七轮加的 ⌘V 只有这三件事能在测试进程里验：**键码是 V、修饰键只剩 ⌘、按下与抬起都在**。
    /// 投到哪一层（session / HID）看不见，见文件头第 1 条 —— 那一条靠装机的日志核。
    ///
    /// 为什么这三件值得单列一条：两种写坏的形状都是「装在真机上才露出来」的坏 ——
    /// 键码抄成 8（那是 C）就等于替用户又复制一次，把他刚复制的东西覆盖掉；
    /// 漏了 `.maskCommand` 就成了往别人的输入框里打一个字母「v」。
    /// 而这两样在接缝层的用例里都看不见：`postPasteKeys` 是颗假的，只记「有没有被调用」。
    func testTheInjectedPasteIsCommandVUpDown() throws {
        let events = try XCTUnwrap(SelectionCopyReader.pasteEvents(), "CGEvent 造不出来")
        XCTAssertEqual(SelectionCopyReader.pasteKeyCode, 9, "V 的 Carbon 键码是 9")
        XCTAssertEqual(events.down.type, .keyDown)
        XCTAssertEqual(events.up.type, .keyUp, "漏了抬起 = 前台看到 ⌘V 一直按着")
        XCTAssertEqual(events.down.getIntegerValueField(.keyboardEventKeycode),
                       Int64(SelectionCopyReader.pasteKeyCode))
        XCTAssertEqual(events.up.getIntegerValueField(.keyboardEventKeycode),
                       Int64(SelectionCopyReader.pasteKeyCode),
                       "抬起那一下换了键码，等于按住了另一颗键")
        XCTAssertEqual(events.down.flags, .maskCommand)
        XCTAssertEqual(events.up.flags, .maskCommand, "修饰键不是只剩 ⌘：那就不是 ⌘V")
    }
}
