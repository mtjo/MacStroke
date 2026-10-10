// 远程控制服务的端到端取证：真的起监听、真的用 TCP 客户端连上去走一遍协议。
//
// 连 127.0.0.1 是本地的快捷做法（只有微信小程序禁止连本机，服务端绑的是所有网卡）。
//
// 关键约束：服务端把 welcome / ack 都丢回主队列执行（合成点击要和手势 tap 串行），
// 而 XCTest 用例正占着主线程。所以整段对话跑在后台线程，主线程只管抽干主队列，
// 断言仍留在主线程。
//
// 真实点击会落到光标底下那个窗口上，除「按住后掉线」那条外都不合成点击——
// 完整点击链路留给手机扫码实测。
import XCTest
import Foundation
import Darwin
import CoreGraphics
import ImageIO
@testable import RemoteControl

/// 端口和配对码是文件级常量：@escaping 的对话闭包里引用实例属性要写 self.，
/// 而闭体长得像协议报文，加前缀只是噪音。
private let testPort = 48849
private let testToken = "TESTAB"

final class RemoteControlServerE2ETests: XCTestCase {
    private var server: RemoteControlServer { .shared }

    override func setUp() {
        super.setUp()
        server.apply(RemoteControlSettings(enabled: true, port: testPort, token: testToken))
        waitForListening()
    }

    override func tearDown() {
        server.apply(RemoteControlSettings(enabled: false, port: testPort, token: ""))
        // stop() 是异步的：不等它真的落定，下一条用例的 apply() 会看到还是
        // isRunning == true 而跳过重新监听，端口就空了。
        waitUntil(timeout: 3) { self.server.isRunning == false }
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - 协议往返

    func testWelcomeArrivesAfterAValidHello() throws {
        let welcome = try converse { pipe in
            try pipe.send(#"{"t":"hello","token":"TESTAB","name":"iPhone"}"#)
            return try pipe.readJSON()
        }

        XCTAssertEqual(welcome["t"] as? String, "welcome")
        XCTAssertEqual(welcome["ok"] as? Bool, true)
        XCTAssertEqual(welcome["proto"] as? Int, RemoteCommand.revision)
        XCTAssertNotNil(welcome["screen"], "welcome 要带上屏幕尺寸，手机端才能换算摇杆量")
        XCTAssertNotNil(welcome["cursor"])
    }

    func testWrongTokenClosesTheConnection() throws {
        let (reply, eof) = try converse { pipe in
            try pipe.send(#"{"t":"hello","token":"WRONG1"}"#)
            let reply = try pipe.readJSON()
            return (reply, try pipe.readRaw())
        }

        XCTAssertEqual(reply["t"] as? String, "error")
        XCTAssertEqual(reply["code"] as? String, "badToken")
        XCTAssertNotNil(reply["message"], "错误回复要带中文说明，手机端直接显示")
        XCTAssertEqual(eof, "", "配对失败后必须断开，不能留着继续套屏幕坐标")
    }

    func testCommandBeforeHelloIsRejected() throws {
        let reply = try converse { pipe in
            try pipe.send(#"{"t":"click","btn":"left"}"#)
            return try pipe.readJSON()
        }

        XCTAssertEqual(reply["t"] as? String, "error")
        XCTAssertEqual(reply["code"] as? String, "notAuthenticated")
    }

    func testPingIsAcked() throws {
        let ack = try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()          // welcome
            try pipe.send(#"{"t":"ping"}"#)
            return try pipe.readJSON()
        }

        XCTAssertEqual(ack["t"] as? String, "ack")
        XCTAssertEqual(ack["cmd"] as? String, "ping")
    }

    /// 一次 write 里塞两行：分帧要按换行切开，每条都要有回执。
    func testTwoCommandsInOneWriteAreBothHandled() throws {
        let acks = try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"ping"}"# + "\n" + #"{"t":"ping"}"#)
            return [try pipe.readJSON(), try pipe.readJSON()]
        }

        XCTAssertEqual(acks.map { $0["cmd"] as? String }, ["ping", "ping"])
    }

    /// 真移动一次光标：手机端摇杆的主链路，只靠解析单测证明不了它落到了系统。
    func testMoveActuallyRelocatesTheCursor() throws {
        let before = RemoteClickExecutor.state()
        // 朝屏幕内侧移动：贴边时服务端会夹到屏幕边界，断言就会假失败。
        let dx = before.cursor.x < before.size.w / 2 ? 40.0 : -40.0
        let dy = before.cursor.y < before.size.h / 2 ? 30.0 : -30.0

        let ack = try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"move","dx":\#(Int(dx)),"dy":\#(Int(dy))}"#)
            return try pipe.readJSON()
        }

        XCTAssertEqual(ack["cmd"] as? String, "move")
        let after = RemoteClickExecutor.state()
        XCTAssertEqual(after.cursor.x, before.cursor.x + dx, accuracy: 1,
                       "光标要真的被挪走，而不只是回一个 ack")
        XCTAssertEqual(after.cursor.y, before.cursor.y + dy, accuracy: 1)
        let reportedX = try XCTUnwrap((ack["cursor"] as? [String: Double])?["x"])
        XCTAssertEqual(reportedX, after.cursor.x, accuracy: 1,
                       "回执里的坐标要等于系统当下的真实位置")

        // 放回原处，别影响后面的用例和用户手里的鼠标。
        try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"move","dx":\#(Int(-dx)),"dy":\#(Int(-dy))}"#)
            _ = try pipe.readJSON()
        }
        XCTAssertEqual(RemoteClickExecutor.state().cursor.x, before.cursor.x, accuracy: 1)
    }

    // MARK: - 触屏模式

    /// 绝对坐标：手机点哪儿光标就落哪儿，越界是夹住而不是拒绝。
    func testWarpMovesTheCursorToAnAbsolutePoint() throws {
        let before = RemoteClickExecutor.state()
        let size = before.size

        let ack = try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"warp","x":0.25,"y":0.75}"#)
            return try pipe.readAck(cmd: "warp")
        }
        XCTAssertNil(ack["cursor"], "手机知道自己点在哪，回执再带一次坐标就是浪费带宽")

        let after = RemoteClickExecutor.state()
        XCTAssertEqual(after.cursor.x, (size.w - 1) * 0.25, accuracy: 1,
                       "归一化坐标要真的摊到主屏像素上")
        XCTAssertEqual(after.cursor.y, (size.h - 1) * 0.75, accuracy: 1)

        // 缩放边界上算出 1.0004 是常态：夹进屏幕，别断连也别报错。
        try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"warp","x":2,"y":-1}"#)
            _ = try pipe.readAck(cmd: "warp")
        }
        let clamped = RemoteClickExecutor.state()
        XCTAssertEqual(clamped.cursor.x, size.w - 1, accuracy: 1)
        XCTAssertEqual(clamped.cursor.y, 0, accuracy: 1)

        // 把用户的指针放回原处。
        try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"warp","x":\#(before.cursor.x / max(size.w - 1, 1)),"y":\#(before.cursor.y / max(size.h - 1, 1))}"#)
            _ = try pipe.readAck(cmd: "warp")
        }
        XCTAssertEqual(RemoteClickExecutor.state().cursor.x, before.cursor.x, accuracy: 2)
    }

    /// 回显开关的完整往返：不开就一帧都不来（反向对照），开了要收到真能解码的桌面帧，
    /// 关掉之后必须彻底静默。
    ///
    /// 参数刻意用 w=320 fps=5：窗口短、帧小，断言跑得快，也顺手证明夹取之外的
    /// 自定义尺寸真的被服务端采纳了。
    func testMirrorFramesFollowTheSwitch() throws {
        guard RemoteScreenCapture.hasScreenRecordingPermission() else {
            throw XCTSkip("测试进程没有「屏幕录制」权限，服务端此时只会回 noScreenPermission")
        }
        let displaySize = RemoteClickExecutor.state().size

        let outcome = try converse { pipe -> MirrorEvidence in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()

            // 反向对照：先只 ping，确认没人开回显时真的一帧都没有。
            try pipe.send(#"{"t":"ping"}"#)
            _ = try pipe.readAck(cmd: "ping")
            let beforeOn = try pipe.collectFrames(window: 1.0)

            try pipe.send(#"{"t":"mirror","on":true,"w":320,"fps":5,"q":40}"#)
            _ = try pipe.readAck(cmd: "mirror")
            let first = try pipe.readFrame()
            // 第二帧用来验序号真的在往前走，而不是同一帧被反复重发。
            let second = try pipe.readFrame()
            let whileOn = try pipe.collectFrames(window: 1.0)

            try pipe.send(#"{"t":"mirror","on":false}"#)
            _ = try pipe.readAck(cmd: "mirror")
            // 已经压在链路里的那一帧容许迟到半秒，先把它冲掉再要静默窗口。
            usleep(400_000)
            _ = try pipe.collectFrames(window: 0.6)
            let afterOff = try pipe.collectFrames(window: 1.4)

            return MirrorEvidence(beforeOn: beforeOn.count, first: first, second: second,
                                  whileOn: whileOn.count, afterOff: afterOff.count)
        }

        XCTAssertEqual(outcome.beforeOn, 0, "没发 mirror 就不该推任何帧")
        XCTAssertLessThanOrEqual(outcome.first.width, 320, "手机要的宽度服务端要认")
        XCTAssertEqual(CGFloat(outcome.first.height) / CGFloat(outcome.first.width),
                       displaySize.h / displaySize.w, accuracy: 0.02,
                       "帧必须是整屏等比缩下来的，不然手机上点的位置对不上")
        XCTAssertGreaterThan(outcome.second.seq, outcome.first.seq, "序号要单调递增")
        XCTAssertGreaterThanOrEqual(outcome.whileOn, 2, "5 fps 的一秒窗口里至少该有两帧")
        XCTAssertEqual(outcome.afterOff, 0, "关掉回显之后还在推流")

        let jpeg = outcome.first.jpeg
        let decoded = try XCTUnwrap(
            CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
            "帧里的字节解不出图像，手机端只会看到一个灰块")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil)
                                       as? [CFString: Any])
        XCTAssertNotNil(properties[kCGImagePropertyWidth], "JPEG 里没有尺寸信息")
    }

    /// 没有屏幕录制权限时，服务端要把话说明白并且一个字节画面都不推。
    /// 权限是环境状态，这里只断言「有权限时不该走这条分支」这一半。
    func testMirrorWithoutPermissionIsAnExplicitError() throws {
        try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"mirror","on":true}"#)
            guard !RemoteScreenCapture.hasScreenRecordingPermission() else {
                // 有权限：这条分支走不到，确认它真的在推流而不是空报一个错。
                _ = try pipe.readAck(cmd: "mirror")
                _ = try pipe.readFrame()
                try pipe.send(#"{"t":"mirror","on":false}"#)
                return
            }
            let reply = try pipe.readJSON()
            XCTAssertEqual(reply["t"] as? String, "error")
            XCTAssertEqual(reply["code"] as? String, "noScreenPermission")
            XCTAssertNotNil(reply["message"] as? String, "手机端要能直接把这句话给用户看")
            XCTAssertEqual(try pipe.collectFrames(window: 1.0).count, 0)
        }
    }

    // MARK: - 驱动

    /// 双指滚动：服务端要真的往 session 里丢一条滚轮事件，并把手机给的像素增量
    /// 原样带进事件字段。内容到底滚多少是窗口服务器的事，这里只证明报文发对了。
    func testScrollPostsAWheelEventWithTheGivenDelta() throws {
        let log = WheelLog()
        guard let tap = log.start() else {
            throw XCTSkip("测试进程没有权限挂事件 tap（辅助功能未授权）")
        }
        defer { log.stop(tap: tap) }

        let ack = try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"scroll","dx":6,"dy":-120}"#)
            return try pipe.readJSON()
        }

        XCTAssertEqual(ack["t"] as? String, "ack")
        XCTAssertEqual(ack["cmd"] as? String, "scroll")
        XCTAssertNil(ack["cursor"], "滚动不动指针，回执不该再带坐标浪费带宽")

        waitUntil(timeout: 1) { log.events > 0 }
        XCTAssertEqual(log.events, 1, "事件 tap 没抓到滚轮事件，用例无法证明任何事")
        // 实测（2026-10-09）：像素单位的事件会把原值放进 point 场，同时按
        // 10px/行折出行场，两条读法（scrollingDeltaY 与 deltaY）都拿得到数。
        XCTAssertEqual(log.lastPoint1, -120, "像素增量要原样落在 point 场上")
        XCTAssertEqual(log.lastAxis1, -12, "同一个值折算成行是 12 行")
        XCTAssertEqual(log.lastPoint2, 6)
        XCTAssertEqual(log.lastAxis2, 1, "6px 折成 1 行")
        XCTAssertEqual(log.lastContinuous, 1, "连续标记决定 AppKit 按像素读还是按行读")
    }

    /// 按住左键后手机掉线：服务端必须自己补一个松开，否则 Mac 卡在拖拽状态，
    /// 用户只能狂点鼠标才解得开。
    ///
    /// 取证用只读事件 tap 直接数左键的 down/up，不看系统按钮状态：
    /// XCTest 宿主里 `CGEventSource.buttonState` 恒为 false（无 GUI 连接，读不到
    /// 服务端那份状态表），拿它当判据会假绿。
    func testDroppingWhileHoldingReleasesTheButton() throws {
        let log = MouseButtonLog()
        guard let tap = log.start() else {
            throw XCTSkip("测试进程没有权限挂事件 tap（辅助功能未授权）")
        }
        defer { log.stop(tap: tap) }

        try converse { pipe in
            try pipe.hello(token: testToken)
            _ = try pipe.readJSON()
            try pipe.send(#"{"t":"button","btn":"left","down":true}"#)
            _ = try pipe.readJSON()
            pipe.close()               // 模拟手机断网/杀进程
        }

        // tap 真的看得见合成事件，否则下面的断言就是空转。
        waitUntil(timeout: 1) { log.leftDowns > 0 }
        XCTAssertGreaterThan(log.leftDowns, 0, "事件 tap 没抓到按下，用例无法证明任何事")

        let upsBeforeRelease = log.leftUps
        waitUntil(timeout: 2) { log.leftUps > upsBeforeRelease }
        XCTAssertGreaterThan(log.leftUps, upsBeforeRelease,
                             "掉线之后左键还按着，Mac 会一直停在拖拽里")
    }

    /// 整段对话跑在后台线程，主线程抽干主队列让服务端得以回执。
    @discardableResult
    private func converse<T>(_ script: @escaping (ClientPipe) throws -> T) throws -> T {
        let pipe = ClientPipe(port: testPort)
        var result: T?
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try pipe.open()
                result = try script(pipe)
            } catch {
                failure = error
            }
            pipe.close()
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }

    private func waitForListening() {
        let deadline = Date().addingTimeInterval(3)
        let probe = ClientPipe(port: testPort)
        while Date() < deadline {
            if (try? probe.open()) != nil {
                probe.close()
                return
            }
            usleep(50_000)
        }
        probe.close()
        XCTFail("服务没有在 \(testPort) 端口起来")
    }
}

/// 一条连接上收到的一次「回显往返」的全部计数，一次带回 converse 闭包，
/// 断言留在主线程里写，免得把它们埋在闭包中看不清顺序。
private struct MirrorEvidence {
    var beforeOn: Int
    var first: (seq: Int, width: Int, height: Int, jpeg: Data)
    var second: (seq: Int, width: Int, height: Int, jpeg: Data)
    var whileOn: Int
    var afterOff: Int
}

/// 同步的测试用客户端：一行一条 JSON，读满一个换行为止。
private final class ClientPipe {
    private let port: Int
    private var fd: Int32 = -1
    private var pending = Data()
    private var scratch = [UInt8](repeating: 0, count: 16 * 1024)

    init(port: Int) { self.port = port }

    func open() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            Darwin.close(socket)
            throw POSIXError(.ECONNREFUSED)
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = socket
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    func hello(token: String) throws {
        try send(#"{"t":"hello","token":"\#(token)"}"#)
    }

    func send(_ line: String) throws {
        var payload = Data(line.utf8)
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, payload.count, "命令没写完整")
    }

    /// 读到换行为止；对端关闭或超时且没有完整行时返回空串。
    /// 一次读满一缓冲区再找换行：回显帧一行就有几十 KB，逐字节 read 会慢到测不出真相。
    func readRaw() throws -> String {
        while true {
            if let index = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<index)
                pending.removeSubrange(pending.startIndex...index)
                return String(decoding: line, as: UTF8.self)
            }
            let read = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if read <= 0 { return "" }
            pending.append(contentsOf: scratch[0..<read])
        }
    }

    func readJSON() throws -> [String: Any] {
        let line = try readRaw()
        XCTAssertFalse(line.isEmpty, "没读到回执行")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    /// 读到指定 cmd 的 ack 为止；推流一旦起来，报文顺序就不再由我们保证了，
    /// 中途撞上的帧直接跳过。
    func readAck(cmd: String) throws -> [String: Any] {
        while true {
            let object = try readJSON()
            if (object["t"] as? String) == "ack", object["cmd"] as? String == cmd { return object }
            if (object["t"] as? String) == "frame" { continue }
            return object
        }
    }

    /// 换一次读超时：负向断言（「这一段时间里不该再来帧」）必须用短超时，
    /// 不然默认 5 秒的阻塞读会把窗口拖成 5 秒还在猜。
    func setReadTimeout(_ seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 在 `window` 这段时间里数收到几条 `{"t":"frame"}`，顺带把每条的报文交出来。
    func collectFrames(window: TimeInterval) throws -> [[String: Any]] {
        setReadTimeout(1)
        var frames: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            guard let line = try readRaw().nonEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if object["t"] as? String == "frame" { frames.append(object) }
        }
        setReadTimeout(5)
        return frames
    }

    /// 读一条帧并解出 JPEG 字节；不是帧就当场失败，免得断言跑偏。
    func readFrame() throws -> (seq: Int, width: Int, height: Int, jpeg: Data) {
        let object = try readJSON()
        XCTAssertEqual(object["t"] as? String, "frame", "收到的不是帧：\(object)")
        let base64 = try XCTUnwrap(object["jpg"] as? String, "帧里没有 base64 图像")
        return (try XCTUnwrap(object["i"] as? Int),
                try XCTUnwrap(object["w"] as? Int),
                try XCTUnwrap(object["h"] as? Int),
                try XCTUnwrap(Data(base64Encoded: base64), "帧里的 base64 解不开"))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// 只读事件 tap：数左键的按下与松开，用来证明服务端真的补发了松开。
/// 计数器只能在 C 回调里写，所以靠 userInfo 传实例指针。
private final class MouseButtonLog {
    private(set) var leftDowns = 0
    private(set) var leftUps = 0

    func start() -> CFMachPort? {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: MouseButtonLog.onEvent,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    func stop(tap: CFMachPort) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    private static let onEvent: CGEventTapCallBack = { _, type, event, userInfo in
        if let userInfo {
            let log = Unmanaged<MouseButtonLog>.fromOpaque(userInfo).takeUnretainedValue()
            switch type {
            case .leftMouseDown: log.leftDowns += 1
            case .leftMouseUp: log.leftUps += 1
            default: break
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

/// 只读事件 tap：抓滚轮事件各场的值，证明服务端发出的报文没被中途改写。
private final class WheelLog {
    private(set) var events = 0
    private(set) var lastAxis1 = 0
    private(set) var lastAxis2 = 0
    private(set) var lastPoint1 = 0
    private(set) var lastPoint2 = 0
    private(set) var lastContinuous = -1

    func start() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: WheelLog.onEvent,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    func stop(tap: CFMachPort) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    private static let onEvent: CGEventTapCallBack = { _, type, event, userInfo in
        if type == .scrollWheel, let userInfo {
            let log = Unmanaged<WheelLog>.fromOpaque(userInfo).takeUnretainedValue()
            log.events += 1
            log.lastAxis1 = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            log.lastAxis2 = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            log.lastPoint1 = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            log.lastPoint2 = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            log.lastContinuous = Int(event.getIntegerValueField(.scrollWheelEventIsContinuous))
        }
        return Unmanaged.passUnretained(event)
    }
}
