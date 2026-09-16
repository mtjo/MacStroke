//
//  FinderSync.swift
//  MacStroke
//
//  Finder Sync Extension - provides right-click menu integration.
//

import Foundation
import Cocoa

/// Context menu provider for Finder integration.
public final class FinderMenuProvider: NSObject {

    /// Create a context menu for Finder.
    /// - Returns: An NSMenu with MacStroke options
    public func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "MacStroke")

        let recognizerItem = NSMenuItem(
            title: "Recognize Gesture",
            action: #selector(handleRecognizeGesture),
            keyEquivalent: ""
        )
        recognizerItem.target = self
        menu.addItem(recognizerItem)

        let presetsItem = NSMenuItem(
            title: "Preset Gestures",
            action: #selector(handlePresets),
            keyEquivalent: ""
        )
        presetsItem.target = self
        menu.addItem(presetsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Open Preferences",
            action: #selector(handleOpenPreferences),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        return menu
    }

    @objc private func handleRecognizeGesture() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.macstroke.RecognizeGesture"),
            object: nil
        )
    }

    @objc private func handlePresets() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.macstroke.Presets"),
            object: nil
        )
    }

    @objc private func handleOpenPreferences() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.macstroke.OpenPreferences"),
            object: nil
        )
    }
}