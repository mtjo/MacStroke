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
                NSLog("%@", "[LoginManager] Failed to register login item: \(error)")
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
                NSLog("%@", "[LoginManager] Failed to unregister login item: \(error)")
                return false
            }
        } else {
            UserDefaults.standard.set(false, forKey: "SMLoginItemEnabled")
            return true
        }
    }

    /// Synchronize the login item state with the stored user preference.
    /// Called when the user changes the "Launch at login" toggle in preferences.
    /// - Parameter enabled: The desired state.
    /// - Returns: true if the operation succeeded, false otherwise.
    public func syncWithPreference(_ enabled: Bool) -> Bool {
        if enabled {
            return enableLoginItem()
        } else {
            return disableLoginItem()
        }
    }

    /// Check if the app is currently registered as a login item.
    /// - Returns: true if the app is registered as a login item.
    public func isRegistered() -> Bool {
        return isLoginItem
    }
}