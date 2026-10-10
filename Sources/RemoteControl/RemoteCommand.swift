//
//  RemoteCommand.swift
//  MacStroke
//
//  The line-delimited JSON wire protocol between the mini program and the
//  Mac. One JSON object per "\n"-terminated line, UTF-8.
//
//  client → server
//    {"t":"hello","token":"ABC123","name":"iPhone"}    握手，必须是第一条
//    {"t":"ping"}                                      保活
//    {"t":"move","dx":12,"dy":-8}                      光标位移（像素，x 右 y 下）
//    {"t":"warp","x":0.42,"y":0.66}                    光标绝对位置（主屏归一化，0…1）
//    {"t":"click","btn":"right","double":false}        在当前光标处点击
//    {"t":"button","btn":"left","down":true}           按住/松开（拖窗口、长按）
//    {"t":"scroll","dx":0,"dy":-40}                    滚动（像素，x 右 y 下，同手指方向）
//    {"t":"mirror","on":true,"w":720,"fps":3,"q":45}   开关桌面回显，w/fps/q 可省
//
//  server → client
//    {"t":"welcome","ok":true,"proto":2,"screen":{…},"cursor":{…}}
//    {"t":"error","code":"badToken"}
//    {"t":"ack","cmd":"move","cursor":{…}}
//    {"t":"frame","i":12,"w":720,"h":450,"jpg":"<base64>"}
//
//  回显走 base64 而不是裸 JPEG 字节：JPEG 里出现 0x0A 就会把行协议切成两半，
//  想混二进制得另加长度前缀，而一帧也就多三分之一字节。
//

import Foundation

public enum RemoteMouseButton: String, CaseIterable {
    case left
    case right
    case middle

    /// CoreGraphics button number, the same numbering the gesture replay uses
    /// (`MouseButton.cgNumber` in EventCapture).
    public var cgNumber: Int {
        switch self {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        }
    }
}

public struct RemoteScreenPoint: Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var json: [String: Double] { ["x": x, "y": y] }
}

public struct RemoteScreenSize: Equatable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }

    var json: [String: Double] { ["w": w, "h": h] }
}

/// 桌面回显的一帧参数，来自 `{"t":"mirror",…}`。
///
/// 三个尺寸/频率/质量都是「手机想要的」，不是承诺：越界一律夹到能用的边界，
/// 客户端写错数字不该断连，也不该把 Mac 拖去跑 60 fps 全屏编码。
public struct RemoteMirrorRequest: Equatable {
    public static let defaultWidth = 720
    public static let defaultFPS = 3
    public static let defaultQuality = 45

    public var on: Bool
    public var maxWidth: Int
    public var fps: Int
    public var quality: Int

    public init(on: Bool, maxWidth: Int = RemoteMirrorRequest.defaultWidth,
                fps: Int = RemoteMirrorRequest.defaultFPS,
                quality: Int = RemoteMirrorRequest.defaultQuality) {
        self.on = on
        self.maxWidth = maxWidth
        self.fps = fps
        self.quality = quality
    }

    public var clamped: RemoteMirrorRequest {
        RemoteMirrorRequest(on: on,
                            maxWidth: min(max(maxWidth, 320), 1920),
                            fps: min(max(fps, 1), 10),
                            quality: min(max(quality, 10), 90))
    }
}

public enum RemoteCommand: Equatable {
    case hello(token: String, deviceName: String)
    case ping
    case move(dx: Double, dy: Double)
    case warp(x: Double, y: Double)
    case click(button: RemoteMouseButton, doubleClick: Bool)
    case button(button: RemoteMouseButton, pressed: Bool)
    case scroll(dx: Double, dy: Double)
    case mirror(RemoteMirrorRequest)

    /// 协议版本：1 只有位移与点击，2 加了绝对坐标与桌面回显。
    /// 手机端要靠这句话判断该不该提示「升级 MacStroke」。
    public static let revision = 2
}

public enum RemoteCommandError: String {
    case malformed
    case unknownCommand
    case badToken
    case notAuthenticated
    case busy
    case missingHello
    case noScreenPermission
}

/// A decoded inbound line, or the reason it was rejected.
public enum RemoteRequest: Equatable {
    case command(RemoteCommand)
    case error(RemoteCommandError)
}

/// Wire field names are short because every keystroke goes over the socket.
private enum Field {
    static let type = "t"
    static let token = "token"
    static let name = "name"
    static let dx = "dx"
    static let dy = "dy"
    static let x = "x"
    static let y = "y"
    static let button = "btn"
    static let doubleClick = "double"
    static let down = "down"
    static let on = "on"
    static let maxWidth = "w"
    static let fps = "fps"
    static let quality = "q"
    static let seq = "i"
    static let height = "h"
    static let jpeg = "jpg"
}

public extension RemoteCommand {
    /// Decodes one protocol line. Surrounding whitespace is tolerated; the
    /// "\n" framing itself is stripped by the connection, not here.
    static func parse(line rawLine: String) -> RemoteRequest {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let type = fields[Field.type] as? String else {
            return .error(.malformed)
        }

        switch type {
        case "hello":
            let token = ((fields[Field.token] as? String) ?? "").uppercased()
            return .command(.hello(token: token, deviceName: fields[Field.name] as? String ?? ""))
        case "ping":
            return .command(.ping)
        case "move":
            guard let dx = number(fields[Field.dx]), let dy = number(fields[Field.dy]) else {
                return .error(.malformed)
            }
            return .command(.move(dx: dx, dy: dy))
        case "warp":
            // 触屏页按「点哪儿就是哪儿」发归一化坐标，不需要知道屏幕分辨率。
            guard let x = number(fields[Field.x]), let y = number(fields[Field.y]) else {
                return .error(.malformed)
            }
            return .command(.warp(x: x, y: y))
        case "click":
            guard let button = button(fields[Field.button]) else { return .error(.malformed) }
            return .command(.click(button: button, doubleClick: flag(fields[Field.doubleClick])))
        case "button":
            guard let button = button(fields[Field.button]) else { return .error(.malformed) }
            return .command(.button(button: button, pressed: flag(fields[Field.down])))
        case "scroll":
            // 滚动和移动共用 dx/dy：手机端两根手指的位移本来就是同一套坐标语义。
            guard let dx = number(fields[Field.dx]), let dy = number(fields[Field.dy]) else {
                return .error(.malformed)
            }
            return .command(.scroll(dx: dx, dy: dy))
        case "mirror":
            let request = RemoteMirrorRequest(
                on: flag(fields[Field.on]),
                maxWidth: int(fields[Field.maxWidth]) ?? RemoteMirrorRequest.defaultWidth,
                fps: int(fields[Field.fps]) ?? RemoteMirrorRequest.defaultFPS,
                quality: int(fields[Field.quality]) ?? RemoteMirrorRequest.defaultQuality
            ).clamped
            return .command(.mirror(request))
        default:
            return .error(.unknownCommand)
        }
    }

    /// Builds a reply. `nil` values drop their key so callers can pass an
    /// optional cursor without emitting `"cursor":null`.
    static func reply(type: String, fields: [String: Any?]) -> Data {
        var object: [String: Any] = [Field.type: type]
        for (key, value) in fields {
            if let value { object[key] = value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return Data(#"{"t":"error","code":"malformed"}"#.utf8)
        }
        return data
    }

    static func errorReply(_ error: RemoteCommandError) -> Data {
        reply(type: "error", fields: ["code": error.rawValue, "message": error.message])
    }

    /// 一帧桌面图像。base64 是纯 ASCII，塞进 JSON 字符串不需要转义。
    static func frameLine(seq: Int, width: Int, height: Int, jpeg: Data) -> Data {
        reply(type: "frame", fields: [
            Field.seq: seq,
            Field.maxWidth: width,
            Field.height: height,
            Field.jpeg: jpeg.base64EncodedString(),
        ])
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        // A stringified value is a client bug, not a reason to drop the socket.
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        number(value).map { Int($0) }
    }

    private static func flag(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func button(_ value: Any?) -> RemoteMouseButton? {
        // Omitting the button means the left one; an unknown spelling is an
        // error rather than a guess about which button the user meant.
        guard let text = value as? String else { return value == nil ? .left : nil }
        return RemoteMouseButton(rawValue: text.lowercased())
    }
}

public extension RemoteCommandError {
    /// Text the mini program shows as-is: the phone has no way to diagnose a
    /// failed connection, so the reason has to come from the Mac.
    var message: String {
        switch self {
        case .malformed: return "命令格式不对"
        case .unknownCommand: return "不认识这条命令"
        case .badToken: return "配对码不对"
        case .notAuthenticated: return "还没配对"
        case .busy: return "连接的设备太多了"
        case .missingHello: return "没有先发配对命令"
        case .noScreenPermission: return "Mac 还没给屏幕录制权限，给完要重启 MacStroke"
        }
    }
}
