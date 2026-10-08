//
//  RemoteControlServer.swift
//  MacStroke
//
//  LAN TCP service that lets the WeChat mini program drive the cursor.
//
//  Nothing here is reachable from outside the local network: WeChat's
//  `wx.createTCPSocket` itself refuses to talk to anything but a same-subnet
//  address (plus configured domains), so a pairing token is the only
//  credential on the wire. It gates the first packet, not every one — a
//  connection that never says hello is dropped after `helloTimeout`.
//

import Foundation
import Network
import Storage

public extension Notification.Name {
    /// The remote-control settings changed; the app re-applies them to the live
    /// service (start / stop / restart), like the clipboard switches do.
    static let macStrokeRemoteControlDidChange = Notification.Name("MacStrokeRemoteControlDidChange")
}

/// One paired phone, as shown on the About pane.
public struct RemotePeer: Identifiable, Equatable {
    public let id = UUID()
    public var name: String
    public var address: String
}

public final class RemoteControlServer: ObservableObject {
    public static let shared = RemoteControlServer()

    /// @Published so the About pane can observe the live peer list.
    @Published public private(set) var peers: [RemotePeer] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var statusMessage: String?

    /// Max simultaneous phones: enough for a desk, low enough that a lost
    /// hotspot cannot pile up sockets.
    private let maxPeers = 4
    private let helloTimeout: TimeInterval = 10
    /// A client that streams without ever sending a newline must not be able to
    /// grow the buffer forever.
    private let maxBufferedBytes = 64 * 1024

    private let queue = DispatchQueue(label: "net.mtjo.MacStroke.remote")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var settings = RemoteControlSettings.current()

    /// 各连接按住的鼠标键。**只在主队列读写**（命令本来就在那里执行）。
    /// 手机断线、退出小程序或关掉开关时若不补一个松开，Mac 会一直停在拖拽状态，
    /// 用户只能狂点鼠标才解得开。
    private var heldButtons: [ObjectIdentifier: RemoteMouseButton] = [:]

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var authenticated = false
        var name = ""
        var address = ""

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    private init() {}

    // MARK: - Lifecycle

    /// Starts, restarts or stops the listener to match the stored settings.
    @discardableResult
    public func apply(_ newSettings: RemoteControlSettings? = nil) -> RemoteControlSettings {
        let next = newSettings ?? RemoteControlSettings.current()
        if !next.enabled {
            stop()
            return next
        }
        // Turning the switch on without a token yet would advertise an
        // unpairable service, so mint one before listening.
        if next.token.isEmpty {
            RemoteControlSettings.enable(port: next.port)
            return apply(RemoteControlSettings.current())
        }
        if isRunning, settings == next { return next }
        if isRunning { stop() }
        settings = next
        startListening(on: next.port)
        return settings
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            let dying = Array(self.clients.values)
            for client in dying { client.connection.cancel() }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
            DispatchQueue.main.async {
                dying.forEach(self.releaseHeldButton)
                self.isRunning = false
                self.peers = []
            }
        }
    }

    private func startListening(on port: Int) {
        queue.async {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                self.publish(status: "端口 \(port) 不可用")
                return
            }
            do {
                let listener = try NWListener(using: parameters, on: nwPort)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.publish(status: nil)
                    case .failed(let error):
                        NSLog("%@", "[RemoteControl] Listener failed: \(error.localizedDescription)")
                        self.publish(status: "监听失败：\(error.localizedDescription)")
                    case .cancelled:
                        self.publish(status: nil)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
                self.listener = listener
                DispatchQueue.main.async { self.isRunning = true }
                NSLog("%@", "[RemoteControl] Listening on port \(port)")
            } catch {
                NSLog("%@", "[RemoteControl] Could not listen on \(port): \(error.localizedDescription)")
                self.publish(status: "监听失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        client.address = String(describing: connection.endpoint)

        if clients.count >= maxPeers {
            connection.start(queue: queue)
            connection.send(content: RemoteCommand.errorReply(.busy) + newline,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        connection.start(queue: queue)
        clients[ObjectIdentifier(connection)] = client
        receive(from: client)

        // A socket that never authenticates is closed rather than held open.
        queue.asyncAfter(deadline: .now() + helloTimeout) { [weak self] in
            guard let self, self.clients[ObjectIdentifier(connection)] === client,
                  !client.authenticated else { return }
            self.fail(client, with: .missingHello)
        }
    }

    private func receive(from client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                client.buffer.append(data)
                if client.buffer.count > self.maxBufferedBytes {
                    self.fail(client, with: .malformed)
                    return
                }
                self.drainLines(from: client)
            }
            if isComplete || error != nil {
                self.disconnect(client)
                return
            }
            self.receive(from: client)
        }
    }

    private func drainLines(from client: Client) {
        while let index = client.buffer.firstIndex(of: 0x0A) {
            let lineData = client.buffer.subdata(in: client.buffer.startIndex..<index)
            client.buffer.removeSubrange(client.buffer.startIndex...index)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line, from: client)
        }
    }

    private func handle(_ line: String, from client: Client) {
        switch RemoteCommand.parse(line: line) {
        case .error(let error):
            send(RemoteCommand.errorReply(error), to: client)
        case .command(let command):
            if client.authenticated {
                execute(command, from: client)
            } else {
                authenticateOrReject(command, from: client)
            }
        }
    }

    private func authenticateOrReject(_ command: RemoteCommand, from client: Client) {
        switch command {
        case .hello(let token, let name):
            guard token == settings.token else {
                NSLog("%@", "[RemoteControl] Rejected hello with token \(token) from \(client.address)")
                fail(client, with: .badToken)
                return
            }
            authenticate(client, deviceName: name)
        default:
            fail(client, with: .notAuthenticated)
        }
    }

    private func authenticate(_ client: Client, deviceName: String) {
        client.authenticated = true
        client.name = deviceName.isEmpty ? client.address : deviceName
        let peer = RemotePeer(name: client.name, address: client.address)
        let count = clients.values.filter { $0.authenticated }.count
        DispatchQueue.main.async {
            let state = RemoteClickExecutor.state()
            self.send(RemoteCommand.reply(type: "welcome", fields: [
                "ok": true,
                "proto": RemoteCommand.revision,
                "screen": state.size.json,
                "cursor": state.cursor.json,
                "peers": count,
            ]), to: client)
            self.peers.append(peer)
        }
        NSLog("%@", "[RemoteControl] Paired with \(peer.name)")
    }

    /// Commands run on the main queue: that is where the gesture tap lives, so
    /// a synthetic click cannot interleave with a live gesture's replay.
    private func execute(_ command: RemoteCommand, from client: Client) {
        switch command {
        case .hello:
            // A second hello just re-confirms the pairing.
            authenticateRecheck(client)
        case .ping:
            DispatchQueue.main.async { self.ack("ping", to: client, cursor: false) }
        case .move(let dx, let dy):
            DispatchQueue.main.async {
                RemoteClickExecutor.moveCursor(byX: CGFloat(dx), y: CGFloat(dy))
                self.ack("move", to: client, cursor: true)
            }
        case .click(let button, let doubleClick):
            DispatchQueue.main.async {
                RemoteClickExecutor.click(button: button, doubleClick: doubleClick)
                self.ack("click", to: client, cursor: true)
            }
        case .button(let button, let pressed):
            DispatchQueue.main.async {
                RemoteClickExecutor.setButton(button, pressed: pressed)
                let key = ObjectIdentifier(client.connection)
                if pressed {
                    self.heldButtons[key] = button
                } else {
                    self.heldButtons[key] = nil
                }
                self.ack("button", to: client, cursor: true)
            }
        }
    }

    /// 补发一个松开并把这台手机从「按住中」里划掉。主队列调用。
    private func releaseHeldButton(for client: Client) {
        guard let button = heldButtons.removeValue(forKey: ObjectIdentifier(client.connection)) else {
            return
        }
        RemoteClickExecutor.setButton(button, pressed: false)
    }

    private func authenticateRecheck(_ client: Client) {
        DispatchQueue.main.async {
            let state = RemoteClickExecutor.state()
            self.send(RemoteCommand.reply(type: "welcome", fields: [
                "ok": true,
                "proto": RemoteCommand.revision,
                "screen": state.size.json,
                "cursor": state.cursor.json,
            ]), to: client)
        }
    }

    private func ack(_ cmd: String, to client: Client, cursor: Bool) {
        var fields: [String: Any?] = ["cmd": cmd]
        if cursor {
            let state = RemoteClickExecutor.state()
            fields["cursor"] = state.cursor.json
            fields["screen"] = state.size.json
        }
        send(RemoteCommand.reply(type: "ack", fields: fields), to: client)
    }

    private func send(_ payload: Data, to client: Client, then action: @escaping () -> Void = {}) {
        var framed = payload
        framed.append(newline)
        client.connection.send(content: framed, completion: .contentProcessed { _ in action() })
    }

    /// 报错后必须等字节真的写出去再断开：同一拍里 cancel() 会把还没发完的
    /// 错误包丢掉，手机端就只知道连接断了，看不到「配对码不对」。
    private func fail(_ client: Client, with error: RemoteCommandError) {
        send(RemoteCommand.errorReply(error), to: client) { [weak self] in
            self?.disconnect(client)
        }
    }

    private func disconnect(_ client: Client) {
        let key = ObjectIdentifier(client.connection)
        guard clients.removeValue(forKey: key) != nil else { return }
        if client.authenticated {
            DispatchQueue.main.async {
                self.releaseHeldButton(for: client)
                self.peers.removeAll { $0.name == client.name && $0.address == client.address }
            }
        }
        client.connection.cancel()
    }

    private func publish(status: String?) {
        DispatchQueue.main.async {
            self.statusMessage = status
            if status != nil {
                self.isRunning = false
                self.peers = []
            }
        }
    }

    private var newline: Data { Data([0x0A]) }
}
