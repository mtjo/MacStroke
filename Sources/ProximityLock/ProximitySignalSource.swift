//
//  ProximitySignalSource.swift
//  MacStroke
//
//  信号源的抽象：真机上是 CoreBluetooth 扫描，单测里是手工喂帧的假源。
//  没有这层缝，判定逻辑就只能连着蓝牙一起测 —— 而蓝牙授权弹窗需要人点，
//  无人值守的机器上根本跑不了。
//

import Foundation

/// 一帧广播。`deviceID` 用 `CBPeripheral.identifier` 的 UUID 串：
/// 同 Apple ID 的设备（手表 / 手机）macOS 会把随机地址解析成公开地址，这个 UUID 跨扫描稳定；
/// 非苹果设备则取决于厂商是否用静态 MAC 广播（见交接文档的设备矩阵）。
public struct ProximitySample: Equatable {
    public let deviceID: String
    public let rssi: Int
    public let time: TimeInterval

    public init(deviceID: String, rssi: Int, time: TimeInterval) {
        self.deviceID = deviceID
        self.rssi = rssi
        self.time = time
    }
}

/// 扫到过的设备，只用于偏好页那张候选表。名字可以重复也可以改，所以判定只认 id。
public struct ProximityDevice: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var rssi: Int
    public var lastSeen: TimeInterval

    public init(id: String, name: String, rssi: Int, lastSeen: TimeInterval) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.lastSeen = lastSeen
    }
}

public enum ProximitySignalStatus: Equatable {
    case idle
    /// 系统没给蓝牙权限。CoreBluetooth 没有 requestAccess 这种主动申请的 API，
    /// 弹窗是在构造 CBCentralManager 时由系统弹的，所以这个状态只能提示用户去系统设置。
    case unauthorized
    case poweredOff
    case unsupported
    case scanning
}

public protocol ProximitySignalSource: AnyObject {
    /// 只把这台设备的广播转发给 `onSample`。
    /// 为什么在源上过滤：开了 allowDuplicates 之后一秒钟能收到几十上百帧（整栋楼的
    /// BLE 设备都在广播），全都抛到主线程去判定的话纯属浪费。候选表走另一条路（`onDevices`）。
    /// nil = 还没选设备，此时一帧都不转发。
    var targetDeviceID: String? { get set }
    /// 目标设备的一帧广播。
    var onSample: ((ProximitySample) -> Void)? { get set }    /// 候选设备表变了（按信号强弱排序后给）。
    var onDevices: (([ProximityDevice]) -> Void)? { get set }
    var onStatusChange: ((ProximitySignalStatus) -> Void)? { get set }
    func start()
    func stop()
}
