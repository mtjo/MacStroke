import XCTest
import AppKit
import Storage
@testable import RemoteControl

/// 协议解析：小程序那边只能发字符串，服务端必须对坏包有明确回话而不是断连。
final class RemoteCommandParsingTests: XCTestCase {
    func testHelloUpperCasesTheTokenAndKeepsDeviceName() {
        XCTAssertEqual(
            RemoteCommand.parse(line: #"{"t":"hello","token":"ab12cd","name":"iPhone 14"}"#),
            .command(.hello(token: "AB12CD", deviceName: "iPhone 14"))
        )
    }

    func testPingMoveClickAndButton() {
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"ping"}"#), .command(.ping))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"move","dx":12.5,"dy":-8}"#),
                       .command(.move(dx: 12.5, dy: -8)))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"click","btn":"right","double":true}"#),
                       .command(.click(button: .right, doubleClick: true)))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"button","btn":"middle","down":false}"#),
                       .command(.button(button: .middle, pressed: false)))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"scroll","dx":0,"dy":-40}"#),
                       .command(.scroll(dx: 0, dy: -40)))
    }

    /// 省略 btn 就是左键：小程序的主按钮不必带字段。
    func testClickWithoutButtonDefaultsToLeft() {
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"click"}"#),
                       .command(.click(button: .left, doubleClick: false)))
    }

    func testStringifiedNumbersAreAccepted() {
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"move","dx":"30","dy":"-4"}"#),
                       .command(.move(dx: 30, dy: -4)))
    }

    /// 触屏页只发主屏归一化坐标：它不知道也不需要知道这台 Mac 是 1440 还是 3025 宽。
    func testWarpTakesNormalizedCoordinates() {
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"warp","x":0.42,"y":0.66}"#),
                       .command(.warp(x: 0.42, y: 0.66)))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"warp","x":"0.5","y":0}"#),
                       .command(.warp(x: 0.5, y: 0)))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"warp","x":0.5}"#), .error(.malformed))
    }

    /// 回显参数全省略就是默认那组；越界不报错而是夹到能用的边界——
    /// 手机端写错数字不该断连，也不该把 Mac 拖去跑 60 fps 全屏编码。
    func testMirrorDefaultsAndClamping() {
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"mirror","on":true}"#),
                       .command(.mirror(RemoteMirrorRequest(on: true))))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"mirror","on":true,"w":640,"fps":5,"q":60}"#),
                       .command(.mirror(RemoteMirrorRequest(on: true, maxWidth: 640, fps: 5, quality: 60))))
        let squeezed = RemoteMirrorRequest(on: true, maxWidth: 50, fps: 600, quality: 100).clamped
        XCTAssertEqual(squeezed.maxWidth, 320)
        XCTAssertEqual(squeezed.fps, 10)
        XCTAssertEqual(squeezed.quality, 90)
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"mirror","on":true,"w":99999,"fps":0,"q":0}"#),
                       .command(.mirror(RemoteMirrorRequest(on: true, maxWidth: 1920, fps: 1, quality: 10))))
    }

    func testMalformedAndUnknownPackets() {
        XCTAssertEqual(RemoteCommand.parse(line: ""), .error(.malformed))
        XCTAssertEqual(RemoteCommand.parse(line: "not json"), .error(.malformed))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"move","dx":1}"#), .error(.malformed))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"click","btn":"side4"}"#), .error(.malformed))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"scroll","dx":3}"#), .error(.malformed))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"t":"zoom","x":10,"y":20}"#), .error(.unknownCommand))
        XCTAssertEqual(RemoteCommand.parse(line: #"{"dx":1,"dy":2}"#), .error(.malformed))
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(RemoteCommand.parse(line: "  {\"t\":\"ping\"}\r\n"), .command(.ping))
    }

    func testButtonNumbersMatchTheReplayLayer() {
        XCTAssertEqual(RemoteMouseButton.left.cgNumber, 0)
        XCTAssertEqual(RemoteMouseButton.right.cgNumber, 1)
        XCTAssertEqual(RemoteMouseButton.middle.cgNumber, 2)
    }
}

final class RemoteReplyEncodingTests: XCTestCase {
    private func jsonObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testReplyDropsNilFields() {
        let reply = RemoteCommand.reply(type: "ack", fields: ["cmd": "ping", "cursor": nil])
        let object = jsonObject(reply)
        XCTAssertEqual(object["t"] as? String, "ack")
        XCTAssertEqual(object["cmd"] as? String, "ping")
        XCTAssertNil(object["cursor"], "没有光标信息时不能发 null，小程序会当有效值读")
    }

    func testErrorReplyCarriesCodeAndMessage() {
        let object = jsonObject(RemoteCommand.errorReply(.badToken))
        XCTAssertEqual(object["t"] as? String, "error")
        XCTAssertEqual(object["code"] as? String, "badToken")
        XCTAssertNotNil(object["message"] as? String)
    }
}

/// 端口规则：微信 TCP 的黑名单是硬限制，选了黑名单端口等于服务对外不存在。
final class RemotePortRulesTests: XCTestCase {
    func testLowPortsRejected() {
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(80))
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(1023))
        XCTAssertTrue(RemoteControlSettings.isPortAllowed(1024))
    }

    func testKnownBlacklistPortsRejected() {
        for port in RemoteControlSettings.blacklistedPorts {
            XCTAssertFalse(RemoteControlSettings.isPortAllowed(port), "端口 \(port) 在微信黑名单里")
        }
    }

    func testBlacklistedRangesRejected() {
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(8000))
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(8050))
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(8100))
        XCTAssertTrue(RemoteControlSettings.isPortAllowed(8101))
    }

    func testDefaultPortIsUsable() {
        XCTAssertTrue(RemoteControlSettings.isPortAllowed(StorageDefaults.remoteControlPort))
    }

    func testOutOfRangePortsRejected() {
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(0))
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(-1))
        XCTAssertFalse(RemoteControlSettings.isPortAllowed(65536))
    }
}

final class RemoteTokenTests: XCTestCase {
    func testTokenShape() {
        let token = RemoteControlSettings.makeToken()
        XCTAssertEqual(token.count, 6)
        XCTAssertTrue(token.allSatisfy { "ABCDEFGHJKMNPQRSTUVWXYZ23456789".contains($0) },
                      "配对码要能手敲，不能含 I/L/O/0/1 这类易混字符")
    }

    func testTokensAreNotReused() {
        let tokens = Set((0..<200).map { _ in RemoteControlSettings.makeToken() })
        XCTAssertGreaterThan(tokens.count, 150, "随机配对码不该频繁撞车")
    }
}

final class RemoteClickExecutorMathTests: XCTestCase {
    private let size = RemoteScreenSize(w: 1920, h: 1080)

    func testMoveAddsTheDelta() {
        let target = RemoteClickExecutor.moveTarget(from: RemoteScreenPoint(x: 500, y: 400),
                                                    size: size, dx: 120, dy: -60)
        XCTAssertEqual(target, CGPoint(x: 620, y: 340))
    }

    func testMoveStaysInsideTheScreen() {
        XCTAssertEqual(RemoteClickExecutor.moveTarget(from: RemoteScreenPoint(x: 1910, y: 5),
                                                      size: size, dx: 500, dy: -500),
                       CGPoint(x: 1919, y: 0))
        XCTAssertEqual(RemoteClickExecutor.moveTarget(from: RemoteScreenPoint(x: 5, y: 1075),
                                                      size: size, dx: -500, dy: 500),
                       CGPoint(x: 0, y: 1079))
    }

    /// 一条命令最多挪 500px：坏客户端不能一个包把指针甩到另一块屏。
    func testMoveDeltaIsClamped() {
        let target = RemoteClickExecutor.moveTarget(from: RemoteScreenPoint(x: 900, y: 500),
                                                    size: size, dx: 100_000, dy: -100_000)
        XCTAssertEqual(target, CGPoint(x: 1400, y: 0))
    }

    /// 滚动同样要夹（一条命令不超过 300px），并且小数位移得取整，
    /// 否则零头会被一点点丢掉，越滚越慢。
    func testScrollDeltaIsClampedAndRounded() {
        let delta = RemoteClickExecutor.scrollDelta(dx: 12.4, dy: -7.6)
        XCTAssertEqual(delta.x, 12)
        XCTAssertEqual(delta.y, -8)
        let clamped = RemoteClickExecutor.scrollDelta(dx: 100_000, dy: -100_000)
        XCTAssertEqual(clamped.x, 300)
        XCTAssertEqual(clamped.y, -300)
    }

    /// 归一化坐标摊到屏幕上：中心就是中心，右下角留一像素，越界的夹进来而不是拒掉
    /// （手机在缩放边界上算出 1.0004 是常态）。
    func testWarpMapsNormalizedPointOntoTheScreen() {
        XCTAssertEqual(RemoteClickExecutor.warpTarget(nx: 0, ny: 0, size: size), CGPoint(x: 0, y: 0))
        XCTAssertEqual(RemoteClickExecutor.warpTarget(nx: 0.5, ny: 0.5, size: size),
                       CGPoint(x: 959.5, y: 539.5))
        XCTAssertEqual(RemoteClickExecutor.warpTarget(nx: 1, ny: 1, size: size),
                       CGPoint(x: 1919, y: 1079))
        XCTAssertEqual(RemoteClickExecutor.warpTarget(nx: 2, ny: -3, size: size),
                       CGPoint(x: 1919, y: 0))
    }
}

/// 回显帧的编码：一行一条 JSON，JPEG 走 base64。
final class RemoteScreenFrameTests: XCTestCase {
    /// 等比缩：只缩不放，宽不超过 maxWidth，高按比例取整且至少 1。
    func testScaledSizeKeepsAspectRatioAndNeverUpscales() {
        XCTAssertEqual(RemoteScreenCapture.scaledSize(width: 2880, height: 1800, maxWidth: 720).w, 720)
        XCTAssertEqual(RemoteScreenCapture.scaledSize(width: 2880, height: 1800, maxWidth: 720).h, 450)
        XCTAssertEqual(RemoteScreenCapture.scaledSize(width: 640, height: 400, maxWidth: 720).w, 640,
                       "比 maxWidth 还窄的屏幕不该被放大，只会更糊更大")
        XCTAssertEqual(RemoteScreenCapture.scaledSize(width: 1000, height: 3, maxWidth: 500).h, 2,
                       "高度按比例取整，不是无条件压成 1")
        XCTAssertEqual(RemoteScreenCapture.scaledSize(width: 1000, height: 1, maxWidth: 400).h, 1,
                       "极扁的画面不能缩成 0 高，否则 CGContext 直接建不出来")
    }

    func testFrameLineCarriesBase64JPEG() {
        let jpeg = Data([0xFF, 0xD8, 0x0A, 0xFF, 0xD9])   // 故意含换行：见协议头注释
        let line = RemoteCommand.frameLine(seq: 7, width: 720, height: 450, jpeg: jpeg)
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertFalse(text.contains("\n"), "成帧靠换行，base64 里绝不能出现真的换行字节")

        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        XCTAssertEqual(object["t"] as? String, "frame")
        XCTAssertEqual(object["i"] as? Int, 7)
        XCTAssertEqual(object["w"] as? Int, 720)
        XCTAssertEqual(object["h"] as? Int, 450)
        let decoded = Data(base64Encoded: (object["jpg"] as? String) ?? "")
        XCTAssertEqual(decoded, jpeg, "手机端 base64 解回来必须一个字节都不差")
    }
}

final class RemotePairingPayloadTests: XCTestCase {
    func testRoundTrip() {
        let text = RemotePairing.payload(host: "10.1.211.61", port: 8848, token: "K7FQ2M")
        XCTAssertEqual(text, "macstroke://pair?host=10.1.211.61&port=8848&token=K7FQ2M")
        let target = RemotePairing.parse(text)
        XCTAssertEqual(target?.host, "10.1.211.61")
        XCTAssertEqual(target?.port, 8848)
        XCTAssertEqual(target?.token, "K7FQ2M")
    }

    func testPastedTextWithWhitespaceIsParsed() {
        let target = RemotePairing.parse(" macstroke://pair?port=9527&token=abcd&host=192.168.1.9\n")
        XCTAssertEqual(target, RemotePairing.Target(host: "192.168.1.9", port: 9527, token: "ABCD"))
    }

    func testForeignOrIncompletePayloadsRejected() {
        XCTAssertNil(RemotePairing.parse("https://pair?host=1.2.3.4&port=1&token=a"))
        XCTAssertNil(RemotePairing.parse("macstroke://pair?host=1.2.3.4&port=1"))
        XCTAssertNil(RemotePairing.parse("macstroke://pair?port=1&token=abcd"))
        XCTAssertNil(RemotePairing.parse("macstroke://pair?host=&port=1&token=abcd"))
        XCTAssertNil(RemotePairing.parse("随便一句话"))
    }

    func testQRImageIsProduced() {
        let image = RemoteQRCode.image(from: RemotePairing.payload(host: "10.0.0.2", port: 8848, token: "AAAAAA"))
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size, NSSize(width: 180, height: 180))
    }
}
