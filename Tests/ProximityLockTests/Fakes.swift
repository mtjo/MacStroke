//
//  Fakes.swift
//  ProximityLockTests
//
//  这一整套测试的铁律：**不锁屏、不发一个真按键、不构造 CBCentralManager**。
//  无人值守的开发机上锁一次屏就等于把人关在门外，弹一次蓝牙授权框就等于永久挂起。
//  所以锁屏、注入、信号源全部换成假的，只留判定逻辑本身是真的。
//

import CoreGraphics
import Foundation
@testable import ProximityLock

/// 假会话状态：ScreenLock 读的字典、进程名、锁屏动作都从这里来。
final class FakeSession {
    var isLocked = false
    var secureInputPID: Int32?
    var processNameForPID = "loginwindow"
    /// 屏幕是不是熄的。默认 false（亮着）：熄屏是新加的一道门，
    /// 默认值必须让已有的解锁测试照旧走注入那条路，否则「新增校验」就变成「改写老判据」。
    var isDisplayAsleep = false
    /// macOS 26 上 `CGSSessionScreenIsLocked` 被报告已从会话字典里移除（BLEUnlock PR #190），
    /// 打开这个开关就是模拟那种系统。
    var omitsLockKey = false
    var lockCalls = 0
    var lockResult = true

    var dictionary: [String: Any] {
        var values: [String: Any] = [:]
        if !omitsLockKey { values["CGSSessionScreenIsLocked"] = isLocked ? 1 : 0 }
        if let pid = secureInputPID { values["kCGSSessionSecureInputPID"] = pid }
        return values
    }

    func screenLock() -> ScreenLock {
        ScreenLock(sessionReader: { [weak self] in self?.dictionary },
                   processName: { [weak self] _ in self?.processNameForPID },
                   lockNow: { [weak self] in
                       guard let self else { return false }
                       self.lockCalls += 1
                       return self.lockResult
                   },
                   displayAsleep: { [weak self] in self?.isDisplayAsleep ?? false },
                   log: { _ in },
                   observeNotifications: false)
    }
}

/// 假信号源：手工喂帧，顺便记下 start/stop 次数。
final class FakeSource: ProximitySignalSource {
    var targetDeviceID: String?
    var onSample: ((ProximitySample) -> Void)?
    var onDevices: (([ProximityDevice]) -> Void)?
    var onStatusChange: ((ProximitySignalStatus) -> Void)?
    var startCount = 0
    var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    /// 真扫描器会按 targetDeviceID 过滤，这里照抄同一条语义：不是目标设备的帧一个都不转发。
    func report(rssi: Int, at time: TimeInterval, deviceID: String? = nil) {
        let id = deviceID ?? targetDeviceID ?? ""
        guard deviceID != nil || targetDeviceID != nil else { return }
        onSample?(ProximitySample(deviceID: id, rssi: rssi, time: time))
    }

    func report(status: ProximitySignalStatus) { onStatusChange?(status) }
    func report(devices: [ProximityDevice]) { onDevices?(devices) }
}

/// 记下发过的每一个按键事件（不 post，只记账）。
///
/// 只把「打字键」（virtualKey 49，注入器唯一用来带 unicode 的那个）当字符看：
/// Esc / Return 这些键没有 unicode 串，`keyboardGetUnicodeString` 会拿当前键盘布局
/// 去翻译键码，翻出来的是 0x1b、0x0d 这类控制字符 —— 混进断言里就变成
/// 「两个看起来一模一样的字符串不相等」，排查起来极其费劲。
final class EventRecorder {
    static let typingKeyCode: CGKeyCode = 49

    private(set) var events: [CGEvent] = []

    var typedChunks: [String] {
        events.compactMap { event in
            guard event.type == .keyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(Self.typingKeyCode) else { return nil }
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 64)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                           actualStringLength: &length,
                                           unicodeString: &buffer)
            guard length > 0 else { return nil }
            return String(utf16CodeUnits: buffer, count: length)
        }
    }

    /// 非打字键的键码（Esc 0x35、Return 0x24 之类），按发出去的顺序。
    var controlKeyCodes: [CGKeyCode] {
        events.filter { $0.type == .keyDown }
            .map { CGKeyCode($0.getIntegerValueField(.keyboardEventKeycode)) }
            .filter { $0 != Self.typingKeyCode }
    }

    func callAsFunction(_ event: CGEvent) { events.append(event) }
}
