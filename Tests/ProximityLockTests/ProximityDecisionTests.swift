//
//  ProximityDecisionTests.swift
//  ProximityLockTests
//
//  判定状态机的取证。时间全是手工喂的，一秒一步，没有 sleep —— 真等 60 秒超时的测试
//  在 CI 上就是灾难。
//

import XCTest
@testable import ProximityLock

final class ProximityDecisionTests: XCTestCase {
    /// 默认阈值：回来 ≥ -60，走开 ≤ -80，弱满 5 秒才锁，60 秒收不到广播算信号丢。
    private func makeDecision(windowSize: Int = 5,
                              lockDelay: TimeInterval = 5,
                              signalTimeout: TimeInterval = 60) -> ProximityDecision {
        ProximityDecision(unlockRSSI: -60, lockRSSI: -80,
                          lockDelay: lockDelay, signalTimeout: signalTimeout,
                          windowSize: windowSize)
    }

    /// 冷启动不锁屏：程序刚起来时手表不在旁边，那不是「走开」。
    /// 这条是无人值守机器上最要命的防线 —— 少了它，每次开机都会把自己锁在门外。
    func testColdStartNeverLocksNoMatterHowLongTheDeviceIsAway() {
        var decision = makeDecision()
        for second in 0 ... 300 {
            decision.ingest(rssi: -95, at: TimeInterval(second))
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: false), .none,
                           "第 \(second) 秒就不该锁屏")
        }
        XCTAssertEqual(decision.presence, .unknown)
    }

    /// 冷启动时收不到任何广播也一样：没见过的设备不能当成「刚走开」。
    func testColdStartWithoutAnyAdvertisementNeverLocks() {
        var decision = makeDecision()
        for second in stride(from: 0, through: 300, by: 5) {
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: false), .none)
        }
        XCTAssertEqual(decision.presence, .unknown)
    }

    func testStrongSignalMarksPresent() {
        var decision = makeDecision()
        decision.ingest(rssi: -50, at: 0)
        XCTAssertEqual(decision.tick(now: 0, screenLocked: false), .none)
        XCTAssertEqual(decision.presence, .present)
    }

    /// 走开之后要连续弱满 lockDelay 才锁：早一秒都不行，到点必须锁。
    /// 注意 t=0 转成 present 时窗口被清空，所以 t=1 那一帧 -95 的均值就是 -95，
    /// 计时从 t=1 起算，锁屏落在 1 + 5 = 6 秒。
    func testLockFiresExactlyAfterTheDelay() {
        var decision = makeDecision(lockDelay: 5)
        decision.ingest(rssi: -50, at: 0)
        _ = decision.tick(now: 0, screenLocked: false)
        XCTAssertEqual(decision.presence, .present)

        for second in 1 ... 5 {
            decision.ingest(rssi: -95, at: TimeInterval(second))
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: false), .none,
                           "第 \(second) 秒还没等满延时")
            XCTAssertEqual(decision.presence, .present)
        }
        decision.ingest(rssi: -95, at: 6)
        XCTAssertEqual(decision.tick(now: 6, screenLocked: false), .lock)
        XCTAssertEqual(decision.presence, .absent)
    }

    /// 锁完就不再重复提交：人一直不在，也不该一秒锁一次。
    func testLockFiresOnlyOncePerDeparture() {
        var decision = driveToAbsent()
        for second in 100 ... 120 {
            decision.ingest(rssi: -95, at: TimeInterval(second))
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: true), .none)
        }
    }

    /// 滑动均值要能滤掉一次抖动：连续 5 帧 -95（够 lockDelay）也不该锁，
    /// 因为窗口里还压着之前的强样本。把窗口改成 1（等于不平滑）这条就会红。
    func testSlidingWindowAbsorbsAShortDip() {
        var decision = makeDecision(windowSize: 5, lockDelay: 5)
        decision.ingest(rssi: -50, at: 0)
        _ = decision.tick(now: 0, screenLocked: false)
        // 先把窗口填满强样本。
        for second in 1 ... 5 {
            decision.ingest(rssi: -50, at: TimeInterval(second))
            _ = decision.tick(now: TimeInterval(second), screenLocked: false)
        }
        // 再来 7 帧弱信号，均值一路 -59 / -68 / -86 / -95……：
        // 头两帧被窗口里的强样本托住，压根没开始计时；真跌破阈值时延时又从零起算。
        for second in 6 ... 12 {
            decision.ingest(rssi: -95, at: TimeInterval(second))
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: false), .none,
                           "第 \(second) 秒：均值 \(decision.smoothedRSSI.map { Int($0) } ?? 0) 还没连续弱满延时")
        }
        XCTAssertEqual(decision.presence, .present)
        // 一直弱下去终究要锁（14 秒 = 计时起点 9 + 延时 5）：这条不是「永不锁屏」。
        // 计时起点比直觉晚 3 秒，正是因为窗口里还压着 5 帧强样本。
        decision.ingest(rssi: -95, at: 13)
        XCTAssertEqual(decision.tick(now: 13, screenLocked: false), .none)
        decision.ingest(rssi: -95, at: 14)
        XCTAssertEqual(decision.tick(now: 14, screenLocked: false), .lock)
    }

    /// 滞回：中间地带（-70）既不算回来也不算走开，两边都保持原状态。
    /// 只留一个阈值的话，RSSI 在阈值附近抖几 dB 就会来回锁解。
    func testMiddleGroundHoldsEitherState() {
        var present = makeDecision()
        present.ingest(rssi: -50, at: 0)
        _ = present.tick(now: 0, screenLocked: false)
        for second in 1 ... 40 {
            present.ingest(rssi: -70, at: TimeInterval(second))
            XCTAssertEqual(present.tick(now: TimeInterval(second), screenLocked: false), .none)
        }
        XCTAssertEqual(present.presence, .present, "-70 不该把 present 拖成 absent")

        var absent = driveToAbsent()
        for second in 100 ... 140 {
            absent.ingest(rssi: -70, at: TimeInterval(second))
            XCTAssertEqual(absent.tick(now: TimeInterval(second), screenLocked: true), .none)
        }
        XCTAssertEqual(absent.presence, .absent, "-70 不该把 absent 拉回 present")
    }

    /// 收不到广播 = 人走了。CoreBluetooth 永远不会告诉你「设备不见了」，只能靠超时。
    func testSignalTimeoutCountsAsDeparture() {
        var decision = makeDecision(lockDelay: 5, signalTimeout: 60)
        decision.ingest(rssi: -50, at: 0)
        _ = decision.tick(now: 0, screenLocked: false)
        XCTAssertEqual(decision.presence, .present)

        // 60 秒之内还算新鲜（而且窗口刚被清空，没有样本时既不算强也不算弱）。
        for second in stride(from: 1, through: 60, by: 1) {
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: false), .none,
                           "第 \(second) 秒还在信号超时窗口内")
        }
        // 超时之后开始算走开，再等满 lockDelay。
        for second in 61 ... 65 {
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: false), .none)
        }
        XCTAssertEqual(decision.tick(now: 66, screenLocked: false), .lock)
        XCTAssertEqual(decision.presence, .absent)
    }

    /// 回来之后要解锁，但只有屏幕确实锁着才发这个动作。
    func testReturnUnlocksOnlyWhenScreenIsLocked() {
        var decision = driveToAbsent()
        decision.ingest(rssi: -50, at: 200)
        XCTAssertEqual(decision.tick(now: 200, screenLocked: true), .unlock)
        XCTAssertEqual(decision.presence, .present)

        var manual = driveToAbsent()
        manual.ingest(rssi: -50, at: 200)
        // 用户自己按键盘解开了：状态要悄悄纠正回 present，但一个字都不能注入。
        XCTAssertEqual(manual.tick(now: 200, screenLocked: false), .none)
        XCTAssertEqual(manual.presence, .present)
    }

    /// 换状态就清空窗口：不然锁完屏的第一帧会被旧样本立刻推翻，来回弹。
    func testWindowIsClearedOnTransition() {
        var decision = driveToAbsent()
        XCTAssertNil(decision.smoothedRSSI, "锁屏那一刻窗口就该清空")
        // 清空之后没有新样本 → 既不算强也不算弱 → 保持 absent，不会自己解开。
        for second in 100 ... 110 {
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: true), .none)
        }
        XCTAssertEqual(decision.presence, .absent)
    }

    /// 挂起（远程控制接管、录屏中）期间走开计时必须清零，
    /// 否则恢复的那一刻会突然锁屏。计时从 t=1 起算，t=4 时已经弱了 3 秒；
    /// 清零之后要再等满 5 秒（t=5 重新起算 → t=10 才锁）。
    func testCancelPendingLockPreventsAnImmediateLockAfterResume() {
        var decision = makeDecision(lockDelay: 5)
        decision.ingest(rssi: -50, at: 0)
        _ = decision.tick(now: 0, screenLocked: false)
        for second in 1 ... 4 {
            decision.ingest(rssi: -95, at: TimeInterval(second))
            _ = decision.tick(now: TimeInterval(second), screenLocked: false)
        }
        XCTAssertEqual(decision.weakFor ?? -1, 3, accuracy: 0.001)

        decision.cancelPendingLock()
        XCTAssertNil(decision.weakFor)

        for second in 5 ... 9 {
            decision.ingest(rssi: -95, at: TimeInterval(second))
            XCTAssertEqual(decision.tick(now: TimeInterval(second), screenLocked: false), .none,
                           "第 \(second) 秒：挂起之后计时该从零开始")
        }
        decision.ingest(rssi: -95, at: 10)
        XCTAssertEqual(decision.tick(now: 10, screenLocked: false), .lock)
    }

    /// 一帧都不该少：窗口长度就是 5，第 6 帧进来时最老的那帧要出去。
    func testWindowKeepsOnlyTheLastNSamples() {
        var decision = makeDecision(windowSize: 3)
        decision.ingest(rssi: -50, at: 0)
        _ = decision.tick(now: 0, screenLocked: false)
        decision.ingest(rssi: -90, at: 1)
        decision.ingest(rssi: -90, at: 2)
        decision.ingest(rssi: -90, at: 3)
        XCTAssertEqual(decision.smoothedRSSI ?? 0, -90, accuracy: 0.001,
                       "老的强样本必须被挤出去，否则均值永远拉不下来")
    }

    // MARK: - 辅助

    /// 走完整条时间线到「已锁屏」：t=0 见到设备，t=1… 一路弱下去，t=14 锁。
    private func driveToAbsent() -> ProximityDecision {
        var decision = makeDecision(lockDelay: 5)
        decision.ingest(rssi: -50, at: 0)
        _ = decision.tick(now: 0, screenLocked: false)
        precondition(decision.presence == .present)
        for second in 1 ... 90 {
            decision.ingest(rssi: -95, at: TimeInterval(second))
            if decision.tick(now: TimeInterval(second), screenLocked: false) == .lock { return decision }
        }
        precondition(decision.presence == .absent, "时间线没走到锁屏，测试自身有 bug")
        return decision
    }
}
