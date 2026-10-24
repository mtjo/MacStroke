//
//  SelectionTriggerTests.swift
//  SelectionPopupTests
//
//  两个判定：这一次松手算不算划词、读回来的这段文字该不该弹。
//  边界最容易写反的两处都在这里：位移下限记反 = 单击也弹（M33），空值当成有值 = 抛一条空气泡（M34）。
//

import AppKit
import CoreGraphics
import XCTest
@testable import SelectionPopup

final class SelectionTriggerTests: XCTestCase {
    private let end = CGPoint(x: 500, y: 400)

    /// 反向变异 M33：把「必须拖过几笔」那一条删掉，单击就变成划词。
    /// 系统里每一次点东西都是一次单击 —— 这一条写反了就是满屏弹气泡。
    func testASingleClickIsNotASelection() {
        let click = dragSample(from: CGPoint(x: 400, y: 400), to: end, dragEvents: 0)
        // 距离够长（按下和松开不在一处，比如拖动被别处吃掉只收到首尾两笔）也不算：
        // 认的是「中间有没有拖动」，不是「首尾差多远」。
        XCTAssertGreaterThan(click.travel, SelectionBubbleSettings.minimumTravel)
        XCTAssertEqual(SelectionTrigger.decide(drag: click, modifiers: []), .skip(.singleClick))
    }

    /// 拖了但没拖出 6 点：在一段字上抖一下、双击选词、点住不动手抖，都在这一档。
    func testATwitchShorterThanTheMinimumTravelIsNotASelection() {
        let twitch = dragSample(from: CGPoint(x: end.x - 3, y: end.y), to: end, dragEvents: 2)
        XCTAssertEqual(SelectionTrigger.decide(drag: twitch, modifiers: []), .skip(.tooShort))
        // 边界：正好 6 点算划词（判定用的是 `>=`，改成 `>` 就少掉一格整数位移）。
        let exactly = dragSample(from: CGPoint(x: end.x - 6, y: end.y), to: end, dragEvents: 1)
        XCTAssertEqual(SelectionTrigger.decide(drag: exactly, modifiers: []), .arm(anchor: end))
    }

    /// 按住 ⌥/⇧/⌘ 的拖动另有含义（列选、扩展选区、多选），别抢戏。
    /// ⌃ 不在这一档里：那些控件里 ⌃ 拖动没有第二含义，拦它只会少弹 —— 所以这条要单独钉住。
    func testBlockedModifiersSkipButControlDoesNot() {
        for modifier in [NSEvent.ModifierFlags.option, .shift, .command] {
            XCTAssertEqual(SelectionTrigger.decide(drag: armedDrag(), modifiers: modifier),
                           .skip(.modifierHeld), "\(modifier.rawValue) 不该弹")
            // 按下时才有的副位（大/小写、数字键区）不该被误判成修饰键。
            XCTAssertEqual(SelectionTrigger.decide(drag: armedDrag(),
                                                   modifiers: modifier.union(.deviceIndependentFlagsMask)),
                           .skip(.modifierHeld))
        }
        XCTAssertEqual(SelectionTrigger.decide(drag: armedDrag(), modifiers: .control), .arm(anchor: end))
        XCTAssertEqual(SelectionTrigger.decide(drag: armedDrag(), modifiers: .capsLock), .arm(anchor: end))
        XCTAssertFalse(SelectionBubbleController.blockedModifiers.contains(.control),
                       "⌃ 不在拦的那三个键里 —— 拦它只会少弹")
    }

    /// 弹在哪：记的是**松手那一瞬**的鼠标点，不是按下的点。
    /// 布局那一头靠它把气泡摆在最后指到的那段字上方，取错端点就摆到起点去了。
    func testArmedOutcomeCarriesTheMouseUpPoint() {
        let start = CGPoint(x: 100, y: 700)
        let drag = dragSample(from: start, to: end, dragEvents: 4)
        XCTAssertEqual(SelectionTrigger.decide(drag: drag, modifiers: []), .arm(anchor: end))
    }

    // MARK: - 读回来的那段文字

    /// 反向变异 M34：把「空串也当读到东西」写回去，就是往屏幕上抛一条四格全无事干的空气泡。
    /// 空、纯空白、只有换行三种都要挡住 —— 拖过一段全是空格行距的区域是真会发生的。
    func testNothingSelectedAndWhitespaceShowNothing() {
        XCTAssertEqual(SelectionTrigger.decide(text: .nothingSelected), .skip(.nothingSelected))
        for blank in ["", " ", "   \n\t ", "\n\n"] {
            XCTAssertEqual(SelectionTrigger.decide(text: .text(blank)), .skip(.nothingSelected),
                           "「\(blank)」这种选中内容该当成没选中")
        }
    }

    /// 读不到也要有原因可查：界面上都是「没弹」，日志里必须分得清是没选中、超时、控件不支持
    /// 还是「焦点是容器、选区在子树里」（后两种的修法完全不同，前者放弃、后者改读鼠标点）。
    func testEveryUnavailableReasonIsKeptForTheLog() {
        let reasons: [SelectedTextResult.Unavailable] = [.accessibilityNotEnabled, .noFocusedElement,
                                                         .selectedTextUnsupported, .noSelectedTextValue,
                                                         .noElementUnderCursor, .timedOut, .apiError(-25299)]
        for reason in reasons {
            XCTAssertEqual(SelectionTrigger.decide(text: .unavailable(reason)), .skip(.readFailed(reason)))
            XCTAssertFalse(reasonLog(reason).isEmpty)
        }
    }

    private func reasonLog(_ reason: SelectedTextResult.Unavailable) -> String {
        SelectedTextResult.unavailable(reason).logReason
    }

    /// 弹出去的是裁过首尾空白的原样：复制那段留白没意义，朗读读到一串换行更怪。
    func testShownTextIsTrimmedButInteriorSpacingSurvives() {
        XCTAssertEqual(SelectionTrigger.decide(text: .text("  hello world \n")), .show("hello world"))
        XCTAssertEqual(SelectionTrigger.decide(text: .text("第一段\n第二段")), .show("第一段\n第二段"))
    }

    /// 全选整篇文档时弹气泡只会挡字，而且那么长一段既不是「复制一下」也不是「朗读」的场景。
    /// 计的是裁完之后的字数：拖到文末通常会带一串换行，那些不该把一段本来能用的文字挤掉。
    func testTooLongSelectionIsSkippedAtTheDocumentedCap() {
        let atCap = String(repeating: "字", count: SelectionBubbleSettings.maximumCharacters)
        XCTAssertEqual(SelectionTrigger.decide(text: .text(atCap)), .show(atCap))
        let over = atCap + "多"
        XCTAssertEqual(SelectionTrigger.decide(text: .text(over)),
                       .skip(.tooLong(characterCount: SelectionBubbleSettings.maximumCharacters + 1)))
        let padded = "   " + atCap + "\n\n"
        XCTAssertEqual(SelectionTrigger.decide(text: .text(padded)), .show(atCap),
                       "超长判定该看裁完首尾的字数，不是原始字数")
    }
}
