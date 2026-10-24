//
//  SelectionBubbleControllerTests.swift
//  SelectionPopupTests
//
//  整条链路的取证：松手 → 判定 → 谁在前台 → 后台读 → 回主线程抛上屏。
//  真事件、真窗口、真粘贴板都不在这里（见 Fakes.swift 开头那五条铁律），留真的是顺序和作废条件：
//  「什么时候不许弹」这一半比「什么时候弹」更容易写错，也最难在装机时发现。
//

import AppKit
import CoreGraphics
import Storage
import XCTest
@testable import SelectionPopup

final class SelectionBubbleControllerTests: XCTestCase {
    private let anchor = CGPoint(x: 500, y: 400)

    /// 正常路径：在别人家的 App 上拖过一段字 → 读那个进程 → 弹的是裁过首尾的那段，
    /// 位置是松手那一点。scope 也要钉住 —— 读错了对象就是「在 A 里划词、弹的是 B 的选区」。
    func testADragOnAnotherAppReadsThatAppAndShowsTheTrimmedText() {
        let probe = makeProbe(result: .text("  划词气泡  \n"))
        probe.settle { probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: []) }
        XCTAssertEqual(probe.reader.reads, 1)
        XCTAssertEqual(probe.reader.scopes, [.application(4321)], "该读的是松手那一刻在前台的那个进程")
        XCTAssertEqual(probe.shown, [Shown(text: "划词气泡", anchor: anchor)])
    }

    /// 反向变异 M33：把「必须有拖动」删掉，全系统每一次点东西都会冒一条气泡。
    /// 从控制器这一头验一次：不光判定要说「不算」，读取那一步也必须压根不发生 ——
    /// 读一次就是往别人进程里发一趟无障碍调用，白跑。
    func testASingleClickDoesNotEvenRead() {
        let probe = makeProbe()
        probe.settle {
            probe.controller.evaluate(drag: dragSample(from: CGPoint(x: 400, y: 400),
                                                       to: self.anchor, dragEvents: 0),
                                      modifiers: [])
        }
        XCTAssertEqual(probe.reader.reads, 0)
        XCTAssertTrue(probe.shown.isEmpty)
    }

    /// 反向变异 M34：把「空结果也抛上屏」写回去，屏幕上就多一条四格全无事干的空气泡。
    /// 三种「没字」各验一遍：真没选中、纯空白、读不到。
    func testNothingWorthShowingNeverReachesTheScreen() {
        let cases: [(String, SelectedTextResult)] = [
            ("选区为空", .nothingSelected),
            ("只有空白", .text("   \n ")),
            ("超时", .unavailable(.timedOut)),
            ("控件不支持", .unavailable(.selectedTextUnsupported)),
            ("太长了", .text(String(repeating: "字", count: 5_000))),
        ]
        for (name, result) in cases {
            let probe = makeProbe(result: result)
            probe.settle { probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: []) }
            XCTAssertEqual(probe.reader.reads, 1, "\(name)：该读还是要读一次，才知道它没字")
            XCTAssertTrue(probe.shown.isEmpty, "\(name)：这种结果不许抛上屏")
        }
    }

    /// 读回来到上屏之间那 50ms 里，人可能已经按下、可能已经切走。两种都算这一次作废。
    /// 少了这一条，表现是「切到微信之后，刚才在别处划的那段字突然弹出来」。
    func testAnAppSwitchBeforeTheReadArrivesKillsIt() {
        let probe = makeProbe()
        probe.settle {
            probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: [])
            probe.controller.noteAppSwitch()
        }
        XCTAssertTrue(probe.shown.isEmpty, "切了 App，那次读取不该上屏")
    }

    /// 读的那一瞬间前台换了进程：读取照样发生（已经发出去了，收不回来），但结果不许上屏。
    /// 这一条用的是「pid 变了」那道门，和上面那条用的序号是两道不同的门 —— 都得单独钉。
    func testAProcessChangeDuringTheReadKillsTheResult() {
        let front = MutableFront(FrontApp(bundleID: "com.example.other", pid: 4321))
        let probe = Probe(result: .text("hello"),
                          frontmost: { front.current() },
                          isAppAllowed: { _ in true },
                          isSelfApp: { _ in false },
                          enabled: true,
                          readDelay: 0.05)
        // 读的那一趟正好把人已经走了这件事演出来。
        probe.reader.onRead = { front.app = FrontApp(bundleID: "com.example.another", pid: 9999) }
        probe.settle { probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: []) }
        XCTAssertEqual(probe.reader.reads, 1, "调用已经发出去了，收不回来 —— 这一条只验结果不许上屏")
        XCTAssertTrue(probe.shown.isEmpty)
    }

    /// 过滤名单里的那些 App 不弹：判定来自 App 层注入的黑白名单，本模块不认识 RuleEngine。
    /// 读都不该读 —— 一旦读了就是往一个明说不要这功能的进程里发无障碍调用。
    func testFilteredAppIsNotEvenRead() {
        let probe = makeProbe(isAppAllowed: { $0 != "com.example.other" })
        probe.settle { probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: []) }
        XCTAssertEqual(probe.reader.reads, 0)
    }

    /// 在偏好页里划一段字也弹一条，等于盖住自己正要改的那个框。
    func testOurOwnAppIsSkipped() {
        let probe = makeProbe(isSelfApp: { _ in true })
        probe.settle { probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: []) }
        XCTAssertEqual(probe.reader.reads, 0)
    }

    /// 认不出前台是谁（刚启动、正在切换那一瞬）就当没这回事：宁可不弹，也不弹一条来路不明的字。
    func testAnUnidentifiableFrontAppIsSkipped() {
        let cases: [(String, FrontApp?)] = [
            ("nil 前台", nil),
            ("没有包名", FrontApp(bundleID: nil, pid: 4321)),
        ]
        for (name, front) in cases {
            let probe = Probe(result: .text("hello"),
                              frontmost: { front },
                              isAppAllowed: { _ in true },
                              isSelfApp: { _ in false },
                              enabled: true,
                              readDelay: 0.05)
            probe.settle { probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: []) }
            XCTAssertEqual(probe.reader.reads, 0, "\(name)：认不出来就不许读")
            XCTAssertTrue(probe.shown.isEmpty, "\(name)")
        }
    }

    // MARK: - 真事件走一遍（按下 → 拖 → 松手）

    /// 从假监听拿到回调，演一条真拖动。这一条验的是 `handle` 那三笔的接法：
    /// 少累计一笔拖动就永远判成单击，松手取错端点就弹歪。
    func testAFullDragPlayedThroughTheMonitorShowsTheBubble() {
        let probe = makeProbe(result: .text("拖出来的字"))
        probe.controller.apply(settings: SelectionBubbleSettings(
            enabled: true, shortcut: "", readDelay: 0.05))
        XCTAssertEqual(probe.registeredMasks, [SelectionBubbleController.monitorMask],
                       "挂监听用的就是那三样左键事件（M38）")
        probe.settle {
            probe.playDrag(from: CGPoint(x: 300, y: 600), to: CGPoint(x: 420, y: 600))
        }
        XCTAssertEqual(probe.shown, [Shown(text: "拖出来的字", anchor: CGPoint(x: 420, y: 600))])
    }

    /// 同一条路演一次单击：按下、松手，中间一笔拖动都没有 → 什么都不读。
    func testASingleClickPlayedThroughTheMonitorShowsNothing() {
        let probe = makeProbe()
        probe.controller.apply(settings: SelectionBubbleSettings(enabled: true, shortcut: "", readDelay: 0.05))
        probe.settle {
            probe.play(.leftMouseDown, at: CGPoint(x: 300, y: 600))
            probe.play(.leftMouseUp, at: CGPoint(x: 300, y: 600))
        }
        XCTAssertEqual(probe.reader.reads, 0)
        XCTAssertTrue(probe.shown.isEmpty)
    }

    /// 没挂监听的时候（功能关着），事件压根不会到这里；这里验的是「按下之前没有 drag 记录」这一档
    /// 不会崩、也不会读：松手时手上没有对应的一次按下，就当没这回事。
    func testALooseMouseUpWithoutADownIsIgnored() {
        let probe = makeProbe()
        probe.controller.apply(settings: SelectionBubbleSettings(enabled: true, shortcut: "", readDelay: 0.05))
        probe.settle {
            probe.play(.leftMouseUp, at: CGPoint(x: 400, y: 600))
        }
        XCTAssertEqual(probe.reader.reads, 0)
    }

    // MARK: - 总开关

    /// **总开关关掉要关到根上**：不是「继续监听然后什么都不弹」，而是连那三样左键的全局监听
    /// 都不挂。用户点掉这个勾，就该是这台机器上再也没有这件事。
    func testTheMasterSwitchTakesTheWholeMonitorDownNotJustTheBubble() {
        let probe = makeProbe()
        probe.controller.apply(settings: SelectionBubbleSettings(enabled: true, shortcut: "", readDelay: 0.05))
        XCTAssertTrue(probe.controller.isMonitoring, "开着就该挂上监听")
        XCTAssertEqual(probe.registeredMasks.count, 1)

        probe.controller.apply(settings: SelectionBubbleSettings(enabled: false, shortcut: "", readDelay: 0.05))
        XCTAssertFalse(probe.controller.isMonitoring, "关掉之后监听必须整个拆掉")
        XCTAssertEqual(probe.removals, 1, "拆的那一声要真的落到 removeMonitor 上")

        // 关着的时候连手动那一条也不做事：⌃⌘B 是按同一个开关走的。
        probe.settle { probe.controller.showSelection(at: self.anchor) }
        XCTAssertEqual(probe.reader.reads, 0, "开关关着，快捷键那一支也不许读")
    }

    /// 关掉功能时，reader 那份「哪些进程的开接口请求试过了 / 是我们翻上去的」名单要一起放掉。
    /// 这一条钉的是**接线**（`stop()` 里那一句调用）；名单本身怎么清、为什么要清，
    /// 见 `SelectedTextReaderTests.testTurningTheFeatureOffResetsTheEnableBookkeeping`。
    /// 漏了这一句的坏最难查：用户把功能关一会儿再打开，Chrome 那一类第二次也请不动接口，
    /// 界面上开关明明是开的，日志里连一行错误都没有。
    func testTurningTheFeatureOffReleasesTheAccessibilityRequests() {
        let pid: pid_t = 930_001
        XCTAssertTrue(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXEnhancedUserInterface"))
        XCTAssertFalse(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXEnhancedUserInterface"),
                       "同一个进程的同一个属性只该试一遍")
        let probe = makeProbe()
        probe.controller.apply(settings: SelectionBubbleSettings(enabled: true, shortcut: "", readDelay: 0.05))
        probe.controller.apply(settings: SelectionBubbleSettings(enabled: false, shortcut: "", readDelay: 0.05))
        XCTAssertTrue(AXSelectedTextReader.markAttempt(pid: pid, attribute: "AXEnhancedUserInterface"),
                      "关掉功能没把请求名单放掉：重新打开后再也请不动各家")
    }

    /// 重复 apply 不该把监听挂两遍（偏好页每改一次值都会 apply 一次）。
    func testApplyingTwiceKeepsExactlyOneMonitor() {
        let probe = makeProbe()
        let on = SelectionBubbleSettings(enabled: true, shortcut: "", readDelay: 0.05)
        probe.controller.apply(settings: on)
        probe.controller.apply(settings: on)
        probe.controller.apply(settings: on)
        XCTAssertEqual(probe.registeredMasks.count, 1)
        XCTAssertTrue(probe.controller.isMonitoring)
    }

    /// 没有辅助功能授权时不挂监听。真实现里 MacStroke 启动就过了那道门，
    /// 但这一条要钉住「不挂」这个分支：挂一个收不到事件的监听只是白占一份系统资源，
    /// 而且日志里看起来像功能坏了。
    func testWithoutAccessibilityPermissionNothingIsAttached() {
        let probe = makeProbe()
        probe.controller.isTrustedForGlobalEvents = { false }
        probe.controller.apply(settings: SelectionBubbleSettings(enabled: true, shortcut: "", readDelay: 0.05))
        XCTAssertFalse(probe.controller.isMonitoring)
        XCTAssertTrue(probe.registeredMasks.isEmpty)
    }

    /// 关掉功能时，手上正在等的那次读取要一起作废。
    /// 少了这一条，表现是「把开关一关，正好有一发读回来了，气泡照样弹出来」。
    func testTurningTheSwitchOffInvalidatesTheReadInFlight() {
        let probe = makeProbe()
        probe.controller.apply(settings: SelectionBubbleSettings(enabled: true, shortcut: "", readDelay: 0.05))
        probe.settle {
            probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: [])
            probe.controller.apply(settings: SelectionBubbleSettings(enabled: false, shortcut: "", readDelay: 0.05))
        }
        XCTAssertTrue(probe.shown.isEmpty)
    }

    // MARK: - 快捷键那一支

    /// ⌃⌘B 那一条读的是**整个系统**当前关注的元素，不是某个进程：键盘选字（⌥⇧→ 那一类）
    /// 根本不产生左键事件，只有这一条能叫出气泡。scope 写错就是「按了没反应」。
    func testManualCallReadsTheSystemWideFocusedElement() {
        let probe = makeProbe(result: .text("键盘选的字"))
        probe.settle { probe.controller.showSelection(at: self.anchor) }
        XCTAssertEqual(probe.reader.scopes, [.systemWide])
        XCTAssertEqual(probe.shown, [Shown(text: "键盘选的字", anchor: anchor)])
    }

    /// 按下快捷键时如果上一次读取还在路上，那一次要作废：两次按下去弹两条会叠在同一处。
    func testAManualCallSupersedesTheOneStillInFlight() {
        let probe = makeProbe(result: .text("第二段"))
        probe.settle {
            probe.controller.showSelection(at: CGPoint(x: 100, y: 100))
            probe.controller.showSelection(at: self.anchor)
        }
        XCTAssertEqual(probe.shown.count, 1, "只该留下最后按的那一次")
        XCTAssertEqual(probe.shown.first?.anchor, anchor)
    }

    // MARK: - 坐标要一路带到读取那一头

    /// 松手那一点必须真的传进 reader。
    /// 装机第二轮修的那一档（焦点元素是容器，选区在子树里）靠的是「读鼠标点命中的元素」，
    /// 而 reader 跑在后台线程上 —— 它读回来时指针早就飘走了，坐标只能从事件这一路带进来。
    /// 这一条要是断了（改成传 `nil`、或传成按下点），假件照样答得上来、界面上一切正常，
    /// 只有装机时「邮件里不弹」才发现，而那时已经查不到是哪一手丢的。
    func testTheReleasedPointTravelsIntoTheReader() {
        let probe = makeProbe(result: .text("邮件正文"))
        probe.settle {
            probe.controller.evaluate(drag: dragSample(from: CGPoint(x: 300, y: 460),
                                                       to: self.anchor, dragEvents: 3),
                                      modifiers: [])
        }
        XCTAssertEqual(probe.reader.anchors, [anchor], "传给 reader 的要是松手那一点，不是按下点也不是 nil")
    }

    /// 整条真事件那条路（监听 → handle → 延迟 → 读）也要带上坐标：
    /// 上面那条走的是 `evaluate`，这一条才串到 `cursorLocation` 那一份假光标。
    func testAPlayedDragHandsItsReleasePointToTheReader() {
        let probe = makeProbe(result: .text("拖出来的字"))
        probe.controller.apply(settings: SelectionBubbleSettings(
            enabled: true, shortcut: "", readDelay: 0.05))
        let start = CGPoint(x: 400, y: 500)
        let end = CGPoint(x: 520, y: 500)
        probe.settle { probe.playDrag(from: start, to: end) }
        XCTAssertEqual(probe.reader.anchors, [end], "演出来的这一路，reader 拿到的应该是抬手处")
    }

    /// 快捷键那一条同样把光标位置交给 reader（它自己不探测，但别把这一档写成缺项）。
    func testTheManualCallAlsoCarriesAPoint() {
        let probe = makeProbe(result: .text("手唤的字"))
        probe.settle { probe.controller.showSelection(at: self.anchor) }
        XCTAssertEqual(probe.reader.anchors, [anchor])
    }

    // MARK: - 成功那一行日志要能回答「哪些软件里有效果」

    /// 上一版只有**失败**那几行带 App 名，成功那行是「弹气泡：9 个字符，位置 …」。
    /// 于是装机时问「现在什么软件里才有效果」，日志答不上来 —— 只能靠用户自己记住刚才在哪个 App 里划的。
    /// 这一条钉住成功行里的三样：字符数、是谁、靠哪一手读到的。
    func testTheSuccessLineNamesTheAppAndTheAnsweringSource() {
        let line = SelectionBubbleController.successLogLine(
            text: "划词气泡", subject: "com.apple.mail pid=48317",
            answeredFrom: .atPoint(48317, CGPoint(x: 640, y: 400)))
        XCTAssertTrue(line.contains("读到了"), "成功行要有自己的关键词，装机才 grep 得出来：\(line)")
        XCTAssertTrue(line.contains("com.apple.mail"), "不带 App 名就没法按 App 统计：\(line)")
        XCTAssertTrue(line.contains("pid=48317"))
        XCTAssertTrue(line.contains(AXSelectedTextReader.Scope.atPoint(1, .zero).logLabel),
                      "要说清是哪一手答上来的：\(line)")
        XCTAssertEqual(AXSelectedTextReader.Scope.atPoint(1, .zero).logLabel,
                       AXSelectedTextReader.Scope.atPoint(48317, CGPoint(x: 1, y: 1)).logLabel,
                       "来源说法不该把坐标拼进去，装机统计要的是那一档的名字")
    }

    /// 假件没记来源时不能整行丢掉 —— 「来源未记」比缺一行好查。
    func testTheSuccessLineSurvivesAnUnrecordedSource() {
        let line = SelectionBubbleController.successLogLine(text: "ab", subject: "com.x pid=1",
                                                            answeredFrom: nil)
        XCTAssertTrue(line.contains("来源未记"), "缺来源要留下痕迹：\(line)")
        XCTAssertTrue(line.contains("2 个字符"))
    }

    // MARK: - 触发方式两条各关各的

    /// 「划完字自动弹出」自己关掉时，那三样左键的全局监听要**整个拆掉**，理由和总开关那一条
    /// 是同一句：留着一份收得到事件、却永远什么都不做的全局监听，就是白占系统资源，而且在
    /// 日志里看起来像功能坏了。快捷键那一路不吃这个监听 —— 所以拆完之后 ⌃⌘B 照样读、照样弹。
    func testTurningAutoPopOffTakesOnlyTheMouseButtonMonitorDown() {
        let probe = makeProbe(result: .text("手唤的字"))
        let both = SelectionBubbleSettings(enabled: true,
                                           shortcut: StorageDefaults.selectionPopupShortcut,
                                           readDelay: 0.05)
        probe.controller.apply(settings: both)
        XCTAssertEqual(probe.registeredMasks.count, 1)

        probe.controller.apply(settings: SelectionBubbleSettings(
            enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
            readDelay: 0.05, autoPop: false))
        XCTAssertFalse(probe.controller.isMonitoring, "自动弹关掉后左键监听要没影")
        XCTAssertEqual(probe.removals, 1, "拆的那一声要真的落到 removeMonitor 上")

        // 再来一次 apply 不该重复拆（偏好页每改一个值都会 apply 一次，重复拆会刷日志）。
        probe.controller.apply(settings: SelectionBubbleSettings(
            enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
            readDelay: 0.05, autoPop: false))
        XCTAssertEqual(probe.removals, 1, "已经拆过了不许再拆一次")

        probe.settle { probe.controller.showSelection(at: self.anchor) }
        XCTAssertEqual(probe.reader.reads, 1, "拆掉鼠标监听不许把快捷键那一路一起弄哑")
        XCTAssertEqual(probe.shown, [Shown(text: "手唤的字", anchor: anchor)])
    }

    /// 反方向：只关「手动快捷键唤出」时左键监听必须还在 —— 它只服务自动弹那一路。
    func testTurningTheShortcutOffLeavesTheMouseButtonMonitorAlone() {
        let probe = makeProbe()
        probe.controller.apply(settings: SelectionBubbleSettings(
            enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
            readDelay: 0.05, autoPop: true, shortcutEnabled: false))
        XCTAssertTrue(probe.controller.isMonitoring)
        XCTAssertEqual(probe.removals, 0)
    }

    /// 四格全关 = 读上来的字没地方摆。这时候**两条路都不许读**：白往别人进程里发一趟
    /// 无障碍调用不说，日志里还会留下一句像成功其实没弹的话。
    func testNoCellsStopsBothTriggerPathsFromEvenReading() {
        let probe = makeProbe(result: .text("没人要的"))
        probe.controller.apply(settings: SelectionBubbleSettings(
            enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
            readDelay: 0.05, actions: []))
        probe.settle {
            probe.controller.evaluate(drag: armedDrag(end: self.anchor), modifiers: [])
            probe.controller.showSelection(at: self.anchor)
        }
        XCTAssertEqual(probe.reader.reads, 0, "没格子就不该去读")
        XCTAssertTrue(probe.shown.isEmpty)
    }

    // MARK: - 点上格子之后做的事（搜索走哪一家）

    /// 把「开浏览器」和「写粘贴板」两手换成记录用的假件，并记成**一条序列** ——
    /// 光各记一笔看不出先后，而 AI 那几家要的正是「先放进去、再开页面」。
    /// 真值那两句在 `SelectionBubbleController` 的默认实现里，测试入口压根不带它们，
    /// 所以用例忘了换的最坏结果是「这一手没上场」，不会是「跑单测把用户刚复制的东西顶掉了」。
    ///
    /// 记的那个小本子必须是**引用类型**：两个闭包捕获的是同一个对象，用例事后读得到全部记录。
    /// （第一版这里返回的是 `(events, urls)` 两个值类型 —— 闭包改的是函数里那份局部量，
    /// 元组在 return 那一句就拷贝走了，用例永远拿到空数组，六条用例一起「红得像没接线」。）
    private final class Sink {
        var events: [String] = []
        var urls: [URL] = []
        var written: [String] = []
        /// 粘贴板上此刻那一句。默认**就是我们最后写进去的那句**（这是真跑起来绝大多数时候的样子），
        /// 用例想演「用户中途又复制了别的」就把它改成别的内容。
        var pasteboardContent: String?
        /// 「等多久再贴」那一条排下来的活儿。默认**不自动放行**：延时本身不是被测对象，
        /// 而「到点之前偏好被改了」「到点时粘贴板换人了」这两档只有把闭包攥在手里才演得出来。
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

        /// 放行所有已排的活儿（相当于把那 1.2 秒过完）。
        func fireScheduled() {
            let pending = scheduled
            scheduled = []
            for (_, work) in pending { work() }
        }
    }

    private func actionSinks(_ probe: Probe) -> Sink {
        let sink = Sink()
        probe.controller.openURL = { [weak sink] url in
            sink?.events.append("open")
            sink?.urls.append(url)
        }
        probe.controller.pasteboardWrite = { [weak sink] text in
            sink?.events.append("write:\(text)")
            sink?.written.append(text)
        }
        // 「自动贴那一次 ⌘V」的三条接缝一并换成记账的：贴 = 序列里多一笔 paste，
        // 排期 = 记在这儿等用例放行，读粘贴板 = 默认回我们刚写的那句（见 Sink 那句注释）。
        probe.controller.postPasteKeys = { [weak sink] in
            sink?.events.append("paste")
            return true
        }
        probe.controller.pasteboardString = { [weak sink] in
            sink?.pasteboardContent ?? sink?.written.last
        }
        probe.controller.pasteScheduler = { [weak sink] delay, work in
            // 排期本身也记一笔：不记就演不出「排在开页之前」那种坏 —— 闭包攥在手里等放行，
            // 序列里看不见它是什么时候排的（M146 那一条变异就是这么逃掉的）。
            sink?.events.append("schedule")
            sink?.scheduled.append((delay, work))
        }
        return sink
    }

    /// 搜索引擎那六家：开的是**偏好的那一家**，一次都不写粘贴板。
    /// 这一条是「搜索写成配置」的全部意义：3.1.x 时代这里写死 Google，
    /// 改了偏好还开 Google，就是界面骗人。
    func testTheSearchCellOpensTheEnginePickedInThePreferences() {
        let probe = makeProbe()
        var settings = probe.controller.settings
        settings.searchEngine = .bing
        probe.controller.settings = settings
        let sink = actionSinks(probe)

        probe.controller.perform("search", on: "划词")
        XCTAssertEqual(sink.urls.map(\.absoluteString), ["https://www.bing.com/search?q=%E5%88%92%E8%AF%8D"])
        XCTAssertEqual(sink.events, ["open"], "搜索页用不着粘贴板，多写一次只是弄脏用户刚复制的东西")
    }

    /// 换一家就得换一页：六家里逐条点一遍，防的是「下拉里点了、控制器还拿默认那一条」。
    /// 判据取「开出去的 URL 就是那一家模板换字之后的样子」，整串比 —— 只比域名的话，
    /// 有人把模板串到别人身上（百度拼成搜狗）就漏过去了。
    func testEverySearchEngineRowOpensItsOwnPage() {
        for engine in SelectionBubbleSearchEngine.searchEngines {
            let probe = makeProbe()
            probe.controller.settings = SelectionBubbleSettings(
                enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
                readDelay: 0.05, searchEngine: engine)
            let sink = actionSinks(probe)
            probe.controller.perform("search", on: "字")
            XCTAssertEqual(sink.urls.map(\.absoluteString),
                           [engine.template.replacingOccurrences(
                                of: SelectionBubbleLinks.queryPlaceholder,
                                with: SelectionBubbleLinks.encoded("字"))],
                           "\(engine.rawValue) 点开的是别家")
            XCTAssertEqual(sink.events, ["open"], "\(engine.rawValue) 不该动粘贴板")
        }
    }

    /// 网页 AI 那八家：**先写粘贴板、再开页面**，顺序不许反。
    /// 反了会怎样：页面已经在前台了才把字放进去，用户切回窗口时那一格还是空的，
    /// 而他刚才是照着「打开后 ⌘V」的预期点的 —— 这一条只能靠序列看出来，两句各记一笔看不出来。
    /// 传进来的字是气泡上那段**已经裁过**的（裁首尾在 `SelectionTriggerTests` 里钉），
    /// 这里不再测裁，只测次序。
    func testAnAIEnginePutsTheTextOnThePasteboardBeforeOpening() {
        for engine in SelectionBubbleSearchEngine.aiEngines {
            let probe = makeProbe()
            probe.controller.settings = SelectionBubbleSettings(
                enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
                readDelay: 0.05, searchEngine: engine)
            let sink = actionSinks(probe)
            probe.controller.perform("search", on: "要问的话")
            XCTAssertEqual(sink.events.first, "write:要问的话",
                           "\(engine.rawValue)：没先放粘贴板，页面打开后没地方贴")
            XCTAssertEqual(sink.events.count, 2)
            XCTAssertEqual(sink.events.last, "open")
            XCTAssertEqual(sink.urls.count, 1)
        }
    }

    /// 自定义那一栏真被吃到：填了带占位符的模板 → 开那一页且不写粘贴板；
    /// 填得不像个网址 → 退回默认那一家（Google），而不是「点了放大镜什么也不开」。
    func testTheCustomTemplateIsHonouredAndFallsBackWhenBroken() {
        let probe = makeProbe()
        probe.controller.settings = SelectionBubbleSettings(
            enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
            readDelay: 0.05, searchEngine: .custom,
            searchCustomURL: "https://wiki.corp/?search={query}")
        var sink = actionSinks(probe)
        probe.controller.perform("search", on: "字")
        XCTAssertEqual(sink.urls.map(\.absoluteString), ["https://wiki.corp/?search=%E5%AD%97"])
        XCTAssertEqual(sink.events, ["open"])

        let broken = makeProbe()
        broken.controller.settings = SelectionBubbleSettings(
            enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
            readDelay: 0.05, searchEngine: .custom, searchCustomURL: "填坏了")
        sink = actionSinks(broken)
        broken.controller.perform("search", on: "字")
        XCTAssertEqual(sink.urls.map(\.absoluteString), ["https://www.google.com/search?q=%E5%AD%97"],
                       "自定义写坏了应当退回默认那一家，而不是这一格整个没反应")
    }

    // MARK: - 搜索那一句日志怎么写（装机清单唯一的凭据）

    /// 「拼没拼进 URL」和「动没动粘贴板」是**两件独立的事**，四档都要有各自的说法。
    /// 上一版这里按 `copiesTextFirst` 二选一，对 chatgpt / copilot / perplexity 是说反的：
    /// 那三家模板带占位符、`kind == .ai` 又要求复制，日志却写「这一页不吃 URL 预填」。
    func testTheSearchLogSeparatesPrefillFromPasteboard() {
        let prefillOnly = SelectionBubbleController.searchLogLine(
            engine: .bing, template: "https://www.bing.com/search?q={query}", copiesTextFirst: false)
        XCTAssertTrue(prefillOnly.contains("查询拼进 URL，不碰粘贴板"), " Bing：\(prefillOnly)")

        let prefillAndCopy = SelectionBubbleController.searchLogLine(
            engine: .chatgpt, template: "https://chatgpt.com/?q={query}", copiesTextFirst: true)
        XCTAssertTrue(prefillAndCopy.contains("查询拼进 URL"),
                      "ChatGPT 的模板带占位符，日志不能说不吃预填：\(prefillAndCopy)")
        XCTAssertTrue(prefillAndCopy.contains("粘贴板"),
                      "这一家确实写了粘贴板：\(prefillAndCopy)")

        let openOnly = SelectionBubbleController.searchLogLine(
            engine: .doubao, template: "https://www.doubao.com/chat/", copiesTextFirst: true)
        XCTAssertTrue(openOnly.contains("不吃 URL 预填"), "豆包：\(openOnly)")
        XCTAssertTrue(openOnly.contains("粘贴板"), "豆包：\(openOnly)")

        let neither = SelectionBubbleController.searchLogLine(
            engine: .custom, template: "https://example.com/", copiesTextFirst: false)
        XCTAssertTrue(neither.contains("只打开这一页，不碰粘贴板"), "兜住第四档，别让它悄悄落进别的说法：\(neither)")
    }

    /// **箭头后面必须是实际用的那条模板**。选了自定义、那一栏还空着（或写得不像网址）时，
    /// 前半句 `custom` 说的是「偏好选的」，真正打开的是退回那一家 —— 上一版只印前半句，
    /// 装机时按 `搜索走 custom` 去核对就会核出个假阳性（清单第 31 步判的就是这一格）。
    func testTheSearchLogShowsTheTemplateActuallyUsedWhenCustomFallsBack() {
        let google = SelectionBubbleSearchEngine.google.resolvedTemplate(customURL: "用不上")
        XCTAssertTrue(google.template.contains("google.com"), "前提：退回的是 Google 那条")
        let line = SelectionBubbleController.searchLogLine(engine: .custom,
                                                           template: google.template,
                                                           copiesTextFirst: google.copiesTextFirst)
        XCTAssertTrue(line.hasPrefix("[SelectionBubble] 搜索走 custom"),
                      "前半句要说清偏好里选的是自定义（清单靠这句 grep）：\(line)")
        XCTAssertTrue(line.contains(google.template),
                      "箭头后面得是实际开的那条，不然这句日志在骗人：\(line)")
    }

    /// 自定义真填对时，日志里的模板就是用户写的那一条，而不是名单里任何一家。
    func testTheSearchLogCarriesTheCustomTemplateWhenItIsUsable() {
        let line = SelectionBubbleController.searchLogLine(
            engine: .custom, template: "https://wiki.corp/?search={query}", copiesTextFirst: false)
        XCTAssertTrue(line.contains("https://wiki.corp/?search={query}"), line)
        XCTAssertTrue(line.contains("查询拼进 URL，不碰粘贴板"), line)
    }

    /// 表里每一家都要能从这一句读出来：模板原样出现在句子里，两件事的说法和行为一致。
    /// 逐家过一遍而不是抽两家 —— 十四家里就一家说反也是错的，而装机时只有那一家会露馅。
    func testEveryEngineRowDescribesItselfTheWayTheControllerActs() {
        for engine in SelectionBubbleSearchEngine.allCases where engine != .custom {
            let target = engine.resolvedTemplate(customURL: "")
            let line = SelectionBubbleController.searchLogLine(engine: engine,
                                                               template: target.template,
                                                               copiesTextFirst: target.copiesTextFirst)
            XCTAssertTrue(line.hasPrefix("[SelectionBubble] 搜索走 \(engine.rawValue) → "),
                          "\(engine.rawValue)：前半句没写选的是哪家 —— \(line)")
            XCTAssertTrue(line.contains(target.template),
                          "\(engine.rawValue)：没写实际用的那条模板 —— \(line)")
            XCTAssertTrue(line.contains(SelectionBubbleLinks.prefillsQuery(target.template)
                                            ? "查询拼进 URL" : "不吃 URL 预填"),
                          "\(engine.rawValue)：预填与否说反了 —— \(line)")
            XCTAssertTrue(line.contains(target.copiesTextFirst ? "粘贴板" : "不碰粘贴板"),
                          "\(engine.rawValue)：动没动粘贴板说反了 —— \(line)")
        }
    }

    /// 选哪家都**只管搜索那一格**：翻译那一格始终是网页翻译页。
    /// 这条挡的是「把 engine 那份模板串到 translate 上」—— 表现是搜中文能译、选了百度就译不出。
    func testTranslateIgnoresTheChosenEngine() {
        let probe = makeProbe()
        probe.controller.settings = SelectionBubbleSettings(
            enabled: true, shortcut: StorageDefaults.selectionPopupShortcut,
            readDelay: 0.05, searchEngine: .baidu)
        let sink = actionSinks(probe)
        probe.controller.perform("translate", on: "字")
        XCTAssertTrue(sink.urls.first?.absoluteString.hasPrefix("https://translate.google.com/") ?? false,
                      "翻译那一格被搜索引擎带跑了：\(sink.urls.first?.absoluteString ?? "nil")")
        XCTAssertEqual(sink.events, ["open"], "翻译页也不该动粘贴板")
    }

    /// 复制那一格也走同一个接缝（**不是**真粘贴板）：它是四格里唯一该写粘贴板的，
    /// 也是唯一不该开任何东西的。
    func testTheCopyCellWritesThroughTheSeamAndOpensNothing() {
        let probe = makeProbe()
        let sink = actionSinks(probe)
        probe.controller.perform("copy", on: "要复制的话")
        XCTAssertEqual(sink.events, ["write:要复制的话"])
        XCTAssertTrue(sink.urls.isEmpty)
    }

    // MARK: - 打开之后自动贴那一次 ⌘V

    /// 摆一个「选了豆包（不吃 URL 预填）+ 自动贴开着」的控制器。
    /// 豆包当默认样板是有讲究的：它 `copiesTextFirst` 为真，是这一手**唯一**该上场的形状。
    private func makeAutoPasteProbe(_ engine: SelectionBubbleSearchEngine = .doubao,
                                    autoPaste: Bool = true,
                                    shortcut: String = StorageDefaults.selectionPopupShortcut)
        -> (Probe, Sink) {
        let probe = makeProbe()
        probe.controller.settings = SelectionBubbleSettings(
            enabled: true, shortcut: shortcut, readDelay: 0.05,
            searchEngine: engine, autoPasteAfterOpen: autoPaste)
        return (probe, actionSinks(probe))
    }

    /// 次序：**先开页，再排贴**。反了（贴排在开之前）就是往「此刻前台那个窗口」打一次 ⌘V，
    /// 而那个窗口跟这一页没关系。这条只能靠序列看出来：贴那一手是排在延时里的，
    /// 所以点完格子那一刻序列必须停在 `[write, open, schedule]`，放行之后才多出一笔 paste。
    func testTheAutoPasteIsScheduledAfterThePageOpens() {
        let (probe, sink) = makeAutoPasteProbe()
        probe.controller.perform("search", on: "要问的话")
        XCTAssertEqual(sink.events, ["write:要问的话", "open", "schedule"],
                       "点下去那一刻不该已经贴出去，也不该在开页之前就把 ⌘V 排下去：\(sink.events)")
        XCTAssertEqual(sink.scheduled.map(\.delay), [SelectionBubbleSettings.autoPasteDelay],
                       "排下来的延时不是模块那一个常数，界面/消费端就要各写一个数了")
        sink.fireScheduled()
        XCTAssertEqual(sink.events, ["write:要问的话", "open", "schedule", "paste"])
    }

    /// 真能把字拼进网址的那六家**压根不排这一手**：它们没写粘贴板，
    /// 这时候补一次 ⌘V 贴出去的是用户本来就自己复制着的东西 —— 那不是贴心，是往他没准备的框里填别人的内容。
    func testTheEnginesThatPrefillTheURLNeverScheduleAPaste() {
        for engine in SelectionBubbleSearchEngine.searchEngines {
            let (probe, sink) = makeAutoPasteProbe(engine)
            probe.controller.perform("search", on: "字")
            XCTAssertTrue(sink.scheduled.isEmpty, "\(engine.rawValue)：这一家没有「我们刚复制的那句」可贴")
            sink.fireScheduled()
            XCTAssertFalse(sink.events.contains("paste"), "\(engine.rawValue)：贴出去了")
        }
    }

    /// 自定义那一档**看模板**：不带 `{query}` 就有这一手，带了就没有。
    /// 这一条钉的是「自动贴跟着 copiesTextFirst 走，而不是跟着『这一家是谁』走」——
    /// 名单和开关各判一遍，就会出现「用户自己写的网址在界面上归不了类，行为猜不准」。
    func testTheAutoPasteFollowsTheTemplateNotTheBrand() {
        var settings = SelectionBubbleSettings(enabled: true,
                                              shortcut: StorageDefaults.selectionPopupShortcut,
                                              readDelay: 0.05, searchEngine: .custom,
                                              searchCustomURL: "https://intranet/wiki/",
                                              autoPasteAfterOpen: true)
        XCTAssertTrue(settings.searchAutoPaste, "自定义不带占位符 = 得靠 ⌘V，这一手该上场")
        settings.searchCustomURL = "https://intranet/wiki?s={query}"
        XCTAssertFalse(settings.searchAutoPaste, "自定义带了占位符 = URL 已经吃进去了，不该再多按一次键")

        let (probe, sink) = makeAutoPasteProbe()
        probe.controller.settings = settings
        probe.controller.perform("search", on: "字")
        XCTAssertTrue(sink.scheduled.isEmpty, "界面选了带占位符的自定义，控制器却还是排了一次贴")
    }

    /// 到点时粘贴板已经不是那句 → **什么都不投**。
    /// 这一档必须演出来而不是写在注释里：用户在这 1.2 秒里又复制了别的东西，
    /// 贴进去的就是他的私有内容，而这一切在他眼里只是「我点了个放大镜」。
    func testAPasteboardThatChangedUnderneathCancelsThePaste() {
        let (probe, sink) = makeAutoPasteProbe()
        probe.controller.perform("search", on: "要问的话")
        sink.pasteboardContent = "刚别处复制的一句话"
        sink.fireScheduled()
        XCTAssertFalse(sink.events.contains("paste"), "粘贴板都换人了还贴：\(sink.events)")
    }

    /// 到点时前台是我们自己的窗口 → 不投。否则那一下 ⌘V 打进偏好页那个文本框，
    /// 用户看到的是「搜索完粘贴板里的字跑进了设置窗口」。
    /// 两道闸**同时不过**时报的是粘贴板那一档（贴错内容比贴错窗口更坏），
    /// 这一句在 `pasteGate` 的用例里也钉着，这里钉的是控制器真的照那一句走。
    func testWeDoNotPasteIntoOurOwnWindow() {
        let (probe, sink) = makeAutoPasteProbe()
        probe.controller.ourBundleID = "com.example.other"   // makeProbe 的默认前台就是这一家
        probe.controller.perform("search", on: "要问的话")
        sink.fireScheduled()
        XCTAssertFalse(sink.events.contains("paste"), "前台是我们自己还投按键")

        let both = makeAutoPasteProbe()
        let bothSink = both.1
        both.0.controller.ourBundleID = "com.example.other"
        both.0.controller.perform("search", on: "要问的话")
        bothSink.pasteboardContent = "别的东西"
        bothSink.fireScheduled()
        XCTAssertFalse(bothSink.events.contains("paste"))
    }

    /// 那 1.2 秒里把开关关掉 / 把引擎换成一家能预填的 → 作废。
    /// 判据取「到点那一刻的快照」而不是「点下去那一刻的」：否则关掉之后还会贴出最后一次的尾巴，
    /// 而用户在界面上看到的已经是关了。
    func testChangingThePreferencesInTheMeantimeCancelsThePaste() {
        let (probe, sink) = makeAutoPasteProbe()
        probe.controller.perform("search", on: "要问的话")
        XCTAssertEqual(sink.scheduled.count, 1)
        var off = probe.controller.settings
        off.autoPasteAfterOpen = false
        probe.controller.settings = off
        sink.fireScheduled()
        XCTAssertFalse(sink.events.contains("paste"), "开关已经关了，到点那一下不该再投")

        let swapped = makeAutoPasteProbe()
        let swappedSink = swapped.1
        swapped.0.controller.perform("search", on: "字")
        var toPrefill = swapped.0.controller.settings
        toPrefill.searchEngine = .bing
        swapped.0.controller.settings = toPrefill
        swappedSink.fireScheduled()
        XCTAssertFalse(swappedSink.events.contains("paste"))
    }

    /// 快捷键录成单纯 ⌘V 时**压根不排这一手**（拆环，同 ⌘C 那一处）：
    /// 我们投出去的那一下就是不带别修饰键的 ⌘V，它会进全局事件流、被那只监听听见，
    /// 于是「开页面 → 自动 ⌘V → 监听命中 → 又读选区 → 又开页面」。
    /// 加冷却只把环变慢，所以这里是不上场。
    func testAPlainCommandVShortcutNeverSchedulesThePaste() {
        let plainV = "keyCode=9, flags=1048576"
        XCTAssertTrue(SelectionBubbleSettings.isPlainCommandV(plainV))
        XCTAssertFalse(SelectionBubbleSettings.isPlainCommandV("keyCode=9, flags=1310720"),
                       "⌃⌘V 不该被误判成单纯 ⌘V（默认那组键就是这么配的）")
        XCTAssertFalse(SelectionBubbleSettings.isPlainCommandV(StorageDefaults.selectionPopupShortcut),
                       "默认的 ⌃⌘B 绝不能被这一条挡住，那等于新开关默认自锁")

        let (probe, sink) = makeAutoPasteProbe(shortcut: plainV)
        probe.controller.perform("search", on: "要问的话")
        XCTAssertTrue(sink.scheduled.isEmpty, "配成单纯 ⌘V 还排了这一手，环就回来了")
    }

    /// 「复制」那一格不许顺带排贴：它写完粘贴板就结束了，没有任何页面被打开。
    /// 这一条挡的是「把 copiesTextFirst 那一份判定漏接到 write 那一支上」——
    /// 表现是复制完过一秒，焦点所在的窗口里凭空多出一段字。
    func testTheCopyCellDoesNotScheduleAnAutoPaste() {
        let (probe, sink) = makeAutoPasteProbe()
        probe.controller.perform("copy", on: "只要复制")
        XCTAssertEqual(sink.events, ["write:只要复制"])
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    /// 三档答复各说清一件事，尤其那两条「没做」要能分出是**闸在做对的事**还是这一手压根没上场。
    /// 抽成纯函数的理由同 `searchLogLine`：`NSLog` 在用例里拿不到。
    func testTheAutoPasteLogNamesTheReason() {
        let injected = SelectionBubbleController.autoPasteLogLine(gate: .inject, text: "八个字符的字")
        XCTAssertTrue(injected.contains("投一次 ⌘V"), injected)

        let changed = SelectionBubbleController.autoPasteLogLine(gate: .pasteboardChanged, text: "字")
        XCTAssertTrue(changed.contains("已经不是"), changed)
        XCTAssertFalse(changed.contains("前台是我们自己"), "两档说成一句就分不出锅了：\(changed)")

        let ours = SelectionBubbleController.autoPasteLogLine(gate: .frontIsOurs, text: "字")
        XCTAssertTrue(ours.contains("前台是我们自己"), ours)
    }
}
