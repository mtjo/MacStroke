//
//  RightClicksList.swift
//  MacStroke
//
//  Manages the list of apps that support the right-click menu.
//  Uses UserDefaults + NSKeyedArchiver for persistence.
//

import Foundation

/// Manages the list of apps that support the right-click menu.
/// Persists via UserDefaults using NSKeyedArchiver.
public final class RightClicksList {

    public static let shared = RightClicksList()

    private var list: [String]
    private let defaults: UserDefaults

    // MARK: - Initialization

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.object(forKey: "rightClicksList") as? Data,
           let unarchived = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSString.self], from: data) as? [String] {
            self.list = unarchived
        } else {
            self.list = []
        }
        if list.isEmpty {
            reInit()
        }
    }

    // MARK: - Public Properties

    public var count: Int { list.count }

    // MARK: - Public Methods

    /// Reset to default list containing com.jetbrains.*
    public func reInit() {
        list = ["com.jetbrains.*"]
        save()
    }

    /// Clear all entries
    public func clear() {
        list.removeAll()
        save()
    }

    /// Persist current list to UserDefaults
    public func save() {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: list, requiringSecureCoding: false) {
            defaults.set(data, forKey: "rightClicksList")
            defaults.synchronize()
        }
    }

    /// Returns the app name at the given index
    public func appname(at index: Int) -> String? {
        guard index >= 0 && index < list.count else { return nil }
        return list[index]
    }

    /// Add an app (supports wildcards like com.jetbrains.*)
    public func add(_ appname: String) {
        if !list.contains(appname) {
            list.append(appname)
            save()
        }
    }

    /// Remove app at index
    @discardableResult
    public func remove(at index: Int) -> Bool {
        guard index >= 0 && index < list.count else { return false }
        list.remove(at: index)
        save()
        return true
    }

    /// Replace app name at index
    public func setAppname(at index: Int, appname: String) {
        guard index >= 0 && index < list.count else { return }
        list[index] = appname
        save()
    }

    /// Check whether the given bundle ID should show the right-click menu.
    /// Supports wildcard matching (e.g. "com.jetbrains.*" matches "com.jetbrains.jetbrainsbrains")
    public func needRightClick(byAppname appname: String) -> Bool {
        guard !list.isEmpty else { return false }
        if list.contains(appname) { return true }
        for pattern in list {
            if let wildcardRange = pattern.range(of: "*"), wildcardRange.lowerBound == pattern.index(before: pattern.endIndex) {
                let prefix = pattern.dropLast()
                if appname.hasPrefix(prefix) {
                    return true
                }
            }
        }
        return false
    }

    /// Returns all entries
    public func allApps() -> [String] { list }
}
