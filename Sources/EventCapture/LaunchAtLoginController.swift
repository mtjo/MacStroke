//
//  LaunchAtLoginController.swift
//  MacStroke
//
//  Controller that manages the "Launch at login" preference,
//  bridging the SwiftUI toggle to LoginManager (SMAppService).
//
//  Created by mtjo on 2026-09-16.
//

import Foundation
import AppKit
import ServiceManagement

/// Delegate for launch-at-login state changes.
public protocol LaunchAtLoginControllerDelegate: AnyObject {
    /// Called when the launch-at-login state changes.
    func launchAtLoginControllerDidChangeState(_ controller: LaunchAtLoginController)
}

/// Controller that manages the "Launch at login" preference.
///
/// Bridges the SwiftUI toggle to LoginManager, which uses SMAppService
/// (macOS 13+) for login item registration.
public final class LaunchAtLoginController: ObservableObject {

    /// Shared singleton instance.
    public static let shared = LaunchAtLoginController()

    /// Delegate for state change notifications.
    public weak var delegate: LaunchAtLoginControllerDelegate?

    /// Whether the app is currently registered as a login item.
    @Published public private(set) var isEnabled: Bool {
        didSet {
            if isEnabled != oldValue {
                delegate?.launchAtLoginControllerDidChangeState(self)
            }
        }
    }

    /// Error message if login item registration failed.
    @Published public private(set) var errorMessage: String?

    init() {
        self.isEnabled = LoginManager.shared.isLoginItem
    }

    /// Enables or disables the login item based on the given state.
    /// - Parameter enabled: true to enable, false to disable.
    public func setEnabled(_ enabled: Bool) {
        let success: Bool
        if enabled {
            success = LoginManager.shared.enableLoginItem()
        } else {
            success = LoginManager.shared.disableLoginItem()
        }

        if success {
            self.isEnabled = LoginManager.shared.isLoginItem
            self.errorMessage = nil
        } else {
            self.errorMessage = "Failed to update login item. Please check System Preferences."
            self.isEnabled = LoginManager.shared.isLoginItem
        }
    }

    /// Toggles the login item state.
    public func toggle() {
        setEnabled(!isEnabled)
    }

    /// Refreshes the login item state from the system.
    public func refreshState() {
        let newState = LoginManager.shared.isLoginItem
        if newState != isEnabled {
            isEnabled = newState
        }
    }
}
