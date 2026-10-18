//
//  ScreenLockTests.swift
//  ProximityLockTests
//
//  锁屏状态判定的取证。重点只有一个：**什么时候允许把密码打出去**。
//  「屏幕锁着」不是充分条件 —— 安全输入可能属于别的进程（终端的 ssh 密码提示、
//  1Password、屏保还没退），那时候打进去的字符会落进当时有焦点的任意输入框。
//

import XCTest
@testable import ProximityLock

final class ScreenLockTests: XCTestCase {
    func testIsLockedReadsTheSessionDictionary() {
        let session = FakeSession()
        let lock = session.screenLock()
        XCTAssertFalse(lock.isLocked)
        session.isLocked = true
        XCTAssertTrue(lock.isLocked)
    }

    /// 有些系统把这一项报成 Bool 而不是 Int，两种都得认。
    func testIsLockedAcceptsABooleanFlag() {
        let lock = ScreenLock(sessionReader: { ["CGSSessionScreenIsLocked": true] },
                              log: { _ in }, observeNotifications: false)
        XCTAssertTrue(lock.isLocked)
    }

    /// macOS 26 上会话字典里可能已经没有这个键（BLEUnlock PR #190），
    /// 那时只能信 loginwindow 广播的分布式通知。
    func testFallsBackToDistributedNotificationsWhenTheKeyIsGone() {
        let session = FakeSession()
        session.omitsLockKey = true
        let lock = session.screenLock()
        XCTAssertFalse(lock.isLocked, "既没有键也没有通知时，只能当作没锁（保守方向：不注入密码）")

        lock.noteLockState(true, source: "com.apple.screenIsLocked")
        XCTAssertTrue(lock.isLocked)
        lock.noteLockState(false, source: "com.apple.screenIsUnlocked")
        XCTAssertFalse(lock.isLocked)
    }

    /// 会话字典有键时以它为准，通知只做兜底。
    func testSessionDictionaryWinsOverTheNotificationCache() {
        let session = FakeSession()
        let lock = session.screenLock()
        lock.noteLockState(true, source: "com.apple.screenIsLocked")
        session.isLocked = false
        XCTAssertFalse(lock.isLocked)
    }

    func testAcceptingPasswordNeedsLockPlusLoginwindowOwningSecureInput() {
        let session = FakeSession()
        let lock = session.screenLock()

        XCTAssertFalse(lock.isAcceptingPassword, "没锁屏时绝不能注入")

        session.isLocked = true
        XCTAssertFalse(lock.isAcceptingPassword, "锁着但没人占安全输入，说明密码框还没画出来")

        session.secureInputPID = 181
        session.processNameForPID = "loginwindow"
        XCTAssertTrue(lock.isAcceptingPassword)
    }

    /// 这条就是 BLEUnlock issue #182 的补丁：安全输入属于别的进程时，
    /// 焦点可能在一个普通文本框上，密码会直接被打进用户的文档里。
    func testAcceptingPasswordRefusesWhenAnotherProcessOwnsSecureInput() {
        let session = FakeSession()
        session.isLocked = true
        session.secureInputPID = 4242
        session.processNameForPID = "Terminal"
        XCTAssertFalse(session.screenLock().isAcceptingPassword)
    }

    /// 熄屏这道门为什么要单独问：本机 macOS 27 实测，锁屏 5 秒后系统自己把屏关了，
    /// 而屏熄着的时候 `CGSSessionScreenIsLocked` 仍是 1、安全输入仍是 loginwindow，
    /// 也就是 `isAcceptingPassword` 依然为真 —— 光靠它拦不住「打给黑屏」的注入。
    func testDisplayAsleepIsReadLiveNotCached() {
        let session = FakeSession()
        let lock = session.screenLock()
        XCTAssertFalse(lock.isDisplayAsleep)
        session.isDisplayAsleep = true
        XCTAssertTrue(lock.isDisplayAsleep, "注入前问的是当下，熄屏得能当场读到")
    }

    func testSecureInputPIDIsExposedForLogging() {
        let session = FakeSession()
        session.secureInputPID = 181
        XCTAssertEqual(session.screenLock().secureInputPID, 181)
        session.secureInputPID = nil
        XCTAssertNil(session.screenLock().secureInputPID)
    }

    func testLockSkipsTheCallWhenAlreadyLocked() {
        let session = FakeSession()
        session.isLocked = true
        let lock = session.screenLock()
        XCTAssertTrue(lock.lock())
        XCTAssertEqual(session.lockCalls, 0, "已经锁着还去提交，兜底那条 ⌃⌘Q 会打进前台 App")
    }

    func testLockReportsThePrivateAPIResult() {
        let session = FakeSession()
        session.lockResult = false
        XCTAssertFalse(session.screenLock().lock())
        XCTAssertEqual(session.lockCalls, 1)

        session.lockResult = true
        XCTAssertTrue(session.screenLock().lock())
        XCTAssertEqual(session.lockCalls, 2)
    }

    /// 私有函数在本机 login.framework 里确实存在（dyld_info 实测），
    /// 一旦被系统挪走，兜底路径就会接管 —— 这里只断言「两条路都在」，不真去锁屏。
    func testPrivateLockSymbolIsStillExported() throws {
        let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)
        XCTAssertNotNil(handle, "login.framework 打不开了，锁屏只能退回合成 ⌃⌘Q")
        XCTAssertNotNil(dlsym(handle, "SACLockScreenImmediate"),
                        "SACLockScreenImmediate 没了：这台系统上锁屏要走 ⌃⌘Q 兜底")
    }
}
