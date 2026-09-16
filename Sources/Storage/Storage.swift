//
//  Storage.swift
//  MacStroke
//
//  Persistent storage for user preferences and rules.
//  Uses UserDefaults for simple key-value storage.
//

import Foundation

/// Storage keys used by the preferences module.
public enum StorageKey: String {
    case isEnabled = "isEnabled"
    case minimumPoints = "minimumPoints"
    case minSimilarityScore = "minSimilarityScore"
    case showToast = "showToast"
    case clipboardHistoryLimit = "clipboardHistoryLimit"
    case launchAtLogin = "launchAtLogin"
}

/// A lightweight storage abstraction for user preferences.
public struct PreferencesStorage {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func getBool(forKey key: StorageKey) -> Bool {
        defaults.bool(forKey: key.rawValue)
    }

    public func getInt(forKey key: StorageKey) -> Int {
        defaults.integer(forKey: key.rawValue)
    }

    public func getDouble(forKey key: StorageKey) -> Double {
        defaults.double(forKey: key.rawValue)
    }

    /// Returns the boolean value for the given key, or nil if the key does not exist.
    public func getBoolOptional(forKey key: StorageKey) -> Bool? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.bool(forKey: key.rawValue)
    }

    /// Returns the integer value for the given key, or nil if the key does not exist.
    public func getIntOptional(forKey key: StorageKey) -> Int? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.integer(forKey: key.rawValue)
    }

    /// Returns the double value for the given key, or nil if the key does not exist.
    public func getDoubleOptional(forKey key: StorageKey) -> Double? {
        guard defaults.object(forKey: key.rawValue) != nil else { return nil }
        return defaults.double(forKey: key.rawValue)
    }

    public func setBool(_ value: Bool, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func setInt(_ value: Int, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func setDouble(_ value: Double, forKey key: StorageKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    public func remove(_ key: StorageKey) {
        defaults.removeObject(forKey: key.rawValue)
    }

    public func synchronize() {
        defaults.synchronize()
    }
}

/// Default storage configuration values.
public enum StorageDefaults {
    public static let isEnabled: Bool = true
    public static let minimumPoints: Int = 10
    public static let minSimilarityScore: Double = 30.0
    public static let showToast: Bool = true
    public static let clipboardHistoryLimit: Int = 50
    public static let launchAtLogin: Bool = false
}