//
//  RemoteScreenStreamer.swift
//  MacStroke
//
//  桌面回显的推流循环：一台定时器抓屏编码，分发给所有开了回显的手机。
//
//  所有状态只在服务端那条串行队列上读写（订阅、改参数、发帧、断开都在那里），
//  所以这里不加锁。抓屏 + 缩放 + JPEG 编码实测十几毫秒，3 fps 占队列不到 5%，
//  为它单开一条队列反倒要把订阅表做成线程安全的，不划算。
//
//  生命周期由调用方管：有人开 mirror 就 subscribe，关掉或断线就 unsubscribe，
//  一个订阅者都不剩时定时器自己停掉，不空转烧 CPU 也不让屏幕一直醒着。
//

import Foundation

final class RemoteScreenStreamer {
    /// 一台手机的订阅状态。`send` 由服务端给出，回调负责把字节写进那条连接。
    private final class Subscriber {
        var request: RemoteMirrorRequest
        var send: (Data, @escaping () -> Void) -> Void
        /// 上一帧还压在 socket 里没写完。
        var inFlight = false

        init(request: RemoteMirrorRequest, send: @escaping (Data, @escaping () -> Void) -> Void) {
            self.request = request
            self.send = send
        }
    }

    private let queue: DispatchQueue
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval?
    private var sequence = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// 开了就一直在推，所以「改参数」和「重复开」都走同一条路：更新订阅、必要时换节拍。
    func subscribe(_ key: ObjectIdentifier, request: RemoteMirrorRequest,
                   send: @escaping (Data, @escaping () -> Void) -> Void) {
        if let existing = subscribers[key] {
            existing.request = request
            existing.send = send
        } else {
            subscribers[key] = Subscriber(request: request, send: send)
        }
        reschedule()
    }

    func unsubscribe(_ key: ObjectIdentifier) {
        guard subscribers.removeValue(forKey: key) != nil else { return }
        reschedule()
    }

    /// 关掉远程控制服务时用：订阅全清，定时器一起停。
    func unsubscribeAll() {
        guard !subscribers.isEmpty else { return }
        subscribers.removeAll()
        reschedule()
    }

    /// 多台设备时取最贪心的一组参数，编一次大家共用：来控制的本来就一两台，
    /// 给每台各编一份尺寸是白烧 CPU，大画面发给小屏也只是多花点带宽。
    private var aggregated: RemoteMirrorRequest? {
        let requests = subscribers.values.map { $0.request }
        guard let first = requests.first else { return nil }
        return RemoteMirrorRequest(
            on: true,
            maxWidth: requests.map { $0.maxWidth }.max() ?? first.maxWidth,
            fps: requests.map { $0.fps }.max() ?? first.fps,
            quality: requests.map { $0.quality }.max() ?? first.quality
        ).clamped
    }

    private func reschedule() {
        guard let config = aggregated else {
            timer?.cancel()
            timer = nil
            interval = nil
            return
        }
        let next = 1.0 / Double(config.fps)
        guard interval != next else { return }
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + next, repeating: next, leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        interval = next
        source.resume()
    }

    private func tick() {
        guard let config = aggregated else { return }
        guard let frame = RemoteScreenCapture.capture(maxWidth: config.maxWidth,
                                                      quality: config.quality) else { return }
        sequence += 1
        let line = RemoteCommand.frameLine(seq: sequence, width: frame.width,
                                           height: frame.height, jpeg: frame.jpeg)
        for subscriber in subscribers.values {
            // 背压：上一帧还没写进 socket 就把这一帧丢掉，绝不排队。排队会在链路上
            // 攒出一串过期画面，手机看到的永远是几秒前的桌面，手指点下去全错位。
            guard !subscriber.inFlight else { continue }
            subscriber.inFlight = true
            subscriber.send(line) { [weak self] in
                // 回调可能迟到在这台手机已经取消订阅之后，那时对象已无人引用，
                // 改它的标记不影响任何人，省掉一次按身份回查。
                self?.queue.async { subscriber.inFlight = false }
            }
        }
    }
}
