//
//  ProximityLockSettings.swift
//  MacStroke
//
//  蓝牙靠近锁屏的偏好快照。照 RemoteControlSettings 的写法：读的时候重新校验并夹取，
//  因为这几个值也可能来自导入的偏好 plist，写坏的值不该让功能「静默地乱锁屏」。
//

import Foundation
import Storage

public extension Notification.Name {
    /// 靠近锁屏的设置变了，App 侧要重新 apply（开扫 / 停扫 / 换阈值）。
    static let macStrokeProximityLockDidChange =
        Notification.Name("MacStrokeProximityLockDidChange")
}

public struct ProximityLockSettings: Equatable {
    public var enabled: Bool
    public var deviceID: String
    public var deviceName: String
    public var unlockRSSI: Int
    public var lockRSSI: Int
    public var lockDelay: TimeInterval
    public var signalTimeout: TimeInterval
    public var autoUnlock: Bool

    public init(enabled: Bool, deviceID: String, deviceName: String,
                unlockRSSI: Int, lockRSSI: Int,
                lockDelay: TimeInterval, signalTimeout: TimeInterval,
                autoUnlock: Bool) {
        self.enabled = enabled
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.unlockRSSI = unlockRSSI
        self.lockRSSI = lockRSSI
        self.lockDelay = lockDelay
        self.signalTimeout = signalTimeout
        self.autoUnlock = autoUnlock
    }

    /// 没选设备就等于没开：没有目标的「靠近/走开」无从判定，这时候开始扫描只会白耗电。
    public var isArmed: Bool { enabled && !deviceID.isEmpty }

    /// RSSI 的有效区间。BLE 广播实测最低也就 -100 左右，再弱等于收不到。
    public static let rssiRange = -100 ... -20
    /// 滞回至少留这么多 dB：两个阈值挨在一起时，RSSI 本身的几 dB 抖动就会来回锁解。
    public static let minimumHysteresis = 5
    public static let lockDelayRange: ClosedRange<TimeInterval> = 0 ... 300
    public static let signalTimeoutRange: ClosedRange<TimeInterval> = 10 ... 600

    public static func current(from storage: PreferencesStorage = PreferencesStorage()) -> ProximityLockSettings {
        let storedUnlock = storage.getIntOptional(forKey: .proximityUnlockRSSI) ?? StorageDefaults.proximityUnlockRSSI
        let storedLock = storage.getIntOptional(forKey: .proximityLockRSSI) ?? StorageDefaults.proximityLockRSSI
        let (unlock, lock) = sanitizedRSSI(unlock: storedUnlock, lock: storedLock)
        let storedDelay = TimeInterval(storage.getIntOptional(forKey: .proximityLockDelay) ?? StorageDefaults.proximityLockDelay)
        let storedTimeout = TimeInterval(storage.getIntOptional(forKey: .proximitySignalTimeout) ?? StorageDefaults.proximitySignalTimeout)
        return ProximityLockSettings(
            enabled: storage.getBoolOptional(forKey: .enableProximityLock) ?? StorageDefaults.enableProximityLock,
            deviceID: (storage.getStringOptional(forKey: .proximityDeviceID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            deviceName: storage.getStringOptional(forKey: .proximityDeviceName) ?? "",
            unlockRSSI: unlock,
            lockRSSI: lock,
            lockDelay: clamp(storedDelay, to: lockDelayRange, fallback: TimeInterval(StorageDefaults.proximityLockDelay)),
            signalTimeout: clamp(storedTimeout, to: signalTimeoutRange, fallback: TimeInterval(StorageDefaults.proximitySignalTimeout)),
            autoUnlock: storage.getBoolOptional(forKey: .proximityAutoUnlock) ?? StorageDefaults.proximityAutoUnlock
        )
    }

    /// 两个阈值一起看：越界或者滞回不够时整对退回默认值。
    /// 只夹一个的话，用户手写出「解锁 -90 / 锁屏 -60」这种反过来的组合会变成永远解不开锁。
    public static func sanitizedRSSI(unlock: Int, lock: Int) -> (unlock: Int, lock: Int) {
        let fallback = (StorageDefaults.proximityUnlockRSSI, StorageDefaults.proximityLockRSSI)
        guard rssiRange.contains(unlock), rssiRange.contains(lock) else { return fallback }
        guard unlock - lock >= minimumHysteresis else { return fallback }
        return (unlock, lock)
    }

    /// 落盘用的那一对：界面上拖滑块时也用同一条规则，省得写进去的值和读出来的不一样。
    public static func isValidRSSI(unlock: Int, lock: Int) -> Bool {
        sanitizedRSSI(unlock: unlock, lock: lock) == (unlock, lock)
    }

    public static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>, fallback: T) -> T {
        guard value >= range.lowerBound, value <= range.upperBound else { return fallback }
        return value
    }

    @discardableResult
    public static func selectDevice(id: String, name: String,
                                    from storage: PreferencesStorage = PreferencesStorage()) -> ProximityLockSettings {
        storage.setString(id, forKey: .proximityDeviceID)
        storage.setString(name, forKey: .proximityDeviceName)
        storage.synchronize()
        return current(from: storage)
    }
}
