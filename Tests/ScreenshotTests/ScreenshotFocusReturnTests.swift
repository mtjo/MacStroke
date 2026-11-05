//
//  ScreenshotFocusReturnTests.swift
//  MacStroke
//
//  issue #78 第 1 条：按截图快捷键之后，Dock 上主程序自己跳到前台（遮罩收了，那个没有
//  图标、没有菜单的进程却留着），用户还得自己点回原来的 App。
//
//  修法是「摊遮罩前记一笔当时的前台，收遮罩时只在前台还是我们的那一下交还」。判据全部
//  走 `ScreenshotController` 那两个接缝（读前台 / 交还），原因和这一层其余用例一样：
//  桩件进程没有 GUI 会话，`NSWorkspace.frontmostApplication` 给不出有意义的答案，
//  而真按一次 ⌘⇧A 又会把本机真的遮罩摊开 —— 判据不能取自被测对象自己。
//
//  钉住的五种坏法：
//  - 记账发生在 `NSApp.activate` **之后**：那时前台已经是我们自己，记出来是 0，
//    交还那一手永久失效（第 2 条用例把「自己当前台 ⇒ 什么都不记」这个后果钉住）。
//  - 读不到前台（0）时硬猜一个还回去 —— 无头/刚启动的那几秒会把焦点甩到别处。
//  - 用户已经自己切走了还硬拉回来：那是比原缺陷更烦人的第二种坏。
//  - 一次交还都不发（灰掉的判据）与发两遍（焦点在两个 App 之间弹）。
//  - 上一场记的那一笔漏到下一场：第二次触发时前台已换人。
//
import AppKit
import XCTest

@testable import Screenshot

final class ScreenshotFocusReturnTests: XCTestCase {

    private let mine = ProcessInfo.processInfo.processIdentifier
    /// 记账用的假 pid：4242 不等于本机任何一个真实进程的话，`activate` 走不到也就看不出来，
    /// 所以这里只断言接缝收到什么，绝不让真的 `NSRunningApplication.activate` 跑起来。
    private let other: pid_t = 4242
    private let stranger: pid_t = 90210

    private var restored: [pid_t] = []

    override func setUp() {
        super.setUp()
        restored = []
        ScreenshotController.focusRestorer = { self.restored.append($0) }
    }

    override func tearDown() {
        ScreenshotController.frontmostPIDReader = nil
        ScreenshotController.focusRestorer = nil
        ScreenshotController.shared.focusOwnerBeforeOverlay = 0
        super.tearDown()
    }

    /// 单例：这一手的状态（记的那一笔）本来就只有一份。
    private var subject: ScreenshotController { ScreenshotController.shared }

    // MARK: - 记账

    func testCaptureRecordsTheAppThatWasFront() {
        ScreenshotController.frontmostPIDReader = { self.other }
        subject.captureFocusOwner()
        XCTAssertEqual(subject.focusOwnerBeforeOverlay, other,
                       "没记账就没有交还，主程序照样跳前台")
    }

    /// 这一条就是「记账必须在 activate 之前」的后果：如果那一步排到了激活之后，
    /// 读回来的前台是我们自己，记出来的就是 0 —— 后面再怎么交还都是空转。
    func testNothingIsRecordedWhenWeAreAlreadyTheFrontApp() {
        ScreenshotController.frontmostPIDReader = { self.mine }
        subject.captureFocusOwner()
        XCTAssertEqual(subject.focusOwnerBeforeOverlay, 0,
                       "前台是自己还记一笔，交还时会把主程序自己 Activate 一遍")

        subject.restoreFocus()
        XCTAssertTrue(restored.isEmpty, "记的是 0 还去交还，等于凭空甩一次焦点")
    }

    func testNothingIsRecordedWhenTheFrontAppIsUnknown() {
        ScreenshotController.frontmostPIDReader = { 0 }
        subject.captureFocusOwner()
        XCTAssertEqual(subject.focusOwnerBeforeOverlay, 0)
        subject.restoreFocus()
        XCTAssertTrue(restored.isEmpty, "读不到前台就硬猜一个还回去，比不交还更糟")
    }

    // MARK: - 交还

    func testRestoreHandsFocusBackOnlyWhileWeHoldIt() {
        ScreenshotController.frontmostPIDReader = { self.other }
        subject.captureFocusOwner()

        ScreenshotController.frontmostPIDReader = { self.mine }
        subject.restoreFocus()

        XCTAssertEqual(restored, [other], "收了遮罩就该把焦点还给原来那家，且只还一次")
    }

    /// 用户自己切走了（点了别的 App、或者遮罩里那条路已经换了家）：硬拉回来是第二次打扰。
    func testRestoreSkipsOnceTheUserSwitchedAway() {
        ScreenshotController.frontmostPIDReader = { self.other }
        subject.captureFocusOwner()

        ScreenshotController.frontmostPIDReader = { self.stranger }
        subject.restoreFocus()

        XCTAssertTrue(restored.isEmpty, "前台已经不是我们了还交还，会把用户刚点的窗口抢走")
    }

    func testRestoreSkipsWhenNothingWasRecorded() {
        ScreenshotController.frontmostPIDReader = { self.mine }
        subject.restoreFocus()
        XCTAssertTrue(restored.isEmpty)
    }

    /// 第二次触发必须重新记账：上一场那一笔不能漏下来。
    func testEachSessionRecalculatesTheOwner() {
        ScreenshotController.frontmostPIDReader = { self.other }
        subject.captureFocusOwner()
        XCTAssertEqual(subject.focusOwnerBeforeOverlay, other)

        ScreenshotController.frontmostPIDReader = { self.mine }
        subject.captureFocusOwner()
        XCTAssertEqual(subject.focusOwnerBeforeOverlay, 0,
                       "旧的记账没被冲掉：下一场会去激活一个跟它无关的 App")
    }

    func testRestoreIsIdempotentAcrossTwoClosePaths() {
        // 一场会话里交还可能走到两次（收遮罩、存盘面板收尾）。第二次读回来的前台已经是
        // 被还回去那家，判据自己就该挡下，不需要额外的账。
        ScreenshotController.frontmostPIDReader = { self.other }
        subject.captureFocusOwner()

        ScreenshotController.frontmostPIDReader = { self.mine }
        subject.restoreFocus()
        ScreenshotController.frontmostPIDReader = { self.other }
        subject.restoreFocus()

        XCTAssertEqual(restored, [other], "交还发两遍就是焦点在两家之间弹")
    }
}
