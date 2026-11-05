//
//  ShortcutKeyboardTests.swift
//  MacStroke
//
//  双击录制框弹出的屏幕键盘（issue #78 第 3 条入口改版）的取证。
//
//  为什么要有这块：手写要求用户知道 ⌘⇧2 这几个符号怎么写，多数人只是想把眼前
//  那几个键点出来。键盘面板的路是「点修饰键（可多选/可取消）→ 点主键 → 提交」，
//  修饰键模式则是「点修饰键 → 完成」。判据分三层：
//  - **布局表**：每个字母/数字/标点都映射到它那一格真实的 ANSI 键码，且名字能解回
//    同一个键 —— 表错一格，界面上看不出，用户下次按那个键才发现。
//  - **面板语义**：修饰键是切换、不是提交；主键才提交；修饰键模式只收修饰键；
//    取消/点外面不落库；一颗都没选时「完成」不能把空绑定写进去。
//  - **接进录制框**：走 `makeKeyboardPanel()` 这条真装配（popover 之外的部分），
//    验证模型与回调各只动一次、旧值在取消时原样保留；「改成手写…」要能回到原入口。
//
//  离屏渲染另有一组：面板要真的画出来，且修饰键选中前后同一颗键帽的像素要变 ——
//  只验状态位、不验重绘的话，用户点了键看不见选中，和坏了没区别。
//
import XCTest
import AppKit
import SwiftUI
import Carbon.HIToolbox
import GestureEngine
import Storage
@testable import Preferences

final class ShortcutKeyboardTests: XCTestCase {

    private var retainedWindows: [NSWindow] = []

    override func tearDown() {
        retainedWindows.forEach { $0.contentView = nil }
        retainedWindows.removeAll()
        super.tearDown()
    }

    private final class KeyReportingWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @discardableResult
    private func hostInKeyWindow(_ view: ShortcutRecorderView) -> ShortcutRecorderView {
        let window = KeyReportingWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        window.makeKeyAndOrderFront(nil)
        retainedWindows.append(window)
        return view
    }

    private func keyButtons(in view: NSView) -> [ShortcutKeyButton] {
        var found: [ShortcutKeyButton] = []
        for sub in view.subviews {
            if let button = sub as? ShortcutKeyButton { found.append(button) }
            found.append(contentsOf: keyButtons(in: sub))
        }
        return found
    }

    // MARK: - A 布局表

    /// 26 个字母、10 个数字各在键盘上恰好一格，键码就是 ANSI 那一格。
    /// 表里少一个字母，键盘上就少一颗能点的键；多一格或写错码，点它绑的是别的键。
    func testEveryLetterAndDigitSitsOnItsANSICodeExactlyOnce() {
        let expected: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
            "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
            "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
            "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
            "n": 0x2D, "m": 0x2E,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
            "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
        ]
        let codes = ShortcutKeyboardLayout.shortcutKeys.compactMap { key -> UInt16? in
            if case .key(let code) = key.behavior { return code }
            return nil
        }
        XCTAssertEqual(Set(codes).count, codes.count, "同一个键码在键盘上出现两次")
        for (name, code) in expected {
            XCTAssertTrue(codes.contains(code), "键盘上没有 \(name)（键码 \(code)）")
        }
    }

    /// 每个能提交的键都有名字，名字能由 `KeyboardKeys` 解回同一个码。
    /// 这条咬的是「表里多写了一个码、名字表里却没有」：那种键手写回填与日志都叫不出它。
    /// 注意它只验「名字与码自洽」，验不出两个码写反（名字表也跟着反也是自洽的）——
    /// 方向键这类特殊键的真实码由上一条逐个钉。
    func testEverySubmittedKeyHasANameThatRoundTrips() {
        for key in ShortcutKeyboardLayout.shortcutKeys {
            guard case .key(let code) = key.behavior else { continue }
            let name = KeyboardKeys.name(for: code)
            XCTAssertNotNil(name, "\(key.label)（键码 \(code)）没有名字")
            if let name {
                XCTAssertEqual(KeyboardKeys.keyCode(for: name), code,
                               "\(key.label) 的名字「\(name)」解回另一个键")
            }
        }
    }

    /// 字母数字之外的键也要落在 ANSI 那一格：方向键、空格、回车、Tab、delete、esc、F1/F12。
    /// 上一组用例只覆盖字母数字；↑/↓ 写反了照样「名字与码自洽」，只有这里盯得住。
    func testSpecialKeysSitOnTheirANSICodes() {
        func code(_ name: String) -> UInt16? {
            ShortcutKeyboardLayout.shortcutKeys.first { $0.name == name }.flatMap { key in
                if case .key(let code) = key.behavior { return code }
                return nil
            }
        }
        let expected: [String: UInt16] = [
            "Left Arrow": UInt16(kVK_LeftArrow), "Right Arrow": UInt16(kVK_RightArrow),
            "Up Arrow": UInt16(kVK_UpArrow), "Down Arrow": UInt16(kVK_DownArrow),
            "Space": UInt16(kVK_Space), "Return": UInt16(kVK_Return),
            "Tab": UInt16(kVK_Tab), "Delete": UInt16(kVK_Delete),
            "Escape": UInt16(kVK_Escape), "F1": UInt16(kVK_F1), "F12": UInt16(kVK_F12),
        ]
        for (name, expectedCode) in expected {
            XCTAssertEqual(code(name), expectedCode, "\(name) 不在它那一格上")
        }
    }

    /// 五个修饰键各落一位，键盘表与紧凑面板用的是同一套位。
    func testTheFiveModifiersMapToTheFiveModeledBits() {
        func flags(in keys: [ShortcutKeyboardKey]) -> Set<UInt> {
            Set(keys.compactMap { key -> UInt? in
                if case .modifier(let flag) = key.behavior { return flag }
                return nil
            })
        }
        let expected: Set<UInt> = [
            ShortcutText.functionFlag, ShortcutText.controlFlag, ShortcutText.optionFlag,
            ShortcutText.shiftFlag, ShortcutText.commandFlag,
        ]
        let main = flags(in: ShortcutKeyboardLayout.mainRows.flatMap(\.keys))
        XCTAssertEqual(main, expected, "主键盘缺了某个修饰键，或混进了别的位")
        XCTAssertEqual(flags(in: ShortcutKeyboardLayout.modifiersOnlyKeys), expected,
                       "修饰键模式那排和主键盘不是同一套位")
    }

    /// 所有键帽都在面板里，回车贴住主键盘右沿（它是这一行唯一短键）。
    func testTheLayoutKeepsEveryKeyInsideThePanelAndReturnAtTheRightEdge() {
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        let buttons = keyButtons(in: panel)
        XCTAssertFalse(buttons.isEmpty)
        for button in buttons {
            XCTAssertTrue(panel.bounds.contains(button.frame),
                          "\(button.keyName) 的键帽超出面板：\(button.frame) / \(panel.bounds)")
        }
        let returnKey = buttons.first { $0.keyName == "Return" }
        XCTAssertNotNil(returnKey)
        if let returnKey {
            let rightEdge = 12 + ShortcutKeyboardLayout.mainWidth
            XCTAssertEqual(returnKey.frame.maxX, rightEdge, accuracy: 0.5,
                           "回车没贴右沿：它比上一行短一截，会停在半空")
        }
    }

    /// 每一行的单位宽度不能超过主键盘宽度；除功能键行外都要正好铺满。
    /// 少一格会在行尾留个洞，多一格会把最后一颗键挤出面板 —— 两种在截图里都只是「有点怪」，
    /// 对着这张表比一眼就能抓住。功能键行是照真机留短 1.5 格（F12 落在 delete 左边）。
    func testEveryRowFitsTheMainWidth() {
        for (index, row) in ShortcutKeyboardLayout.mainRows.enumerated() {
            let units = row.keys.reduce(CGFloat(0)) { $0 + $1.units }
                + (row.endsWithArrowCluster ? 3 : 0)
            XCTAssertLessThanOrEqual(units, ShortcutKeyboardLayout.mainRowUnits + 0.0001,
                                     "这一行排了 \(units) 格，比主键盘还宽")
            if index == 0 {
                XCTAssertEqual(units, ShortcutKeyboardLayout.mainRowUnits - 1.5,
                               accuracy: 0.0001,
                               "功能键行该跟真机一样比主键区短 1.5 格")
            } else {
                XCTAssertEqual(units, ShortcutKeyboardLayout.mainRowUnits, accuracy: 0.0001,
                               "这一行排了 \(units) 格，主键盘是 \(ShortcutKeyboardLayout.mainRowUnits) 格")
            }
        }
    }

    /// 真机那块键盘的方向键：← / → 整高，↑ / ↓ 叠在同一列的上、下半格。
    /// 摆错了（比如 ↑ 压到别的行）在截图上是能看出来的，但没人会天天对截图。
    func testTheArrowClusterStacksUpAndDownInOneColumn() {
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        let buttons = keyButtons(in: panel)
        func button(_ name: String) -> ShortcutKeyButton? {
            buttons.first { $0.keyName == name }
        }
        guard let up = button("Up Arrow"), let down = button("Down Arrow"),
              let left = button("Left Arrow"), let right = button("Right Arrow") else {
            return XCTFail("方向键少了一颗")
        }
        XCTAssertEqual(up.frame.minX, down.frame.minX, accuracy: 0.5, "↑/↓ 没叠在同一列")
        XCTAssertEqual(up.frame.width, down.frame.width, accuracy: 0.5)
        XCTAssertEqual(down.frame.minY, up.frame.maxY + ShortcutKeyboardLayout.keyGap, accuracy: 0.5,
                       "↓ 没接在 ↑ 下面那一半")
        XCTAssertEqual(up.frame.height, down.frame.height, accuracy: 0.5)
        XCTAssertLessThan(up.frame.height, left.frame.height, "↑/↓ 该是半格高，和 ← / → 一样高就摆错了")
        XCTAssertLessThan(left.frame.maxX, up.frame.minX, "← 没在叠层左边")
        XCTAssertLessThan(down.frame.maxX, right.frame.minX, "→ 没在叠层右边")
        XCTAssertEqual(right.frame.maxX,
                       12 + ShortcutKeyboardLayout.mainWidth, accuracy: 0.5,
                       "方向键没贴住面板右沿")
    }

    /// ⇪ 只在画面上占位：本 App 的绑定模型里没有它，摆出来能点会让人以为点了个空。
    func testCapsLockIsShownButCannotBePicked() throws {
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        var commits = 0
        panel.onCommit = { _, _ in commits += 1 }
        let capsButton = try XCTUnwrap(
            keyButtons(in: panel).first { $0.keyName == "Caps Lock" })
        XCTAssertFalse(capsButton.isEnabled, "⇪ 该是灰的")
        capsButton.performClick(nil)
        XCTAssertEqual(commits, 0, "点了 ⇪ 却提交了一份绑定")
        XCTAssertFalse(ShortcutKeyboardLayout.shortcutKeys.contains {
            if case .key(let code) = $0.behavior { return code == UInt16(kVK_CapsLock) }
            return false
        }, "⇪ 不该出现在可提交的键里")
    }

    /// 悬停提示就是人话：⌘ ⌦ ⇞ 这些字形对不熟的人不直观，每颗键都要能问出名字。
    func testEveryKeyCarriesAHumanReadableName() {
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        for button in keyButtons(in: panel) {
            XCTAssertFalse(button.keyName.isEmpty)
            XCTAssertEqual(button.toolTip, button.keyName, "\(button.keyLabel) 的提示与名字不一致")
        }
        let escape = keyButtons(in: panel).first { $0.keyName == "Escape" }
        XCTAssertNotNil(escape)
        XCTAssertNotEqual(escape?.toolTip, "⎋", "悬停提示把字形又抄了一遍，等于没解释")
    }

    // MARK: - B 面板语义

    func testTogglingAModifierIsStickyAndShowsUpInTheReadout() {
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        XCTAssertEqual(panel.selectedFlags, 0, "面板一开就替用户选了修饰键")

        panel.toggleModifier(ShortcutText.commandFlag)
        panel.toggleModifier(ShortcutText.shiftFlag)
        XCTAssertEqual(panel.selectedFlags,
                       ShortcutText.commandFlag | ShortcutText.shiftFlag)
        let readout = panel.headerReadoutForTesting
        XCTAssertTrue(readout.contains("⌘") && readout.contains("⇧"),
                      "选中了 ⌘⇧，顶部却没显示：\(readout)")

        panel.toggleModifier(ShortcutText.commandFlag)
        XCTAssertEqual(panel.selectedFlags, ShortcutText.shiftFlag, "再点一下没取消")
        let after = panel.headerReadoutForTesting
        XCTAssertFalse(after.contains("⌘"), "取消 ⌘ 后顶部还挂着：\(after)")
    }

    func testClickingAKeyCommitsTheSelectedModifiersExactlyOnce() {
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        var commits: [(UInt16, UInt)] = []
        panel.onCommit = { code, flags in commits.append((code, flags)) }
        panel.toggleModifier(ShortcutText.commandFlag)
        panel.toggleModifier(ShortcutText.shiftFlag)
        panel.activateKey(UInt16(kVK_ANSI_2))

        XCTAssertEqual(commits.count, 1, "一次点击提交了 \(commits.count) 次")
        XCTAssertEqual(commits.first?.0, UInt16(kVK_ANSI_2))
        XCTAssertEqual(commits.first?.1,
                       ShortcutText.commandFlag | ShortcutText.shiftFlag)
    }

    func testClickingAKeyWithNoModifiersStillCommitsThatBareKey() {
        // 与录制框同一口径：裸键也是合法的一份绑定（录制框里按住 A 也能落库）。
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        var commits: [(UInt16, UInt)] = []
        panel.onCommit = { code, flags in commits.append((code, flags)) }
        panel.activateKey(UInt16(kVK_ANSI_K))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.1, 0)
    }

    func testModifiersOnlyCommitsNoKeyAndRefusesAnEmptySelection() {
        let panel = ShortcutKeyboardView(modifiersOnly: true)
        var commits: [(UInt16, UInt)] = []
        panel.onCommit = { code, flags in commits.append((code, flags)) }

        panel.activateKey(UInt16(kVK_ANSI_K))
        XCTAssertTrue(commits.isEmpty, "修饰键模式把主键也收进去了")
        panel.confirm()
        XCTAssertTrue(commits.isEmpty, "一个修饰键都没选，「完成」却提交了空绑定")

        panel.toggleModifier(ShortcutText.controlFlag)
        panel.toggleModifier(ShortcutText.commandFlag)
        panel.confirm()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.0, 0, "修饰键模式带了键码")
        XCTAssertEqual(commits.first?.1,
                       ShortcutText.controlFlag | ShortcutText.commandFlag)
    }

    func testCancelAndOutsideDismissalCommitNothing() {
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        var commits = 0
        var cancels = 0
        panel.onCommit = { _, _ in commits += 1 }
        panel.onCancel = { cancels += 1 }
        panel.toggleModifier(ShortcutText.optionFlag)
        panel.cancel()
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(cancels, 1)
    }

    // MARK: - C 接进录制框

    private func recorderInKeyWindow() -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.keyCode = UInt16(kVK_ANSI_V)
        view.flags = ShortcutText.commandFlag
        hostInKeyWindow(view)
        return view
    }

    /// 面板只是装配起来、还没点任何键时：模型与宿主都不该被惊动。
    func testOpeningTheKeyboardPanelDoesNotCommitAnything() {
        let view = recorderInKeyWindow()
        var commits = 0
        view.onShortcutChanged = { _, _ in commits += 1 }

        let panel = view.makeKeyboardPanel()
        XCTAssertTrue(view.isEditingWithKeyboard)
        XCTAssertEqual(commits, 0, "一开面板就提交了一次")
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V))
        XCTAssertEqual(view.flags, ShortcutText.commandFlag)
        XCTAssertEqual(panel.selectedFlags, 0, "面板替用户预选了旧修饰键")
    }

    func testPickingModifiersAndAKeyWritesTheModelOnceAndClosesThePanel() {
        let view = recorderInKeyWindow()
        var commits: [(UInt16, UInt)] = []
        view.onShortcutChanged = { code, flags in commits.append((code, flags)) }

        let panel = view.makeKeyboardPanel()
        panel.toggleModifier(ShortcutText.commandFlag)
        panel.toggleModifier(ShortcutText.optionFlag)
        panel.activateKey(UInt16(kVK_ANSI_K))

        XCTAssertEqual(commits.count, 1, "键盘提交发了 \(commits.count) 次回调")
        XCTAssertEqual(commits.first?.0, UInt16(kVK_ANSI_K))
        XCTAssertEqual(commits.first?.1,
                       ShortcutText.commandFlag | ShortcutText.optionFlag)
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_K))
        XCTAssertEqual(view.flags, ShortcutText.commandFlag | ShortcutText.optionFlag)
        XCTAssertFalse(view.isEditingWithKeyboard, "提交完面板还挂着")
        XCTAssertTrue(view.displayString.contains("⌘"))
        XCTAssertTrue(view.displayString.contains("K"))
    }

    func testModifiersOnlyRecorderCommitsAnEmptyKeyThroughTheKeyboard() {
        let view = recorderInKeyWindow()
        view.modifiersOnly = true
        var commits: [(UInt16, UInt)] = []
        view.onShortcutChanged = { code, flags in commits.append((code, flags)) }

        let panel = view.makeKeyboardPanel()
        panel.toggleModifier(ShortcutText.controlFlag)
        panel.toggleModifier(ShortcutText.shiftFlag)
        panel.confirm()

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.0, 0)
        XCTAssertEqual(commits.first?.1,
                       ShortcutText.controlFlag | ShortcutText.shiftFlag)
        XCTAssertEqual(view.keyCode, 0)
        XCTAssertEqual(view.flags, ShortcutText.controlFlag | ShortcutText.shiftFlag)
        XCTAssertFalse(view.isEditingWithKeyboard)
    }

    func testCancellingTheKeyboardKeepsTheOldValueAndFiresNothing() {
        let view = recorderInKeyWindow()
        var commits = 0
        view.onShortcutChanged = { _, _ in commits += 1 }

        let panel = view.makeKeyboardPanel()
        panel.toggleModifier(ShortcutText.shiftFlag)
        panel.cancel()

        XCTAssertEqual(commits, 0)
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V), "取消把旧键写掉了")
        XCTAssertEqual(view.flags, ShortcutText.commandFlag, "取消把旧修饰位写掉了")
        XCTAssertFalse(view.isEditingWithKeyboard)
        XCTAssertNil(view.keyboardPanelForTesting)
    }

    func testTypeInsteadFallsBackToTheOriginalTextEntry() {
        let view = recorderInKeyWindow()
        var commits = 0
        view.onShortcutChanged = { _, _ in commits += 1 }

        let panel = view.makeKeyboardPanel()
        panel.typeInstead()

        XCTAssertFalse(view.isEditingWithKeyboard)
        XCTAssertTrue(view.isEditingManually, "「改成手写」没回到原入口")
        XCTAssertNotNil(view.subviews.first { $0 is NSTextField }, "手写框没挂上")
        XCTAssertEqual(commits, 0)
        view.cancelManualEntry()
    }

    func testDisablingTheRecorderClosesAnOpenKeyboard() {
        let view = recorderInKeyWindow()
        var commits = 0
        view.onShortcutChanged = { _, _ in commits += 1 }

        _ = view.makeKeyboardPanel()
        view.controlEnabled = false
        XCTAssertFalse(view.isEditingWithKeyboard, "禁用后键盘还开着：看得见却已经没有意义")
        XCTAssertNil(view.keyboardPanelForTesting)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(view.keyCode, UInt16(kVK_ANSI_V))
    }

    func testADisabledRecorderRefusesTheKeyboardOnDoubleClick() {
        let view = recorderInKeyWindow()
        view.controlEnabled = false
        view.click(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), clickCount: 2)
        XCTAssertFalse(view.isEditingWithKeyboard, "灰着的框双击弹出了键盘")
    }

    /// 双击能落在录制中的一格上（那一下还会先把录制收掉）。录制没收的话，
    /// 键盘弹出来了、背后的录制框照样在吃 keyDown —— 用户点完键，旧录制先把它改了。
    func testOpeningTheKeyboardStopsAnInFlightRecording() {
        let view = recorderInKeyWindow()
        view.startRecording(currentlyHeld: 0)
        XCTAssertTrue(view.isRecording)

        _ = view.makeKeyboardPanel()
        XCTAssertFalse(view.isRecording, "键盘开着，录制还在背后吃键")
    }

    /// 气泡壳的三件事：点外面要收、尺寸跟着面板、明暗跟着偏好页。
    /// 明暗这条尤其容易悄悄坏 —— 偏好页是深色时气泡用系统外观，里面的键帽就会
    /// 一半深一半浅，而单看面板截图看不出来（面板本身不挂窗口外观）。
    func testThePopoverTakesItsSizeAndAppearanceFromThePage() throws {
        let view = recorderInKeyWindow()
        let window = try XCTUnwrap(view.window)
        let panel = view.makeKeyboardPanel()

        view.drawAppearance = NSAppearance(named: .darkAqua)
        let popover = view.makeKeyboardPopover(for: panel, in: window)
        XCTAssertEqual(popover.behavior, .transient, "点外面不会收起")
        XCTAssertEqual(popover.appearance?.name, .darkAqua, "气泡没跟着偏好页的明暗")
        XCTAssertEqual(popover.contentSize, panel.preferredSize, "气泡尺寸和面板不一致")
        XCTAssertTrue(popover.contentViewController?.view === panel)

        view.drawAppearance = nil
        let plain = view.makeKeyboardPopover(for: panel, in: window)
        XCTAssertEqual(plain.appearance?.name, window.effectiveAppearance.name,
                       "没有偏好页明暗时没退回宿主窗口的外观")
    }

    // MARK: - D 录制提示气泡

    /// 框里只放短句：录制中那一格装不下「请按下快捷键（Esc 取消）」整句，
    /// 塞回去会重新漫出格、盖住旁边的列（装机实测）。长句挪到上方气泡里。
    func testTheBoxShowsOnlyAShortWordWhileRecording() {
        let view = recorderInKeyWindow()
        view.startRecording(currentlyHeld: 0)
        XCTAssertEqual(view.displayedText, L("Recording…"))
        let size = (view.displayedText as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        XCTAssertLessThanOrEqual(size.width, view.bounds.width - 8,
                                 "框内短句仍超出格子")
    }

    /// 按住修饰键时框内给符号回显（原版 SRRecorderControl 的行为），那串符号短、装得下。
    func testHeldModifiersStillEchoInTheBox() {
        let view = recorderInKeyWindow()
        view.startRecording(currentlyHeld: UInt(NX_CONTROLMASK | NX_SHIFTMASK))
        XCTAssertEqual(view.displayedText, "⌃⇧…")
    }

    /// 气泡壳：不随点外面消失、明暗跟偏好页、文案不被裁。
    /// 文案里必须带「双击打开键盘」——双击是屏幕键盘的唯一入口，只靠悬停 tooltip 没人看得见。
    func testTheRecordingHintPopoverShell() throws {
        let view = recorderInKeyWindow()
        let window = try XCTUnwrap(view.window)
        view.drawAppearance = NSAppearance(named: .darkAqua)
        let popover = view.makeRecordingHintPopover(in: window)
        XCTAssertEqual(popover.behavior, .applicationDefined, "点外面会把提示收掉")
        XCTAssertEqual(popover.appearance?.name, .darkAqua, "气泡没跟着偏好页的明暗")
        let content = try XCTUnwrap(popover.contentViewController?.view)
        let label = try XCTUnwrap(content.subviews.first as? NSTextField)
        XCTAssertEqual(label.stringValue,
                       L("Press a key (double-click for keyboard, Esc to cancel)"))
        XCTAssertTrue(label.stringValue.contains("double-click"),
                      "录制提示没提双击入口：\(label.stringValue)")
        XCTAssertGreaterThanOrEqual(popover.contentSize.width,
                                    label.intrinsicContentSize.width + 20,
                                    "气泡比文案还窄，字被裁掉了")
        XCTAssertNotNil(writePNG(of: content, to: "/tmp/shortcut-recording-hint-dblclick.png"),
                        "提示气泡渲不出 PNG")
    }

    /// 修饰键档的气泡文案是另一句，同样带双击入口。
    func testTheModifiersOnlyHintTextDiffers() throws {
        let view = ShortcutRecorderView()
        view.modifiersOnly = true
        hostInKeyWindow(view)
        let window = try XCTUnwrap(view.window)
        let popover = view.makeRecordingHintPopover(in: window)
        let label = try XCTUnwrap(popover.contentViewController?.view.subviews.first as? NSTextField)
        XCTAssertEqual(label.stringValue,
                       L("Hold modifiers (double-click for keyboard, Esc to cancel)"))
    }

    /// 气泡的生死跟录制态走：开始录制挂上、取消/录完都收掉；
    /// 不然录制早结束了提示还浮着，或录制还开着提示先没了。
    func testTheHintFollowsTheRecordingLifecycle() {
        let view = recorderInKeyWindow()
        view.startRecording(currentlyHeld: 0)
        XCTAssertNotNil(view.recordingHintPopoverForTesting, "录制中没有提示气泡")
        view.cancelRecording()
        XCTAssertNil(view.recordingHintPopoverForTesting, "取消后气泡还挂着")
        view.startRecording(currentlyHeld: 0)
        view.stopRecording()
        XCTAssertNil(view.recordingHintPopoverForTesting, "录完后气泡还挂着")
    }

    // MARK: - E 离屏渲染

    /// 面板要真的画出来；选中修饰键前后，同一颗键帽中心的像素要变。
    /// 只改 `state` 不重绘的坏法在状态断言下是全绿的，用户却看不见自己选了哪颗。
    func testThePanelRendersAndASelectedModifierChangesPixels() throws {
        let panel = ShortcutKeyboardView(modifiersOnly: false)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel.preferredSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = panel
        window.layoutIfNeeded()
        retainedWindows.append(window)
        XCTAssertNotNil(writePNG(of: panel, to: "/tmp/shortcut-keyboard-normal.png"),
                        "键盘面板渲不出 PNG")

        // 单颗键帽的像素判据：键帽自己的视图是翻转的，但中心点上下对称，
        // 不受位图行序影响。
        let definition = try XCTUnwrap(
            ShortcutKeyboardLayout.modifiersOnlyKeys.first { $0.name == "Command" })
        let button = ShortcutKeyButton(key: definition)
        button.frame = NSRect(x: 0, y: 0, width: button.preferredWidth,
                              height: ShortcutKeyboardLayout.keyHeight)
        let host = NSWindow(contentRect: button.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
        host.appearance = NSAppearance(named: .aqua)
        host.contentView = button
        host.layoutIfNeeded()
        retainedWindows.append(host)

        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let before = try sampleColor(in: button, at: center)
        button.state = .on
        button.needsDisplay = true
        let after = try sampleColor(in: button, at: center)
        let distance = abs(before.redComponent - after.redComponent)
            + abs(before.greenComponent - after.greenComponent)
            + abs(before.blueComponent - after.blueComponent)
        XCTAssertGreaterThan(distance, 0.05,
                             "选中态没重绘：\(before) → \(after)")
    }

    func testTheModifiersOnlyPanelRendersAtItsOwnSize() throws {
        let panel = ShortcutKeyboardView(modifiersOnly: true)
        XCTAssertLessThan(panel.preferredSize.width, 500, "修饰键面板不该铺成整块键盘")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel.preferredSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = panel
        window.layoutIfNeeded()
        retainedWindows.append(window)
        panel.toggleModifier(ShortcutText.optionFlag)
        XCTAssertNotNil(writePNG(of: panel, to: "/tmp/shortcut-keyboard-modifiers.png"))
    }

    private func sampleColor(in view: NSView, at point: NSPoint) throws -> NSColor {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y))
        return try XCTUnwrap(color.usingColorSpace(.deviceRGB))
    }

    @discardableResult
    private func writePNG(of view: NSView, to path: String) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: URL(fileURLWithPath: path))
        return data
    }
}
