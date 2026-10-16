//
//  BluetoothProximityScanner.swift
//  MacStroke
//
//  只扫描、绝不 `connect()`：手表都已经和手机配过对了，再去连它要么连不上、
//  要么把手机那边的连接挤掉；而 RSSI 从广播包里就能读到，根本不需要连接。
//
//  CBCentralManager 是**懒创建**的：构造它系统就会弹蓝牙授权框，
//  所以只有「用户点了扫描」或「功能真的开了」才会走到那一步。
//  无人值守的机器上弹一个没人点的框 = 进程挂在那儿。
//

import AppKit
import CoreBluetooth
import Foundation

public final class BluetoothProximityScanner: NSObject, ProximitySignalSource {
    public var targetDeviceID: String?
    public var onSample: ((ProximitySample) -> Void)?
    public var onDevices: (([ProximityDevice]) -> Void)?
    public var onStatusChange: ((ProximitySignalStatus) -> Void)?

    /// 候选表多久重发一次。allowDuplicates 下每帧都发的话界面会抖成一片。
    private let publishInterval: TimeInterval = 1
    /// 超过这么久没见到的设备从候选表里剔掉：否则列表会越攒越长，全是早就走掉的设备。
    private let pruneInterval: TimeInterval = 30
    /// 候选表最多列这么多台。
    private let maxListedDevices = 40

    private let queue = DispatchQueue(label: "net.mtjo.MacStroke.proximity.ble")
    private var central: CBCentralManager?
    private var devices: [String: ProximityDevice] = [:]
    private var lastPublish: TimeInterval = 0
    private var wantsScan = false
    private var lastStatus: ProximitySignalStatus = .idle
    private let now: () -> TimeInterval
    private let log: (String) -> Void
    private var wakeObserver: NSObjectProtocol?

    public init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
                log: @escaping (String) -> Void = { NSLog("%@", "[ProximityLock] " + $0) }) {
        self.now = now
        self.log = log
        super.init()
    }

    // MARK: - ProximitySignalSource

    public func start() {
        queue.async {
            self.wantsScan = true
            // 睡眠唤醒之后 bluetoothd 可能已经重启过，扫描会静默停掉，所以挂个观察者重新扫。
            if self.wakeObserver == nil {
                self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                        guard let self else { return }
                        self.log("系统唤醒，重新开始扫描")
                        self.queue.async { self.resumeScan() }
                    }
            }
            if self.central == nil {
                // 这一句就会触发系统的蓝牙授权弹窗（没有 requestAccess 这种主动 API）。
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else {
                self.resumeScan()
            }
        }
    }

    public func stop() {
        queue.async {
            self.wantsScan = false
            self.central?.stopScan()
            self.devices.removeAll()
            self.publishStatus(.idle)
        }
    }

    private func resumeScan() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [
            // 不打开这个的话，同一个设备只在「广播内容变了」时才回调，
            // 而手表的广播内容基本不变 → RSSI 永远停在第一帧，判定就成了摆设。
            CBCentralManagerScanOptionAllowDuplicatesKey: true,
        ])
        publishStatus(.scanning)
        log("开始扫描 BLE 广播")
    }

    private func publishStatus(_ status: ProximitySignalStatus) {
        guard status != lastStatus else { return }
        lastStatus = status
        log("蓝牙状态 → \(status)")
        DispatchQueue.main.async { self.onStatusChange?(status) }
    }

    private func publishDevices(at time: TimeInterval) {
        guard time - lastPublish >= publishInterval else { return }
        lastPublish = time
        devices = devices.filter { time - $0.value.lastSeen <= pruneInterval }
        let sorted = devices.values
            .sorted { $0.rssi > $1.rssi }
            .prefix(maxListedDevices)
            .map { $0 }
        DispatchQueue.main.async { self.onDevices?(Array(sorted)) }
    }
}

extension BluetoothProximityScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            resumeScan()
        case .unauthorized:
            publishStatus(.unauthorized)
        case .poweredOff:
            publishStatus(.poweredOff)
        case .unsupported:
            publishStatus(.unsupported)
        default:
            publishStatus(.idle)
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let time = now()
        let id = peripheral.identifier.uuidString
        let rssi = RSSI.intValue
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""

        devices[id] = ProximityDevice(id: id, name: name, rssi: rssi, lastSeen: time)
        publishDevices(at: time)

        guard targetDeviceID == id else { return }
        DispatchQueue.main.async {
            self.onSample?(ProximitySample(deviceID: id, rssi: rssi, time: time))
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToStartScanning error: Error?) {
        log("扫描启动失败：\(error?.localizedDescription ?? "未知错误")")
        publishStatus(.idle)
    }
}
