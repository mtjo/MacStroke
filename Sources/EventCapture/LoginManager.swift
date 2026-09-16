//
//  LoginManager.swift
//  MacStroke
//
//  Manages launch at login using SMAppService (macOS 13+) or UserDefaults fallback.
//

import Foundation
import AppKit
import ServiceManagement

/// Manages login item registration for automatic launch at login.
public final class LoginManager {
    public static let shared = LoginManager()

    private init() {}

    /// Check if the app is registered as a login item.
    public var isLoginItem: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return UserDefaults.standard.bool(forKey: "SMLoginItemEnabled")
        }
    }

    /// Register the app as a login item.
    @discardableResult
    public func enableLoginItem() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                return true
            } catch {
                print("[LoginManager] Failed to register login item: \(error)")
                return false
            }
        } else {
            UserDefaults.standard.set(true, forKey: "SMLoginItemEnabled")
            return true
        }
    }

    /// Unregister the app from login items.
    @discardableResult
    public func disableLoginItem() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                return true
            } catch {
                print("[LoginManager] Failed to unregister login item: \(error)")
                return false
            }
        } else {
            UserDefaults.standard.set(false, forKey: "SMLoginItemEnabled")
            return true
        }
    }
}