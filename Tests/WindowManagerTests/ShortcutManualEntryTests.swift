//
//  ShortcutManualEntryTests.swift
//  MacStroke
//
//  issue #78 第 3 条（手填快捷键）的取证。
//
//  为什么要有这一手：有些组合键压根走不到录制框 —— ⌃↑（Mission Control 切桌面）、
//  ⌘⇧2（系统截图）这类在事件到达我们的 `keyDown` 之前就被系统或前台应用吃掉，
//  框里点破了也录不进。双击进文本编辑态、把 "⌘⇧2" 直接写出来，是这类键唯一的入口。
//
//  判据分三层，各咬一种坏：
//  - **表**（A 组）名→键码、修饰别名、`key(N)` 逃生口。坏法是表少一项，或把 ANSI 顺序
//    当成 ASCII 顺序猜（⌘Q 投成 ⌘P 那种：界面上看不出来，只有下一次按 Q 才发现）。
//  - **解析**（B 组）四个失败分支各一条。坏法是「认不出就当空/随手挑一个键」——
//    那等于替用户绑一个他没打算绑的键，比不响应更难查。
//  - **视图**（C 组）双击才进手填、灰着进不去、认不出不动模型不发回调、
//    Esc 一次回调都不发、空文本不等于清除、修饰键模式收「只有修饰键」、
//    预填的那串原样提交落回同一个键。这一层全部走 `commitManualEntry` 这条真入口
//    （不是只调纯函数）：纯函数绿而接线错（写回 `text` 的格式串改了、失败也回调）用户照样用不了。
//
//  录制框的用例一律不依赖会话修饰位（要重新录制的地方显式传 `currentlyHeld: 0`，
//  同一条约定见 ShortcutRecorderClearButtonTests）：本机常驻的监听会吃注入的键，
//  且会话的修饰状态可能被别的套件弄脏。
//
import XCTest
import AppKit
import SwiftUI
import Carbon.HIToolbox
import GestureEngine
@testable import Preferences

/// 桩件里 `NSApp` 不是前台程序，窗口永远成不了 key；手填现在只在这扇窗口是 key 时才开
/// （见 `startManualEntry` 里那道闸），所以这里报一个 key 给被测视图看。
private final class KeyReportingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

final class ShortcutManualEntryTests: XCTestCase {

    /// 挂在窗口上才拿得到 `toolTip`（那句拒因只在 draw 时写进 tooltip）。
    private var retainedWindows: [NSWindow] = []

    /// 手填要窗口是 key 才开，所以参与手填的视图都挂在这扇窗口里。
    @discardableResult
    private func hostInKeyWindow(_ view: ShortcutRecorderView) -> ShortcutRecorderView {
        let window = KeyReportingWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        window.makeKeyAndOrderFront(nil)
        retainedWindows.append(window)
        return view
    }

    private func recordedView(keyCode: UInt16 = 9, flags: UInt = 0x100000) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.keyCode = keyCode
        view.flags = flags
        hostInKeyWindow(view)
        return view
    }

    /// 装进一个离屏窗口并渲一次；返回的还是同一个视图（tooltip 是渲的时候才写上的）。
    @discardableResult
    private func mount(_ view: ShortcutRecorderView) throws -> ShortcutRecorderView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        window.layoutIfNeeded()
        view.needsDisplay = true
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                "录制框渲不出位图：窗口没挂上视图树")
        view.cacheDisplay(in: view.bounds, to: rep)
        retainedWindows.append(window)
        return view
    }

    /// 手填框就是视图自己加进去的那个子 `NSTextField`。
    private func editingField(in view: ShortcutRecorderView) -> NSTextField? {
        view.subviews.first { $0 is NSTextField } as? NSTextField
    }

    override func tearDown() {
        retainedWindows.forEach { $0.contentView = nil }
        retainedWindows.removeAll()
        super.tearDown()
    }

    // MARK: - A 表：名 → 键码

    /// ANSI 虚拟键码不是 ASCII 顺序（A=0、S=1、D=2、F=3、H=4、G=5…）。
    /// 这一条把最容易猜错的几个字母钉死：猜错的话框里写着 ⌘Q、按下去投的是另一个键。
    func testLetterCodesFollowTheANSITableNotASCIIOrder() {
        XCTAssertEqual(KeyboardKeys.keyCode(for: "a"), UInt16(kVK_ANSI_A))
        XCTAssertEqual(KeyboardKeys.keyCode(for: "s"), UInt16(kVK_ANSI_S))
        XCTAssertEqual(KeyboardKeys.keyCode(for: "d"), UInt16(kVK_ANSI_D))
        XCTAssertEqual(KeyboardKeys.keyCode(for: "f"), UInt16(kVK_ANSI_F))
        XCTAssertEqual(KeyboardKeys.keyCode(for: "h"), UInt16(kVK_ANSI_H))
        XCTAssertEqual(KeyboardKeys.keyCode(for: "g"), UInt16(kVK_ANSI_G))
        XCTAssertEqual(KeyboardKeys.keyCode(for: "z"), UInt16(kVK_ANSI_Z))
        // 顺带钉住「这几个互不相等」：整表若被写成 ASCII 顺序，它们会连片撞车。
        XCTAssertEqual(Set(["a", "s", "d", "f", "h", "g", "z"]
            .compactMap { KeyboardKeys.keyCode(for: $0) }).count, 7)
    }

    /// 26 个字母逐个钉住取值。
    ///
    /// 上一手只抽查了 7 个，结果这张表在合并 `ActionExecutor` 私有表时漏了 o 与 u ——
    /// 表少一个字母在界面上毫无征兆，只有那条规则按下去没反应才发现（规则动作
    /// `keyPress("o")` 会退化成日志里一行 "Unknown key"）。期望值取自原版那份逐台实测的
    /// 私有表，不是按 ASCII 猜的。
    func testAllTwentySixLettersHaveTheirANSICodes() {
        let expected: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
            "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
            "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
            "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
            "n": 0x2D, "m": 0x2E,
        ]
        XCTAssertEqual(expected.count, 26)
        for (letter, code) in expected {
            XCTAssertEqual(KeyboardKeys.keyCode(for: letter), code, "\(letter) 的键码不对")
        }
        // 全表两两不等：撞车意味着某个字母被写成了 ASCII 顺序。
        XCTAssertEqual(Set(expected.values).count, 26, "两个字母撞在同一个键码上")
    }

    /// 录制框显示的是 ␣ ↩ ⇥ ⎋ ⌫ ← 这一路字形，不是名字。
    /// 「把框里显示的那串原样填回去」是手填最常见的一手，两种写法必须给同一个码。
    func testDisplayGlyphsResolveToTheSameCodeAsTheirNames() {
        let pairs: [(String, String, UInt16)] = [
            ("space", "␣", UInt16(kVK_Space)),
            ("return", "↩", UInt16(kVK_Return)),
            ("tab", "⇥", UInt16(kVK_Tab)),
            ("escape", "⎋", UInt16(kVK_Escape)),
            ("delete", "⌫", UInt16(kVK_Delete)),
            ("forwarddelete", "⌦", UInt16(kVK_ForwardDelete)),
            ("home", "↖", UInt16(kVK_Home)),
            ("end", "↘", UInt16(kVK_End)),
            ("pageup", "⇞", UInt16(kVK_PageUp)),
            ("pagedown", "⇟", UInt16(kVK_PageDown)),
            ("left", "←", UInt16(kVK_LeftArrow)),
            ("right", "→", UInt16(kVK_RightArrow)),
            ("up", "↑", UInt16(kVK_UpArrow)),
            ("down", "↓", UInt16(kVK_DownArrow)),
        ]
        for (name, glyph, code) in pairs {
            XCTAssertEqual(KeyboardKeys.keyCode(for: name), code, "\(name) 不对")
            XCTAssertEqual(KeyboardKeys.keyCode(for: glyph), code, "\(name) 的显示字形 \(glyph) 不认")
        }
    }

    /// 大小写与首尾空白不影响取值；裸数字不是键码（`key(N)` 才是），
    /// 否则 "2" 到底是数字 2 还是键码 2 就说不清了。
    func testLookupIgnoresCaseAndPaddingButNotBareNumbers() {
        XCTAssertEqual(KeyboardKeys.keyCode(for: " Space "), UInt16(kVK_Space))
        XCTAssertEqual(KeyboardKeys.keyCode(for: "ESCAPE"), UInt16(kVK_Escape))
        XCTAssertEqual(KeyboardKeys.keyCode(for: "2"), UInt16(kVK_ANSI_2))
        XCTAssertNil(KeyboardKeys.keyCode(for: "105"), "裸数字不该被当成键码")
        XCTAssertNil(KeyboardKeys.keyCode(for: ""), "空串不是键")
        XCTAssertNil(KeyboardKeys.keyCode(for: "   "))
    }

    /// `key(105)` 是给「表里没名字的键」留的逃生口。这一手坏了（前缀认不出、越界不收），
    /// F13 以上和小键盘以外的 HID 键就压根没有入口，手填对它们等于没做。
    func testNumericEscapeHatchAcceptsInRangeCodesOnly() {
        XCTAssertEqual(KeyboardKeys.keyCode(for: "key(105)"), 105)
        XCTAssertEqual(KeyboardKeys.keyCode(for: "KEY(0)"), 0)
        XCTAssertNil(KeyboardKeys.keyCode(for: "key(65536)"), "超出 UInt16 不能截断成别的键")
        XCTAssertNil(KeyboardKeys.keyCode(for: "key(-1)"))
        XCTAssertNil(KeyboardKeys.keyCode(for: "key(abc)"))
        XCTAssertNil(KeyboardKeys.keyCode(for: "key 105"), "少了括号就不是这个形状")
    }

    // MARK: - B 解析：成功形状与四个失败分支

    /// 符号形、英文别名形、混合形解成同一份绑定 —— 用户写哪一种都不该有差别。
    func testSymbolAndAsciiFormsResolveToTheSameBinding() {
        let expected = ShortcutText.Parsed(keyCode: UInt16(kVK_ANSI_2),
                                           flags: ShortcutText.commandFlag | ShortcutText.shiftFlag)
        for text in ["⌘⇧2", "cmd+shift+2", "Command-Shift-2", " ⌘ shift 2 ", "2⌘⇧"] {
            XCTAssertEqual(ShortcutText.evaluate(text), .success(expected), "\(text) 解错了")
        }
    }

    /// 每个修饰别名各落一位，且与键的先后无关；`^` 就是 ⌃（文档常那么写）。
    /// 连写只给**符号**（"⌘K"）：英文别名必须和键之间给个分隔符，否则 "cmdK" 是一整个
    /// token，落在「认不出」那条可见的拒因上，而不是被猜成 ⌘K。
    func testEveryModifierAliasMapsToItsOwnBit() {
        let cases: [(String, UInt)] = [
            ("⌘", ShortcutText.commandFlag), ("cmd", ShortcutText.commandFlag),
            ("command", ShortcutText.commandFlag),
            ("⌥", ShortcutText.optionFlag), ("opt", ShortcutText.optionFlag),
            ("option", ShortcutText.optionFlag), ("alt", ShortcutText.optionFlag),
            ("⌃", ShortcutText.controlFlag), ("ctrl", ShortcutText.controlFlag),
            ("control", ShortcutText.controlFlag), ("^", ShortcutText.controlFlag),
            ("⇧", ShortcutText.shiftFlag), ("shift", ShortcutText.shiftFlag),
            ("fn", ShortcutText.functionFlag), ("function", ShortcutText.functionFlag),
        ]
        for (alias, bit) in cases {
            // 只有那四个修饰**符号**能跟键连写；"^" 不是符号 token（它只是 ctrl 的别名），
            // 得给它补分隔符，否则 "^K" 是一整个 token。
            let joined = "⌘⌥⌃⇧".contains(alias) ? "\(alias)K" : "\(alias)+K"
            let parsed = ShortcutText.parse(joined)
            XCTAssertEqual(parsed?.flags, bit, "\(joined) 没落到那一位：\(String(describing: parsed))")
            XCTAssertEqual(parsed?.keyCode, UInt16(kVK_ANSI_K), "\(joined) 的键解错了")
        }
        XCTAssertEqual(ShortcutText.evaluate("cmdK"), .failure(.unknownToken("cmdK")),
                       "英文别名连写被猜成了某个键：那是「投出一个用户没打算绑的键」")
        XCTAssertEqual(ShortcutText.evaluate("⌘K"),
                       .success(ShortcutText.Parsed(keyCode: UInt16(kVK_ANSI_K),
                                                    flags: ShortcutText.commandFlag)),
                       "符号连写是 ⌘K 的主写法，不该要求分隔符")
    }

    /// 这一条就是功能存在的理由：这两个组合键录制框压根收不到。
    /// ⌃↑ 落在方向键 126，⌘⇧2 落在主键盘数字排而不是小键盘。
    func testTheTwoCombosThatTheRecorderCannotHearDoParse() {
        XCTAssertEqual(ShortcutText.evaluate("⌃↑"),
                       .success(ShortcutText.Parsed(keyCode: UInt16(kVK_UpArrow),
                                                    flags: ShortcutText.controlFlag)))
        XCTAssertEqual(ShortcutText.evaluate("⌘⇧2"),
                       .success(ShortcutText.Parsed(keyCode: UInt16(kVK_ANSI_2),
                                                    flags: ShortcutText.commandFlag | ShortcutText.shiftFlag)))
        // 小键盘的 2 得写名字：裸 "2" 永远是主键盘那一格。
        XCTAssertEqual(ShortcutText.evaluate("⌘keypad2"),
                       .success(ShortcutText.Parsed(keyCode: UInt16(kVK_ANSI_Keypad2),
                                                    flags: ShortcutText.commandFlag)))
    }

    /// 认不出的那一段原样报回来，不猜。坏法是把 "⌘qq" 解成「只有 ⌘」或随手挑一个键。
    func testUnknownTokenIsReportedVerbatim() {
        XCTAssertEqual(ShortcutText.evaluate("⌘qq"), .failure(.unknownToken("qq")))
        XCTAssertEqual(ShortcutText.evaluate("⌘¢"), .failure(.unknownToken("¢")))
        XCTAssertNil(ShortcutText.parse("⌘qq"))
    }

    /// 「只给修饰键」在 normal 档不是「没有」：keyCode 0 是键盘上的 A，
    /// 收下来等于把用户的 A 键全局吞掉。只有修饰键模式才允许空手。
    func testModifiersOnlyIsRejectedUnlessThatModeAskedForIt() {
        XCTAssertEqual(ShortcutText.evaluate("⌘⌥"), .failure(.missingKey))
        XCTAssertNil(ShortcutText.parse("⌘⌥"))
        XCTAssertEqual(ShortcutText.evaluate("⌘⌥", requiresKey: false),
                       .success(ShortcutText.Parsed(keyCode: 0,
                                                    flags: ShortcutText.commandFlag | ShortcutText.optionFlag)))
    }

    /// 两段都像键时报回来，不选第一个也不选最后一个：猜哪个都可能投出用户没打算绑的那一键。
    /// 顺带钉住分词的边界："a2" 是一整个 token（字母加数字不切），所以它走「认不出」那条。
    func testTwoKeysInOneStringIsItsOwnFailure() {
        XCTAssertEqual(ShortcutText.evaluate("⌘a-2"), .failure(.moreThanOneKey("2")))
        XCTAssertEqual(ShortcutText.evaluate("a b"), .failure(.moreThanOneKey("b")))
        XCTAssertEqual(ShortcutText.evaluate("⌘a2"), .failure(.unknownToken("a2")))
    }

    /// 空串与「只有分隔符」都算空：不是两种坏，是同一条「什么都没有」。
    func testBlankAndSeparatorOnlyTextFailAsEmpty() {
        XCTAssertEqual(ShortcutText.evaluate(""), .failure(.empty))
        XCTAssertEqual(ShortcutText.evaluate("   "), .failure(.empty))
        XCTAssertEqual(ShortcutText.evaluate("+ - , _"), .failure(.empty))
        // 空串在修饰键模式下也不该被读成「清除」：那一手是右端那把叉的职责。
        XCTAssertEqual(ShortcutText.evaluate("", requiresKey: false), .failure(.empty))
    }

    /// 分隔符与连写符号混着写也要切对："⌘-⇧2" 与 "⌘⇧2" 同一份结果。
    /// "-" 是分词符，所以「减号」这个键只能靠名字写 —— 这一条把那条口子也钉住。
    func testTokenizingSplitsBothSeparatorsAndRunOnSymbols() {
        XCTAssertEqual(ShortcutText.evaluate("⌘-⇧2"), ShortcutText.evaluate("⌘⇧2"))
        XCTAssertEqual(ShortcutText.evaluate("ctrl,shift,down"), ShortcutText.evaluate("⌃⇧↓"))
        XCTAssertEqual(ShortcutText.evaluate("⌘minus"),
                       .success(ShortcutText.Parsed(keyCode: UInt16(kVK_ANSI_Minus),
                                                    flags: ShortcutText.commandFlag)))
    }

    // MARK: - C 视图：入口、提交、失败不落地

    /// 双击弹屏幕键盘；单击还是原版那一下切换录制（issue #53/#59 那几行靠它）。
    /// 键盘态里的单击归面板自己，不能顺手把框切进录制态。
    func testDoubleClickOpensTheShortcutKeyboardWhileSingleClickStillRecords() {
        let view = recordedView()
        view.click(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), clickCount: 2)
        XCTAssertTrue(view.isEditingWithKeyboard, "双击没弹出屏幕键盘")
        XCTAssertFalse(view.isRecording, "键盘态不该同时在录制")
        XCTAssertFalse(view.isEditingManually, "双击还留在手写那条口上")
        XCTAssertNil(editingField(in: view), "双击弹键盘却挂了个文本框")

        view.click(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), clickCount: 1)
        XCTAssertFalse(view.isRecording, "键盘态里点一下把框切进录制了")

        view.cancelKeyboardEntry()
        XCTAssertFalse(view.isEditingWithKeyboard)
        view.click(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), clickCount: 1)
        XCTAssertTrue(view.isRecording, "单击丢了原来那一下切换录制")
    }

    /// 灰着的框不许给一个「点得动却已经在吃你键盘」的抓手：手填和录制一起挡。
    func testADisabledRecorderRefusesManualEntry() {
        let view = recordedView()
        view.controlEnabled = false

        view.click(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), clickCount: 2)
        XCTAssertFalse(view.isEditingManually, "灰着的框双击就进手填了")
        view.startManualEntry()
        XCTAssertFalse(view.isEditingManually, "程序调用也绕过了可用性那道闸")
        XCTAssertNil(editingField(in: view), "进不去却已经加上了文本框")
        XCTAssertEqual(view.keyCode, 9, "灰着的框把值改了")
        XCTAssertEqual(view.flags, 0x100000)
    }

    /// 认得出的串走完整条链：改模型 + 恰好一次回调 + 退出编辑态。
    /// 回调发两次宿主会写两次盘，一次都不发就是「填了没反应」。
    func testCommittingReadableTextWritesTheModelAndNotifiesOnce() {
        let view = recordedView()
        var commits: [(UInt16, UInt)] = []
        view.onShortcutChanged = { code, flags in commits.append((code, flags)) }

        view.startManualEntry()
        XCTAssertTrue(view.commitManualEntry("⌃⇧⌥K"))

        XCTAssertEqual(commits.count, 1, "回调发了 \(commits.count) 次")
        XCTAssertEqual(commits.first?.0, UInt16(kVK_ANSI_K))
        let expected = ShortcutText.controlFlag | ShortcutText.shiftFlag | ShortcutText.optionFlag
        XCTAssertEqual(commits.first?.1, expected)
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_K))
        XCTAssertEqual(view.flags, expected)
        XCTAssertFalse(view.isEditingManually, "提交完还挂着编辑框")
        for symbol in ["⌃", "⌥", "⇧"] {
            XCTAssertTrue(view.displayString.contains(symbol),
                          "显示串少了刚提交的 \(symbol)：\(view.displayString)")
        }
        XCTAssertFalse(view.displayString.contains("⌘"),
                       "旧值那一份 ⌘ 还挂在显示串上：\(view.displayString)")
    }

    /// 认不出的那一次：模型一个字段都不许动，回调一次都不发，编辑态退出。
    /// 这是全文件最贵的一条 —— 写进模型就是给规则绑一个用户没打算绑的键。
    func testRejectedTextLeavesTheModelUntouchedAndFiresNoCallback() {
        let view = recordedView(keyCode: UInt16(kVK_ANSI_V), flags: 0x100000)
        var commits = 0
        view.onShortcutChanged = { _, _ in commits += 1 }

        view.startManualEntry()
        XCTAssertFalse(view.commitManualEntry("⌘qq"))
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V), "被拒的串把键改了")
        XCTAssertEqual(view.flags, 0x100000, "被拒的串把修饰键改了")
        XCTAssertEqual(commits, 0, "被拒还通知了宿主：偏好里会写进一个没解出来的值")
        XCTAssertFalse(view.isEditingManually)

        // 另一种坏法：只有修饰键（⌘⌥）被当成「清除」，或被当成 ⌘⌥A 收进模型。
        XCTAssertFalse(view.commitManualEntry("⌘⌥"))
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V))

        // 两段都像键：同理不收，旧值还是那一份。
        XCTAssertFalse(view.commitManualEntry("⌘a2"))
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V))
        XCTAssertEqual(commits, 0)
    }

    /// 把文本框清空再回车不等于「清除快捷键」：置空是那把叉的职责（它写的必须是空串）。
    /// 这里必须「什么都没发生」，否则用户以为清掉了，宿主那边却收到一次提交。
    func testBlankingTheFieldIsNotClear() {
        let view = recordedView(keyCode: UInt16(kVK_ANSI_V), flags: 0x100000)
        var commits = 0
        var clears = 0
        view.onShortcutChanged = { _, _ in commits += 1 }
        view.onClear = { clears += 1 }

        view.startManualEntry()
        XCTAssertFalse(view.commitManualEntry("   "))
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(clears, 0, "清空文本框走了清除那条路")
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V))
        XCTAssertTrue(view.hasRecordedValue)
    }

    /// Esc（这里用编程调用 `cancelManualEntry`，就是文本框那一下的落点）：
    /// 旧值原样留着，一次回调都不发，文本框从视图上摘掉。
    func testCancelKeepsTheOldValueAndFiresNothing() {
        let view = recordedView(keyCode: UInt16(kVK_ANSI_V), flags: 0x100000)
        var commits = 0
        view.onShortcutChanged = { _, _ in commits += 1 }

        view.startManualEntry()
        XCTAssertNotNil(editingField(in: view), "手填没把文本框挂进视图")
        view.cancelManualEntry()

        XCTAssertFalse(view.isEditingManually)
        XCTAssertNil(editingField(in: view), "取消后文本框还挂在视图上")
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V))
        XCTAssertEqual(view.flags, 0x100000)
    }

    /// 挂进窗口、但这扇窗口成不了 key（探针实测：本机 `NSApp.isActive` 恒为 false，
    /// 桩件不是有 bundle 的前台程序）—— 这正是「从别的 App 里双击偏好窗那一下」的形状：
    /// 本视图 `acceptsFirstMouse` 返回 true，那一下不会先把窗口变 key，
    /// `selectText` 当场把编辑结束掉，`controlTextDidEndEditing` 立刻送到委托。
    ///
    /// 没有 `manualEditingBegan` 那道闸时框里预填的旧值被当成用户敲的串提交了一次
    /// （探针实测 `commits=1`）：界面上「双击没反应」，库里却多写了一次同样的快捷键。
    /// 这一条钉住：编辑没起来的这一次，旧值原样、一次回调都不发、也不留一只挂在视图上
    /// 却进不去的文本框。
    func testADoubleClickIntoAWindowThatCannotHostEditingCommitsNothing() {
        let view = recordedView(keyCode: UInt16(kVK_ANSI_V), flags: 0x100000)
        var commits = 0
        var clears = 0
        view.onShortcutChanged = { _, _ in commits += 1 }
        view.onClear = { clears += 1 }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        window.setFrameOrigin(NSPoint(x: -400, y: -400))
        window.makeKeyAndOrderFront(nil)
        retainedWindows.append(window)

        XCTAssertFalse(window.isKeyWindow, "这台机器上窗口竟是 key 的：这条用例的口径要重新想")

        view.startManualEntry()

        XCTAssertEqual(commits, 0, "编辑没起来的那一次把预填的旧串提交了")
        XCTAssertEqual(clears, 0)
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V))
        XCTAssertEqual(view.flags, 0x100000)
        XCTAssertTrue(view.hasRecordedValue, "旧值被写掉了")
        XCTAssertFalse(view.isEditingManually, "编辑没起来却留着手填态：框子已经不在，界面还在骗人")
        XCTAssertNil(editingField(in: view), "编辑没起来却把文本框留在视图上")
    }

    /// 双击进来的这一下必须真的停得住：文本框在、字段编辑器挂上、预填串被全选、
    /// 一次回调都不发；改写后回车（结束编辑走真委托）才落回模型、只发一次。
    ///
    /// 3.2.4 装机版坏在 `startManualEntry` 里紧跟 `makeFirstResponder` 的那句
    /// `field.selectText(nil)`：它会把刚挂上的编辑会话当场结束（真机实测
    /// `controlTextDidEndEditing` 2 ms 后到委托，而 `controlTextDidBeginEditing` 从没来），
    /// 闸门据此判「编辑没起来」把手填清掉 —— 用户看见的就是「双击没反应」。
    func testAManualEntryInAKeyWindowStaysAliveUntilCommit() throws {
        let view = recordedView(keyCode: UInt16(kVK_ANSI_V), flags: 0x100000)
        var commits: [(UInt16, UInt)] = []
        view.onShortcutChanged = { code, flags in commits.append((code, flags)) }

        view.startManualEntry()

        XCTAssertTrue(view.isEditingManually, "进了手填却当场退出去：编辑会话被结束了")
        XCTAssertEqual(commits.count, 0, "只是进手填就把预填的值提交了一次")
        let field = try XCTUnwrap(editingField(in: view), "手填框没挂进视图")
        let editor = try XCTUnwrap(field.currentEditor(), "字段编辑器没挂上：这个框打不了字")
        XCTAssertEqual(editor.selectedRange,
                       NSRange(location: 0, length: (field.stringValue as NSString).length),
                       "预填串没全选：用户一打字会插在旧串中间")

        // 改写后回车：结束编辑这一手走真委托，内容落回模型。
        (editor as? NSTextView)?.string = "⌃↑"
        view.window?.makeFirstResponder(nil)
        XCTAssertFalse(view.isEditingManually, "回车后还挂着编辑框")
        XCTAssertEqual(commits.count, 1, "回车提交了 \(commits.count) 次")
        XCTAssertEqual(commits.first?.0, UInt16(kVK_UpArrow))
        XCTAssertEqual(view.keyCode, UInt16(kVK_UpArrow))
        XCTAssertNil(editingField(in: view), "提交后文本框还留在视图上")
    }

    /// 空值时手填框必须是空的：normal 档 keyCode 0 显示出来是「A」，
    /// 直接抄显示串等于替用户预填了一个键，回车就绑成 ⌘A。
    func testAnEmptyRecorderOpensManualEntryWithAPrefilledNothing() {
        let view = hostInKeyWindow(ShortcutRecorderView())
        XCTAssertFalse(view.hasRecordedValue)
        var commits = 0
        view.onShortcutChanged = { _, _ in commits += 1 }
        view.startManualEntry()

        XCTAssertEqual(editingField(in: view)?.stringValue ?? "<没有文本框>", "",
                       "空值框进手填被预填了东西")
        XCTAssertNotNil(editingField(in: view)?.placeholderString,
                        "没有占位文案就没人知道这里能打字")
        // 「只有修饰键」在 normal 档不算清空：一次回调都不该发。
        XCTAssertFalse(view.commitManualEntry("⌘"))
        XCTAssertEqual(commits, 0)
    }

    /// 修饰键那一格（issue #59「按住这些键时暂停手势」）本来就能只收修饰键，
    /// 手填这条口也得同样收 —— 否则同一个控件两种模式行为不一致。
    func testModifiersOnlyRecorderAcceptsAHandTypedModifierSet() {
        let view = hostInKeyWindow(ShortcutRecorderView())
        view.modifiersOnly = true
        var commits: [(UInt16, UInt)] = []
        view.onShortcutChanged = { code, flags in commits.append((code, flags)) }

        view.startManualEntry()
        XCTAssertTrue(view.commitManualEntry("⌃⌘"))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.0, 0, "修饰键模式不该带键")
        XCTAssertEqual(commits.first?.1, ShortcutText.controlFlag | ShortcutText.commandFlag)
        XCTAssertTrue(view.hasRecordedValue)
        // 预填的那串（只有修饰符号）也得能原样提交回去。
        view.startManualEntry()
        XCTAssertTrue(view.commitManualEntry(editingField(in: view)?.stringValue ?? ""))
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.last?.1, ShortcutText.controlFlag | ShortcutText.commandFlag)
    }

    /// 往返：双击进来那串，一个字都不改、直接回车，必须落回同一个键与同一份修饰位。
    ///
    /// 这一条咬的是两张表跑偏：显示用的字形表把小键盘 0–9 画成主键盘的 "0"…"9"、
    /// 把两种回车都画成 ↩（36 和 76 撞车）。抄显示串预填的话，「改了个修饰键就回车」
    /// 会把键悄悄换到另一格 —— 用户看不出任何差别，只有下一次按那个键才发现。
    func testThePrefilledTextRoundTripsToTheSameBinding() throws {
        let flags = ShortcutText.commandFlag | ShortcutText.shiftFlag
        let codes: [UInt16] = [
            UInt16(kVK_Space), UInt16(kVK_Return), UInt16(kVK_Tab), UInt16(kVK_Escape),
            UInt16(kVK_Delete), UInt16(kVK_ForwardDelete), UInt16(kVK_Home), UInt16(kVK_End),
            UInt16(kVK_PageUp), UInt16(kVK_PageDown),
            UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow),
            UInt16(kVK_F1), UInt16(kVK_F5), UInt16(kVK_F12),
            UInt16(kVK_ANSI_KeypadEnter), UInt16(kVK_ANSI_Keypad0), UInt16(kVK_ANSI_Keypad5),
            UInt16(kVK_ANSI_Keypad9), UInt16(kVK_ANSI_KeypadPlus), UInt16(kVK_ANSI_KeypadMultiply),
        ]
        for code in codes {
            let view = recordedView(keyCode: code, flags: flags)
            view.startManualEntry()
            let seed = try XCTUnwrap(editingField(in: view)?.stringValue,
                                     "键码 \(code) 没能进手填")
            XCTAssertTrue(view.commitManualEntry(seed),
                          "预填的「\(seed)」被自己拒了（键码 \(code)）")
            XCTAssertEqual(view.keyCode, code, "预填「\(seed)」提交后换成了别的键")
            XCTAssertEqual(view.flags, flags, "预填「\(seed)」把修饰位弄丢了")
        }
    }

    /// 拒因要看得见：被拒之后渲一次，tooltip 里得写着「到底是哪一段不认识」。
    /// 静默吃掉最容易被读成「这功能坏了」（同一口径见 issue #72 那把叉）。
    /// 桩件里 `L()` 只吃 en 表，所以断言取 en 那一份的字面。
    func testTheRejectionReasonLandsInTheToolTip() throws {
        let view = recordedView(keyCode: UInt16(kVK_ANSI_V), flags: 0x100000)
        view.startManualEntry()
        XCTAssertFalse(view.commitManualEntry("⌘qq"))
        try mount(view)
        let tip = view.toolTip ?? ""
        XCTAssertTrue(tip.contains("qq"), "tooltip 没带上不认识的那一段：\(tip)")
        XCTAssertTrue(tip.contains("key"), "tooltip 没写成一句人话：\(tip)")

        // 回去重新录制 = 上一次被拒的作废，那句红字提示不该还挂着。
        view.startRecording(currentlyHeld: 0)
        try mount(view)
        XCTAssertFalse((view.toolTip ?? "").contains("qq"),
                       "重新录制后还挂着上一串的拒因：\(view.toolTip ?? "")")
    }

    /// 真链路（不是只调视图）：SwiftUI 那层 `ShortcutRecorder(text:)` 的 binding
    /// 必须收到录制框同一份口径的串（`keyCode=…, flags=…`）。格式串一改，消费端
    /// （AppDelegate / WindowManager）就解析不出来，快捷键看着录好了其实没上膛。
    func testTheRepresentableWritesTheCommittedBindingInItsOwnFormat() throws {
        final class Box { var text = "" }
        let box = Box()
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let host = NSHostingView(rootView: ShortcutRecorder(text: binding)
            .frame(width: 200, height: 28))
        let window = KeyReportingWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 40)
        host.layoutSubtreeIfNeeded()
        retainedWindows.append(window)

        let recorder = try XCTUnwrap(firstRecorder(in: host), "宿主视图里找不到录制框")
        recorder.startManualEntry()
        XCTAssertTrue(recorder.commitManualEntry("⌃↑"))
        XCTAssertEqual(box.text, "keyCode=\(kVK_UpArrow), flags=\(ShortcutText.controlFlag)",
                       "宿主收到的串不是录制框那份口径")

        // 反向：认不出的串既不动模型也不动 binding（binding 被写坏就是偏好里存进一句垃圾）。
        recorder.startManualEntry()
        XCTAssertFalse(recorder.commitManualEntry("⌘qq"))
        XCTAssertEqual(box.text, "keyCode=\(kVK_UpArrow), flags=\(ShortcutText.controlFlag)")
    }

    private func firstRecorder(in view: NSView) -> ShortcutRecorderView? {
        if let hit = view as? ShortcutRecorderView { return hit }
        for sub in view.subviews {
            if let hit = firstRecorder(in: sub) { return hit }
        }
        return nil
    }
}
