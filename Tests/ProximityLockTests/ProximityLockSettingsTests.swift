//
//  ProximityLockSettingsTests.swift
//  ProximityLockTests
//
//  阈值校验的取证。这几个值也可能来自导入的偏好 plist，写坏了不该让功能「静默地乱锁屏」。
//

import XCTest
import Storage
@testable import ProximityLock

final class ProximityLockSettingsTests: XCTestCase {
    private static let suiteName = "ProximityLockSettingsTests"

    private var defaults: UserDefaults!
    private var storage: PreferencesStorage!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        storage = PreferencesStorage(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    /// 出厂默认必须是「关」，而且两个开关（锁屏 / 自动解锁）都关。
    /// 这一条会自动锁用户的屏幕，没点头之前一次都不该发生。
    func testDefaultsAreOffAndUnarmed() {
        let settings = ProximityLockSettings.current(from: storage)
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.autoUnlock)
        XCTAssertFalse(settings.isArmed)
        XCTAssertEqual(settings.deviceID, "")
        XCTAssertEqual(settings.unlockRSSI, StorageDefaults.proximityUnlockRSSI)
        XCTAssertEqual(settings.lockRSSI, StorageDefaults.proximityLockRSSI)
        XCTAssertEqual(settings.lockDelay, TimeInterval(StorageDefaults.proximityLockDelay))
        XCTAssertEqual(settings.signalTimeout, TimeInterval(StorageDefaults.proximitySignalTimeout))
    }

    /// 开了总开关但没选设备 = 没开。没有目标的「靠近」无从判定，这时候扫描只是白耗电。
    func testEnabledWithoutADeviceIsNotArmed() {
        storage.setBool(true, forKey: .enableProximityLock)
        let settings = ProximityLockSettings.current(from: storage)
        XCTAssertTrue(settings.enabled)
        XCTAssertFalse(settings.isArmed)

        _ = ProximityLockSettings.selectDevice(id: "11111111-2222-3333-4444-555555555555",
                                               name: "MTJO 的 Apple Watch", from: storage)
        XCTAssertTrue(ProximityLockSettings.current(from: storage).isArmed)
    }

    /// 设备 id 只留空白等于没选：从别的机器导偏好时最容易出这种脏值。
    func testWhitespaceDeviceIDIsNotArmed() {
        storage.setBool(true, forKey: .enableProximityLock)
        storage.setString("   ", forKey: .proximityDeviceID)
        XCTAssertFalse(ProximityLockSettings.current(from: storage).isArmed)
    }

    /// 反过来的阈值对（解锁 -90 / 锁屏 -60）会让用户永远解不开锁，整对退回默认。
    func testReversedThresholdsFallBackToDefaults() {
        storage.setInt(-90, forKey: .proximityUnlockRSSI)
        storage.setInt(-60, forKey: .proximityLockRSSI)
        let settings = ProximityLockSettings.current(from: storage)
        XCTAssertEqual(settings.unlockRSSI, StorageDefaults.proximityUnlockRSSI)
        XCTAssertEqual(settings.lockRSSI, StorageDefaults.proximityLockRSSI)
        XCTAssertFalse(ProximityLockSettings.isValidRSSI(unlock: -90, lock: -60))
    }

    /// 两个阈值挨在一起就没有滞回了，RSSI 抖几 dB 就会来回锁解 → 同样退回默认。
    func testThresholdsWithoutHysteresisFallBackToDefaults() {
        storage.setInt(-70, forKey: .proximityUnlockRSSI)
        storage.setInt(-72, forKey: .proximityLockRSSI)
        let settings = ProximityLockSettings.current(from: storage)
        XCTAssertEqual(settings.unlockRSSI, StorageDefaults.proximityUnlockRSSI)
        XCTAssertEqual(settings.lockRSSI, StorageDefaults.proximityLockRSSI)
    }

    func testThresholdsAtTheExactMinimumHysteresisAreKept() {
        storage.setInt(-65, forKey: .proximityUnlockRSSI)
        storage.setInt(-70, forKey: .proximityLockRSSI)
        let settings = ProximityLockSettings.current(from: storage)
        XCTAssertEqual(settings.unlockRSSI, -65)
        XCTAssertEqual(settings.lockRSSI, -70)
        XCTAssertTrue(ProximityLockSettings.isValidRSSI(unlock: -65, lock: -70))
    }

    /// RSSI 超出物理范围（正数、或者比 -100 还弱）也退回默认。
    func testOutOfRangeRSSIFallsBackToDefaults() {
        for pair in [(10, -80), (-60, -140), (0, -200)] {
            storage.setInt(pair.0, forKey: .proximityUnlockRSSI)
            storage.setInt(pair.1, forKey: .proximityLockRSSI)
            let settings = ProximityLockSettings.current(from: storage)
            XCTAssertEqual(settings.unlockRSSI, StorageDefaults.proximityUnlockRSSI, "pair \(pair)")
            XCTAssertEqual(settings.lockRSSI, StorageDefaults.proximityLockRSSI, "pair \(pair)")
        }
    }

    /// 延时和超时越界（负数、离谱的大值）退回默认：负延时等于「一弱就锁」，正是最怕的那种。
    func testOutOfRangeTimingsFallBackToDefaults() {
        storage.setInt(-3, forKey: .proximityLockDelay)
        storage.setInt(2, forKey: .proximitySignalTimeout)
        let settings = ProximityLockSettings.current(from: storage)
        XCTAssertEqual(settings.lockDelay, TimeInterval(StorageDefaults.proximityLockDelay))
        XCTAssertEqual(settings.signalTimeout, TimeInterval(StorageDefaults.proximitySignalTimeout))
    }

    func testReasonableTimingsAreKept() {
        storage.setInt(20, forKey: .proximityLockDelay)
        storage.setInt(120, forKey: .proximitySignalTimeout)
        let settings = ProximityLockSettings.current(from: storage)
        XCTAssertEqual(settings.lockDelay, 20)
        XCTAssertEqual(settings.signalTimeout, 120)
    }

    func testSelectDevicePersistsBothIDAndName() {
        _ = ProximityLockSettings.selectDevice(id: "AAAA", name: "小米手环 8", from: storage)
        let settings = ProximityLockSettings.current(from: storage)
        XCTAssertEqual(settings.deviceID, "AAAA")
        XCTAssertEqual(settings.deviceName, "小米手环 8")
    }
}
