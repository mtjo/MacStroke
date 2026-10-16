//
//  UnlockPasswordStore.swift
//  MacStroke
//
//  存登录密码的地方。这是整个功能里唯一真正的安全红线：**明文登录密码落盘**，
//  所以只放钥匙串（不进 UserDefaults、不进配置文件、不进日志），并且日志里永远只说
//  「读到了 / 没读到」，绝不打印内容或长度。
//
//  自动解锁默认是关的：只锁不解是完全可用的组合，反过来不成立。
//

import Foundation
import Security

public protocol UnlockPasswordStoring {
    var hasPassword: Bool { get }
    func readPassword() -> String?
    @discardableResult
    func savePassword(_ password: String) -> Bool
    func deletePassword()
}

/// 单测与「先不碰钥匙串」的场景用。放同一个模块里，免得测试里到处判环境变量 ——
/// 钥匙串在无人值守的机器上会弹授权框，弹了没人点就是永久挂起。
public final class InMemoryPasswordStore: UnlockPasswordStoring {
    private var password: String?
    public init(password: String? = nil) { self.password = password }
    public var hasPassword: Bool { password?.isEmpty == false }
    public func readPassword() -> String? { password }
    @discardableResult
    public func savePassword(_ password: String) -> Bool { self.password = password; return true }
    public func deletePassword() { password = nil }
}

public final class KeychainPasswordStore: UnlockPasswordStoring {
    public static let service = "net.mtjo.MacStroke.proximitylock"
    public static let account = "login-password"

    private let log: (String) -> Void

    public init(log: @escaping (String) -> Void = { NSLog("%@", "[ProximityLock] " + $0) }) {
        self.log = log
    }

    public var hasPassword: Bool { readPassword() != nil }

    public func readPassword() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // 不要弹任何授权框：弹了没人点，进程就挂在这儿。宁可返回 nil 让用户去偏好页重存一次。
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            log("钥匙串读取失败 OSStatus=\(status)")
            return nil
        }
    }

    @discardableResult
    public func savePassword(_ password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        var query = baseQuery()
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            log(update == errSecSuccess ? "钥匙串密码已更新" : "钥匙串更新失败 OSStatus=\(update)")
            return update == errSecSuccess
        }
        query[kSecValueData as String] = data
        // AfterFirstUnlock：开机登录过一次之后就能读 —— 我们要读的时机恰恰是「屏幕锁着但会话在跑」。
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // 明确走文件钥匙串（login.keychain-db），别落到数据保护钥匙串：
        // 后者在锁屏后可能读不出来，那正是我们唯一需要它的时刻。
        query[kSecUseDataProtectionKeychain as String] = kCFBooleanFalse
        let add = SecItemAdd(query as CFDictionary, nil)
        log(add == errSecSuccess ? "钥匙串密码已保存" : "钥匙串保存失败 OSStatus=\(add)")
        return add == errSecSuccess
    }

    public func deletePassword() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log("钥匙串删除失败 OSStatus=\(status)")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainPasswordStore.service,
            kSecAttrAccount as String: KeychainPasswordStore.account,
        ]
    }
}
