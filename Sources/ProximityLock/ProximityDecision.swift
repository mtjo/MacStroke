//
//  ProximityDecision.swift
//  MacStroke
//
//  「人在不在旁边」的判定状态机。纯逻辑、不碰蓝牙也不碰屏幕，所以整条链路能离线单测。
//
//  三件事叠在一起才敢锁屏：
//   ① 最近 N 个 RSSI 样本的均值（单帧抖动能到十几 dB，用一帧判定必然误锁）；
//   ② 双阈值滞回（强过 unlockRSSI 才算回来，弱过 lockRSSI 才算走开，中间地带保持原状态）；
//   ③ 走开之后还要连续弱满 lockDelay 秒。
//  另外 CoreBluetooth 永远不会告诉你「设备走了」，收不到广播只能靠 signalTimeout 超时判定。
//

import Foundation

public struct ProximityDecision {
    /// `unknown` = 还没见过这台设备。冷启动就是 unknown，而且**从 unknown 不会直接锁屏**：
    /// 程序刚起来时手表可能压根不在旁边，那不是「走开」，锁屏会把人关在门外。
    public enum Presence: String, Equatable {
        case unknown
        case present
        case absent
    }

    public enum Action: Equatable {
        case none
        case lock
        case unlock
    }

    public let unlockRSSI: Int
    public let lockRSSI: Int
    public let lockDelay: TimeInterval
    public let signalTimeout: TimeInterval
    /// 滑动窗口长度。5 帧是 BLEUnlock 长期实测下来的值：再短滤不掉抖动，再长人会走远了还没锁。
    public let windowSize: Int

    public private(set) var presence: Presence = .unknown
    public private(set) var smoothedRSSI: Double?
    public private(set) var secondsSinceSeen: TimeInterval?
    /// 已经弱了多久（没在弱就是 nil）。界面上要显示「还有几秒锁屏」。
    public private(set) var weakFor: TimeInterval?

    private var samples: [Int] = []
    private var lastSeen: TimeInterval?
    private var weakSince: TimeInterval?

    public init(unlockRSSI: Int, lockRSSI: Int,
                lockDelay: TimeInterval, signalTimeout: TimeInterval,
                windowSize: Int = 5) {
        self.unlockRSSI = unlockRSSI
        self.lockRSSI = lockRSSI
        self.lockDelay = lockDelay
        self.signalTimeout = signalTimeout
        self.windowSize = max(1, windowSize)
    }

    /// 收到一帧广播。只记账不判定 —— 判定统一走 `tick`，这样「广播来得密」和「判定频率」解耦。
    public mutating func ingest(rssi: Int, at now: TimeInterval) {
        samples.append(rssi)
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        lastSeen = now
        smoothedRSSI = Double(samples.reduce(0, +)) / Double(samples.count)
    }

    /// 一秒一次的判定。`screenLocked` 由调用方给：用户可能自己手动解了锁，
    /// 这时状态机要把「absent」悄悄纠正回「present」，而不是等他再走开一遍。
    public mutating func tick(now: TimeInterval, screenLocked: Bool) -> Action {
        secondsSinceSeen = lastSeen.map { now - $0 }
        let fresh = secondsSinceSeen.map { $0 <= signalTimeout } ?? false
        let mean = smoothedRSSI

        // 没有样本时既不算强也不算弱：窗口刚被清空（状态切换后）就是这种情况，
        // 这时候必须保持原状态，否则每次锁完屏都会立刻自己解开。
        let strong = fresh && mean != nil && mean! >= Double(unlockRSSI)
        let weak = !fresh || (mean != nil && mean! <= Double(lockRSSI))

        switch presence {
        case .unknown:
            if strong { becomePresent() }
            return .none

        case .present:
            guard weak else {
                weakSince = nil
                weakFor = nil
                return .none
            }
            if weakSince == nil { weakSince = now }
            let elapsed = now - weakSince!
            weakFor = elapsed
            guard elapsed >= lockDelay else { return .none }
            presence = .absent
            clearWindow()
            weakSince = nil
            weakFor = nil
            return .lock

        case .absent:
            guard strong else { return .none }
            becomePresent()
            // 屏幕本来就没锁 = 用户自己解开的，不需要（也不该）再注入一次密码。
            return screenLocked ? .unlock : .none
        }
    }

    /// 挂起期间（远程控制接管、录屏中）不该让「走开计时」继续走：
    /// 恢复的那一刻直接锁屏是最坏的体验。
    public mutating func cancelPendingLock() {
        weakSince = nil
        weakFor = nil
    }

    private mutating func becomePresent() {
        presence = .present
        clearWindow()
        weakSince = nil
        weakFor = nil
    }

    /// 换状态就把窗口清空：留着旧样本会让新状态在第一帧就被旧数据推翻，来回弹。
    private mutating func clearWindow() {
        samples.removeAll()
        smoothedRSSI = nil
    }
}
