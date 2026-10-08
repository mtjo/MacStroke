//
//  RemoteControlSettings.swift
//  MacStroke
//
//  Preference-backed settings for the remote control service, plus the
//  address/port/token rules the wire protocol and the QR payload depend on.
//

import Foundation
import Storage

/// Snapshot of the remote-control preferences.
public struct RemoteControlSettings: Equatable {
    public var enabled: Bool
    public var port: Int
    public var token: String

    public init(enabled: Bool, port: Int, token: String) {
        self.enabled = enabled
        self.port = port
        self.token = token
    }

    /// Reads the three keys. The port is re-validated on every read because the
    /// value can also arrive from an imported preference plist: a forbidden port
    /// falls back to the default instead of silently failing to listen.
    public static func current(from storage: PreferencesStorage = PreferencesStorage()) -> RemoteControlSettings {
        let storedPort = storage.getIntOptional(forKey: .remoteControlPort) ?? StorageDefaults.remoteControlPort
        return RemoteControlSettings(
            enabled: storage.getBoolOptional(forKey: .enableRemoteControl) ?? StorageDefaults.enableRemoteControl,
            port: isPortAllowed(storedPort) ? storedPort : StorageDefaults.remoteControlPort,
            token: storage.getStringOptional(forKey: .remoteControlToken) ?? ""
        )
    }

    /// Turns the service on, generating and persisting a pairing token first so
    /// the QR code shown right after always carries a usable one.
    @discardableResult
    public static func enable(port: Int, from storage: PreferencesStorage = PreferencesStorage()) -> RemoteControlSettings {
        if current(from: storage).token.isEmpty { _ = regenerateToken(from: storage) }
        storage.setInt(isPortAllowed(port) ? port : StorageDefaults.remoteControlPort,
                       forKey: .remoteControlPort)
        storage.setBool(true, forKey: .enableRemoteControl)
        storage.synchronize()
        return current(from: storage)
    }

    public static func disable(from storage: PreferencesStorage = PreferencesStorage()) {
        storage.setBool(false, forKey: .enableRemoteControl)
        storage.synchronize()
    }

    @discardableResult
    public static func regenerateToken(from storage: PreferencesStorage = PreferencesStorage()) -> String {
        let token = makeToken()
        storage.setString(token, forKey: .remoteControlToken)
        storage.synchronize()
        return token
    }

    /// 6 characters from an alphabet without look-alikes (no I/L/O/0/1) — the
    /// user also types this by hand when the camera cannot focus.
    public static func makeToken(length: Int = 6) -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// Ports a WeChat mini program is allowed to connect to: `wx.createTCPSocket`
    /// refuses everything below 1024 plus a published blacklist, so listening on
    /// one of those would make the service unreachable with no visible error.
    public static func isPortAllowed(_ port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return false }
        if (8000...8100).contains(port) { return false }
        return !blacklistedPorts.contains(port)
    }

    static let blacklistedPorts: Set<Int> = [
        1099, 1433, 1521, 1719, 1720, 1723, 2049, 2375, 3128, 3306, 3389, 3659,
        4045, 5060, 5061, 5432, 5984, 6379, 6000, 6566, 7001, 7002, 8443, 8888,
        9200, 9300, 10050, 10051, 11211, 27017, 27018, 27019,
    ]
}

/// The IPv4 addresses this machine advertises on the local network.
public enum RemoteNetworkAddress {
    public struct InterfaceAddress: Equatable {
        public let name: String
        public let address: String
    }

    /// Loopback and link-local addresses are excluded: a mini program may not
    /// connect to the phone's own address, and it cannot reach 169.254.x anyway.
    public static func lanInterfaces() -> [InterfaceAddress] {
        var found: [InterfaceAddress] = []
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else { return [] }
        defer { freeifaddrs(interfacePointer) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text.hasPrefix("169.254.") { continue }
            found.append(InterfaceAddress(name: String(cString: interface.ifa_name), address: text))
        }
        return found
    }

    public static func lanIPv4Addresses() -> [String] {
        lanInterfaces().map { $0.address }
    }

    /// The address to put in the QR code: `en0` is the built-in Wi-Fi, so it is
    /// the network the phone is most likely on.
    public static func preferredAddress() -> String? {
        let interfaces = lanInterfaces()
        return interfaces.first { $0.name == "en0" }?.address
            ?? interfaces.first { $0.name.hasPrefix("en") }?.address
            ?? interfaces.first?.address
    }
}
