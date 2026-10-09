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
//    {"t":"click","btn":"right","double":false}        在当前光标处点击
//    {"t":"button","btn":"left","down":true}           按住/松开（拖窗口、长按）
//    {"t":"scroll","dx":0,"dy":-40}                    滚动（像素，x 右 y 下，同手指方向）
//
//  server → client
//    {"t":"welcome","ok":true,"proto":1,"screen":{…},"cursor":{…}}
//    {"t":"error","code":"badToken"}
//    {"t":"ack","cmd":"move","cursor":{…}}
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

public enum RemoteCommand: Equatable {
    case hello(token: String, deviceName: String)
    case ping
    case move(dx: Double, dy: Double)
    case click(button: RemoteMouseButton, doubleClick: Bool)
    case button(button: RemoteMouseButton, pressed: Bool)
    case scroll(dx: Double, dy: Double)

    /// Protocol revision the client must speak.
    public static let revision = 1
}

public enum RemoteCommandError: String {
    case malformed
    case unknownCommand
    case badToken
    case notAuthenticated
    case busy
    case missingHello
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
    static let button = "btn"
    static let doubleClick = "double"
    static let down = "down"
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

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        // A stringified value is a client bug, not a reason to drop the socket.
        if let text = value as? String { return Double(text) }
        return nil
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
        }
    }
}
