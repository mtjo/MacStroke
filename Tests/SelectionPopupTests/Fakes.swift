//
//  Fakes.swift
//  SelectionPopupTests
//
//  这一整套测试的铁律：**不往真粘贴板写东西、不开浏览器、不念出声、不往别的进程的元素上写属性、
//  不动系统那张全局监听表**。
//  开发机是常驻在用的机器，念一段话或弹一次浏览器就是把人从手头的事里拽出来。所以：
//  - 读选中文字换成 `FakeReader`（真实现只在一个 smoke 用例里跑，且不断言内容）
//  - 上屏换成记录用的 `presenter` 闭包（真窗口在 `swift test` 里不该开）
//  - 前台 App、光标位置、挂监听三样换成假值 —— 这三样都是「这台机器此刻恰好是什么就是什么」，
//    拿它们当判据会做出一个今天绿、明天红的用例
//  留真的只有三样：判定函数、布局算式、无障碍错误码的分类。
//

import AppKit
import CoreGraphics
import Storage
import XCTest
@testable import SelectionPopup

/// 假读取实现：固定给一个结果，顺便记被读了几次、以哪种 scope 读的。
final class FakeReader: SelectionTextReading {
    var result: SelectedTextResult
    /// 每次读取用的 scope，用例用它核对「自动弹走 application(pid)、快捷键那条走 systemWide」。
    var scopes: [AXSelectedTextReader.Scope] = []
    /// 每次读取拿到的**松手点坐标**。这一档必须记：容器那一手（读鼠标点命中的元素）全靠它，
    /// 控制器要是把坐标传丢（写 `nil` 或传成按下点），假件照样答得上来、界面上一切正常，
    /// 只有装机时「邮件里不弹」才发现 —— 而真 AX 在 `swift test` 里演不出来。
    var anchors: [CGPoint?] = []
    /// 每一次读取时，控制器**有没有把「代按 ⌘C」那一手递进来**（第三个参数是不是 nil）。
    /// 为什么这一档非记不可：开关关掉、总开关关掉、四格全关、快捷键正好录成单纯 ⌘C ——
    /// 这四种情形下界面上全都一模一样（读不到就不弹），只有「有没有出手」这一格能把它们分开。
    /// 而真出手要另一个 App 在前台真选中字，`swift test` 里演不出来，只能验到「递没递进来」为止，
    /// 递进来之后的事归 `SelectionCopyReaderTests` 与装机日志。
    var copyHands: [Bool] = []
    /// 这一趟从哪一档来源读到（真实现记在自己身上，假件由用例摆好）。
    /// 只进成功那行日志，用例靠 `SelectionBubbleController.successLogLine` 验它写没写进去。
    var answeredFrom: AXSelectedTextReader.Scope?
    var reads = 0
    /// 读的那一瞬间要做的事：用例用它模拟「读期间人已经切走了」。
    var onRead: (() -> Void)?

    init(result: SelectedTextResult = .nothingSelected) {
        self.result = result
    }

    func read() -> SelectedTextResult {
        reads += 1
        onRead?()
        return result
    }
}

/// 一次上屏的记录。
struct Shown: Equatable {
    let text: String
    let anchor: CGPoint
}

/// 攒一次拖动：按下 → 拖 `dragEvents` 笔 → 松开。坐标全用整数，免得断言里出现浮点尾巴。
func dragSample(from start: CGPoint, to end: CGPoint, dragEvents: Int = 1) -> DragSample {
    DragSample(start: start, end: end, dragEvents: dragEvents)
}

/// 一条明确算「划到了」的拖动：往右拖过 40 点、中间三笔拖动。
func armedDrag(end: CGPoint = CGPoint(x: 500, y: 400)) -> DragSample {
    dragSample(from: CGPoint(x: end.x - 40, y: end.y), to: end, dragEvents: 3)
}

/// 一个用例的全家桶：控制器 + 假读取 + 假监听 + 假光标 + 上屏记录。
/// 引用类型 —— `presenter` 那一手是在主队列的块里执行的，值类型改了半天外面看不见。
final class Probe {
    let controller: SelectionBubbleController
    let reader: FakeReader
    var shown: [Shown] = []

    /// 假注册拿到的回调。用例靠它演一条「按下 → 拖三笔 → 松手」，
    /// 不用真事件（真事件要辅助功能授权加另一个 App 在前台，测试进程两样都没有）。
    private(set) var handler: ((NSEvent) -> Void)?
    /// 每次挂监听收到的事件掩码，取证用它核对 M38 那一条真的传给了系统。
    private(set) var registeredMasks: [NSEvent.EventTypeMask] = []
    private(set) var removals = 0
    /// 假的那条「前台换人」通知：用例调它，就等于工作区真换了进程。
    private(set) var appSwitchFired: (() -> Void)?
    private(set) var appSwitchRemovals = 0
    /// 脚本化的光标：`play` 挪它，控制器读它。
    var cursor = CGPoint(x: 500, y: 400)

    init(result: SelectedTextResult,
         frontmost: @escaping () -> FrontApp?,
         isAppAllowed: @escaping (String) -> Bool,
         isSelfApp: @escaping (FrontApp) -> Bool,
         enabled: Bool,
         readDelay: TimeInterval,
         copyFallback: Bool = true) {
        let fake = FakeReader(result: result)
        // 先用局部量造控制器：这一步的闭包只许捕获 `fake`，捕获 self 要等存储属性全落定。
        let made = SelectionBubbleController(
            readerFactory: { scope, anchor, copy in
                fake.scopes.append(scope)
                fake.anchors.append(anchor)
                fake.copyHands.append(copy != nil)
                return fake
            },
            frontmostApp: frontmost,
            isAppAllowed: isAppAllowed,
            settings: SelectionBubbleSettings(enabled: enabled,
                                              shortcut: StorageDefaults.selectionPopupShortcut,
                                              readDelay: readDelay,
                                              copyFallbackEnabled: copyFallback))
        // 「前台是不是我们自己」在测试进程里恒真恒假都说明不了问题，换成用例传进来的答案。
        made.isSelfApp = isSelfApp
        reader = fake
        controller = made
        // self 到这行才算初始化完，下面几个闭包才允许捕获它。
        made.presenter = { [weak self] text, anchor in
            self?.shown.append(Shown(text: text, anchor: anchor))
        }
        made.cursorLocation = { [weak self] in self?.cursor ?? .zero }
        made.isTrustedForGlobalEvents = { true }
        made.monitorRegistration = { [weak self] mask, handler in
            guard let self else { return nil }
            self.registeredMasks.append(mask)
            self.handler = handler
            return "fake-monitor-\(self.registeredMasks.count)"
        }
        made.monitorRemoval = { [weak self] _ in self?.removals += 1 }
        made.appSwitchRegistration = { [weak self] fire in
            self?.appSwitchFired = fire
            return "fake-app-switch"
        }
        made.appSwitchRemoval = { [weak self] _ in self?.appSwitchRemovals += 1 }
    }

    /// 喂完事件之后空转 0.4s，让「延迟 → 后台读 → 回主线程抛上屏」这一串走完。
    /// 用例里的 readDelay 都设在下限 50ms，0.4s 足够；走不到就是链路停住了，让用例红掉。
    func settle(_ block: () -> Void) {
        let expectation = XCTestExpectation(description: "划词链路走完")
        block()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { expectation.fulfill() }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed,
                       "等不到主队列上的那一句，链路停住了")
    }

    /// 只空转，不发事件：用来等「该什么都没发生」的那一档。
    func idle() { settle {} }

    /// 挪光标并演一笔事件。位置只由 `cursor` 决定 —— 控制器读的就是它，
    /// 合成事件自带的 location 在这条链路上用不上（全局监听的事件没有窗口）。
    func play(_ type: NSEvent.EventType, at point: CGPoint? = nil,
              modifiers: NSEvent.ModifierFlags = []) {
        if let point { cursor = point }
        let event = NSEvent.mouseEvent(with: type, location: cursor,
                                       modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)
        guard let event, let handler else {
            XCTFail("监听没挂上，演不了事件")
            return
        }
        handler(event)
    }

    /// 演一条完整拖动：按下 → 每 `step` 点一笔 → 松手。
    func playDrag(from start: CGPoint, to end: CGPoint, steps: Int = 3,
                  modifiers: NSEvent.ModifierFlags = []) {
        play(.leftMouseDown, at: start)
        let dx = (end.x - start.x) / CGFloat(max(1, steps))
        let dy = (end.y - start.y) / CGFloat(max(1, steps))
        for step in 1 ... max(1, steps) {
            play(.leftMouseDragged, at: CGPoint(x: start.x + dx * CGFloat(step),
                                                y: start.y + dy * CGFloat(step)))
        }
        play(.leftMouseUp, at: end, modifiers: modifiers)
    }
}

/// 造一个不碰真事的探测器：假读取、假前台、假上屏，一个用例一个（单例那份状态会串味）。
func makeProbe(result: SelectedTextResult = .text("hello"),
               frontmost: FrontApp? = FrontApp(bundleID: "com.example.other", pid: 4321),
               isAppAllowed: @escaping (String) -> Bool = { _ in true },
               isSelfApp: @escaping (FrontApp) -> Bool = { _ in false },
               enabled: Bool = true,
               readDelay: TimeInterval = 0.05,
               copyFallback: Bool = true) -> Probe {
    Probe(result: result,
          frontmost: { frontmost },
          isAppAllowed: isAppAllowed,
          isSelfApp: isSelfApp,
          enabled: enabled,
          readDelay: readDelay,
          copyFallback: copyFallback)
}

/// 一份能在用例中途换掉的前台（验「读期间切了 App 那次作废」）。
final class MutableFront {
    var app: FrontApp?
    init(_ app: FrontApp?) { self.app = app }
    func current() -> FrontApp? { app }
}
