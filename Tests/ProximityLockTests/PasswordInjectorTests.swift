//
//  PasswordInjectorTests.swift
//  ProximityLockTests
//
//  注入这一层不 post 任何真事件：所有 CGEvent 都进 EventRecorder 记账。
//  真发按键会落进当时有焦点的窗口，在无人值守的机器上等于往用户的文档里打密码。
//

import CoreGraphics
import XCTest
@testable import ProximityLock

final class PasswordInjectorTests: XCTestCase {
    private func makeSession(accepting: Bool = true, locked: Bool = true) -> FakeSession {
        let session = FakeSession()
        session.isLocked = locked
        session.secureInputPID = accepting ? 181 : nil
        session.processNameForPID = "loginwindow"
        return session
    }

    private func makeInjector(screen: ScreenLock,
                              recorder: EventRecorder,
                              chunkSize: Int = 20,
                              maxAttempts: Int = 3,
                              onPost: ((CGEvent) -> Void)? = nil) -> PasswordInjector {
        PasswordInjector(screen: screen,
                         chunkSize: chunkSize,
                         maxAttempts: maxAttempts,
                         settleDelay: 0,
                         poster: { event in
                             recorder(event)
                             onPost?(event)
                         },
                         sleeper: { _ in },
                         log: { _ in })
    }

    // MARK: - 不该打字的时候一个字都不打

    func testRefusesWhenScreenIsNotLocked() {
        let session = makeSession(locked: false)
        let recorder = EventRecorder()
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder)
        XCTAssertEqual(injector.inject("hunter2"), .notAcceptingPassword)
        XCTAssertEqual(recorder.events.count, 0, "没锁屏就发按键 = 密码打进前台 App")
    }

    func testRefusesWhenAnotherProcessOwnsSecureInput() {
        let session = makeSession()
        session.secureInputPID = 4242
        session.processNameForPID = "Terminal"
        let recorder = EventRecorder()
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder)
        XCTAssertEqual(injector.inject("hunter2"), .notAcceptingPassword)
        XCTAssertEqual(recorder.events.count, 0)
    }

    func testEmptyPasswordIsRejected() {
        let session = makeSession()
        let recorder = EventRecorder()
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder)
        XCTAssertEqual(injector.inject(""), .emptyPassword)
        XCTAssertEqual(recorder.events.count, 0)
    }

    // MARK: - 正常路径

    func testTypesThePasswordAndSubmitsWithReturn() {
        let session = makeSession()
        let recorder = EventRecorder()
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder, onPost: { event in
            // 回车之后屏幕就解开了：不回这个状态，注入器会一直重试。
            if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 0x24 {
                session.isLocked = false
                session.secureInputPID = nil
            }
        })
        XCTAssertEqual(injector.inject("hunter2"), .submitted)
        XCTAssertEqual(recorder.typedChunks.joined(), "hunter2")
        XCTAssertEqual(recorder.controlKeyCodes, [0x24],
                       "提交键必须是 kVK_Return(36)。BLEUnlock 那边写的是 52，"
                       + "而 52 在 HIToolbox 里并没有定义成 Return")
    }

    /// 超过 chunkSize 的密码要分块打，且拼回来必须一字不差。
    func testLongPasswordsAreSplitIntoChunks() {
        let session = makeSession()
        let recorder = EventRecorder()
        let password = String(repeating: "a", count: 45)
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder, chunkSize: 20, onPost: { event in
            if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 0x24 {
                session.isLocked = false
            }
        })
        XCTAssertEqual(injector.inject(password), .submitted)
        XCTAssertEqual(recorder.typedChunks.count, 3)
        XCTAssertEqual(recorder.typedChunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(recorder.typedChunks.joined(), password)
    }

    func testNonASCIIPasswordsSurviveTheRoundTrip() {
        let session = makeSession()
        let recorder = EventRecorder()
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder, chunkSize: 4, onPost: { event in
            if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 0x24 {
                session.isLocked = false
            }
        })
        XCTAssertEqual(injector.inject("pässwörd🔑"), .submitted)
        XCTAssertEqual(recorder.typedChunks.joined(), "pässwörd🔑",
                       "emoji 是代理对，分块必须按 UTF-16 走，切在中间会出乱码")
    }

    /// 屏保还没退（锁着但没人占安全输入）时先发一个 Esc 把登录面板叫出来。
    func testWakesThePasswordFieldWithEscapeWhenInScreensaver() {
        let session = makeSession(accepting: false)
        let recorder = EventRecorder()
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder, onPost: { event in
            guard event.type == .keyDown else { return }
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 0x35: session.secureInputPID = 181   // Esc 之后登录面板出来了
            case 0x24: session.isLocked = false
            default: break
            }
        })
        XCTAssertEqual(injector.inject("hunter2"), .submitted)
        XCTAssertEqual(recorder.controlKeyCodes.first, 0x35)
        XCTAssertEqual(recorder.typedChunks.joined(), "hunter2")
    }

    /// Esc 发了还是没进入等输入状态 → 停手，绝不盲打。
    func testGivesUpWhenEscapeDoesNotRevealThePasswordField() {
        let session = makeSession(accepting: false)
        let recorder = EventRecorder()
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder)
        XCTAssertEqual(injector.inject("hunter2"), .notAcceptingPassword)
        XCTAssertEqual(recorder.controlKeyCodes, [0x35], "只发一个 Esc，不到处喷按键")
        XCTAssertTrue(recorder.typedChunks.isEmpty)
    }

    // MARK: - 守卫：中途翻脸就立刻停手

    /// BLEUnlock 只在打字前 0.5 秒查一次锁屏状态，中途解锁就会把密码打进当时有焦点的
    /// 任意输入框（issue #182）。这里模拟「第一块打完屏幕就解开了」。
    func testAbortsImmediatelyWhenTheScreenUnlocksMidTyping() {
        let recorder = EventRecorder()
        // 守卫直接读 recorder：打完第一块（keyDown+keyUp 两个事件）之后屏幕就不锁了。
        let screen = ScreenLock(sessionReader: {
            if recorder.events.count >= 2 { return [:] }
            return ["CGSSessionScreenIsLocked": 1, "kCGSSessionSecureInputPID": 181]
        }, processName: { _ in "loginwindow" }, log: { _ in }, observeNotifications: false)
        let injector = makeInjector(screen: screen, recorder: recorder, chunkSize: 2)
        XCTAssertEqual(injector.inject("abcdefgh"), .abortedGuardTripped)
        XCTAssertEqual(recorder.typedChunks, ["ab"], "守卫翻脸之后剩下的字符一个都不能发")
        XCTAssertEqual(recorder.controlKeyCodes, [], "更不能发回车")
    }

    /// 安全输入换成别的进程（比如用户切到了终端的 ssh 密码提示）同样要停手。
    func testAbortsWhenSecureInputChangesOwner() {
        let session = makeSession()
        let recorder = EventRecorder()
        let screen = ScreenLock(sessionReader: { session.dictionary },
                               processName: { _ in
                                   recorder.events.count >= 2 ? "Terminal" : "loginwindow"
                               },
                               log: { _ in }, observeNotifications: false)
        let injector = makeInjector(screen: screen, recorder: recorder, chunkSize: 2)
        XCTAssertEqual(injector.inject("abcdefgh"), .abortedGuardTripped)
        XCTAssertEqual(recorder.typedChunks, ["ab"])
    }

    func testStopsAfterTheAttemptCap() {
        let session = makeSession()
        let recorder = EventRecorder()
        // 屏幕一直锁着（密码不对），注入器不能无限重试。
        let injector = makeInjector(screen: session.screenLock(), recorder: recorder, maxAttempts: 3)
        XCTAssertEqual(injector.inject("wrong"), .exhaustedAttempts)
        XCTAssertEqual(recorder.controlKeyCodes, [0x24, 0x24, 0x24])
        XCTAssertEqual(recorder.typedChunks.joined(), "wrongwrongwrong")
    }
}
