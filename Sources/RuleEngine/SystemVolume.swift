//
//  SystemVolume.swift
//  MacStroke
//
//  issue #75 的音量档：直接读写默认输出设备的标量音量。
//
//  为什么不是「投一发多媒体键」：本机实测（2026-10-24，/tmp/volumeprobe2.swift）把
//  NX_NVMEDIAKEY_UP 那几条配方（session / HID、data1 的几种摆法、`NSEvent.systemDefined`
//  包一层）全投了一遍，音量读数一个像素都没动 —— 媒体键要走 DSEvent/ControlCenter 那条
//  私有线，命令行进程投不动。对照 instrumentation 自查（osascript 把音量从 34 抬到 44
//  确实动了）证明尺子是好的。CoreAudio 这条路实测能落地（/tmp/volumeprobe3.swift：
//  0.34363854 → 0.3996565 → 复位，状态 0），所以本功能走 CoreAudio。
//
//  一个现场坑：本机默认输出设备的 `kAudioObjectPropertyElementMain` 这一档报
//  `unknown property`（'who?'），音量挂在**声道 1/2** 上。所以先问 Main、问不到再逐声道，
//  两条设备形态（虚拟设备带 Main 汇总档 / 实体设备只有分声道）都能落地。
//

import Foundation
import CoreAudio

/// 系统音量读写。全是静态函数：本机只有一个默认输出设备，没必要造对象。
public enum SystemVolume {

    /// 一格滚轮的默认增减量（0…1 标度）。与 `WheelGesturePlan.volumeStep` 同值，
    /// 两边各自留一份是为了这层不依赖查表那侧；改档位时改 `WheelGesturePlan`。
    static let defaultStep: Double = 0.05

    // MARK: - 接缝

    /// 属性读写全走这两个闭包，单测才能在不碰真音量的前提下钉「读不到 / 越界钳位 /
    /// 一个声道失败另一个照走」。生产为 nil = 用下面的 CoreAudio 实现。
    public static var propertyReader: ((AudioDeviceID, UInt32) -> Double?)?
    public static var propertyWriter: ((AudioDeviceID, UInt32, Double) -> Bool)?

    /// 默认输出设备 id 也可以换掉：无输出设备（headless / 刚拔了耳机）时读不到设备，
    /// 本层必须老实返回 false，让调用方把滚轮事件交回前台应用。
    public static var defaultDeviceReader: (() -> AudioDeviceID?)?

    /// 「这一档到底有没有音量属性」也能换掉。不换的话待试的档位列表跟着本机设备形态走
    /// （虚拟设备只有 Main、实体设备只有分声道、没插输出设备一个都没有），用例钉不住。
    public static var propertyPresenceChecker: ((AudioDeviceID, UInt32) -> Bool)?

    // MARK: - 对外

    /// 当前音量（0…1）。读不出来返回 nil。
    public static func current(device: AudioDeviceID? = nil) -> Double? {
        guard let device = device ?? currentDevice() else { return nil }
        let channels = volumeChannels(of: device)
        for channel in channels {
            if let value = read(device, channel) { return value }
        }
        return nil
    }

    /// 抬/降一档，钳在 0…1。至少一个声道写成功就算做成。
    /// - Returns: 是否真的动了
    @discardableResult
    public static func step(by delta: Double, device: AudioDeviceID? = nil) -> Bool {
        guard delta != 0 else { return false }
        guard let device = device ?? currentDevice() else {
            NSLog("%@", "[SystemVolume] 没有默认输出设备")
            return false
        }
        var didWrite = false
        for channel in volumeChannels(of: device) {
            guard let before = read(device, channel) else { continue }
            let after = min(max(before + delta, 0), 1)
            guard after != before else {
                // 已经在 0 或 1 头上：这一档写不动，但整件事仍是「配了动作」，
                // 不能因为到底了就退回去滚页面。
                didWrite = true
                continue
            }
            if write(device, channel, after) { didWrite = true }
        }
        return didWrite
    }

    /// 钳到 0…1 后直接设定（给「点一下恢复默认」这类留手，本功能暂时用不到）。
    @discardableResult
    public static func set(_ value: Double, device: AudioDeviceID? = nil) -> Bool {
        guard let device = device ?? currentDevice() else { return false }
        let clamped = min(max(value, 0), 1)
        var didWrite = false
        for channel in volumeChannels(of: device) {
            if write(device, channel, clamped) { didWrite = true }
        }
        return didWrite
    }

    // MARK: - CoreAudio

    /// 默认输出设备。0 = 没有（没插扬声器 / 全被弹出）。
    static func currentDevice() -> AudioDeviceID? {
        if let reader = defaultDeviceReader { return reader() }
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var id = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != 0 else { return nil }
        return id
    }

    /// 要试的档位：Main 在前（虚拟/聚合设备只有它），随后声道 1…8，只留有音量属性的那些。
    /// 逐声道而非查 stream configuration：后者要解析 `AudioBufferList`，而这台机器
    /// 实测就是 1/2 两档，多试几档的代价只是几次 `AudioObjectHasProperty`。
    static func volumeChannels(of device: AudioDeviceID) -> [UInt32] {
        let candidates: [UInt32] = [kAudioObjectPropertyElementMain] + Array(1...8)
        return candidates.filter { channel in
            if let checker = propertyPresenceChecker { return checker(device, channel) }
            var address = address(channel)
            return AudioObjectHasProperty(device, &address)
        }
    }

    private static func address(_ channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: channel)
    }

    private static func read(_ device: AudioDeviceID, _ channel: UInt32) -> Double? {
        if let reader = propertyReader { return reader(device, channel) }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = address(channel)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? Double(value) : nil
    }

    private static func write(_ device: AudioDeviceID, _ channel: UInt32, _ value: Double) -> Bool {
        if let writer = propertyWriter { return writer(device, channel, value) }
        var scalar = Float32(value)
        var address = address(channel)
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &scalar) == noErr
    }
}
