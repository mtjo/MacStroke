// 远程控制服务的端到端取证：真的起监听、真的用 TCP 客户端连上去走一遍协议。
//
// 连 127.0.0.1 是本地的快捷做法（只有微信小程序禁止连本机，服务端绑的是所有网卡）。
//
// 关键约束：服务端把 welcome / ack 都丢回主队列执行（合成点击要和手势 tap 串行），
// 而 XCTest 用例正占着主线程。所以整段对话跑在后台线程，主线程只管抽干主队列，
// 断言仍留在主线程。
//
// 真实点击会落到光标底下那个窗口上，测试里不合成点击——那条链路留给手机扫码实测。
import XCTest
import Foundation
import Darwin
@testable import RemoteControl

/// 端口和配对码是文件级常量：@escaping 的对话闭包里引用实例属性要写 self.，
/// 而闭体长得像协议报文，加前缀只是噪音。
private let testPort = 48848
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

    // MARK: - 驱动

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

/// 同步的测试用客户端：一行一条 JSON，读满一个换行为止。
private final class ClientPipe {
    private let port: Int
    private var fd: Int32 = -1

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

    /// 读到换行为止；对端关闭且没有内容时返回空串。
    func readRaw() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 1)
        var text = ""
        while Darwin.read(fd, &bytes, 1) == 1 {
            if bytes[0] == 0x0A { break }
            text.append(Character(UnicodeScalar(bytes[0])))
        }
        return text
    }

    func readJSON() throws -> [String: Any] {
        let line = try readRaw()
        XCTAssertFalse(line.isEmpty, "没读到回执行")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}
