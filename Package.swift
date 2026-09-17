// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacStroke",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Library products
        .library(
            name: "GestureEngine",
            targets: ["GestureEngine"]),
        .library(
            name: "EventCapture",
            targets: ["EventCapture"]),
        .library(
            name: "RuleEngine",
            targets: ["RuleEngine"]),
        .library(
            name: "Storage",
            targets: ["Storage"]),
        .library(
            name: "Preferences",
            targets: ["Preferences"]),
        .library(
            name: "WindowManager",
            targets: ["WindowManager"]),
        .library(
            name: "AppleScriptRunner",
            targets: ["AppleScriptRunner"]),
        // Executable product
        .executable(
            name: "MacStrokeApp",
            targets: ["MacStrokeApp"])
    ],
    dependencies: [
        // SQLite.swift for clipboard history and rule storage
        .package(
            url: "https://github.com/stephencelis/SQLite.swift.git",
            .upToNextMajor(from: "0.14.0")),
        // Sparkle for automatic updates
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            .upToNextMajor(from: "2.5.0"))
    ],
    targets: [
        // ============ Core gesture recognition algorithms (pure Swift, fully testable) ============
        .target(
            name: "GestureEngine",
            dependencies: []),
        // ============ Global event capture ============
        .target(
            name: "EventCapture",
            dependencies: ["GestureEngine"]),
        // ============ Rule engine and action execution ============
        .target(
            name: "RuleEngine",
            dependencies: ["GestureEngine", "AppleScriptRunner"]),
        // ============ Persistence layer ============
        .target(
            name: "Storage",
            dependencies: [
                .product(name: "SQLite", package: "sqlite.swift")
            ]),
        // ============ Preferences management (SwiftUI + AppKit) ============
        .target(
            name: "Preferences",
            dependencies: ["Storage", "RuleEngine", "AppleScriptRunner", "RightClickMenu"]),
        // ============ Window management (status bar, canvas, toast) ============
        .target(
            name: "WindowManager",
            dependencies: ["GestureEngine", "RuleEngine", "Storage", "Preferences"]),
        // ============ AppleScript execution ============
        .target(
            name: "AppleScriptRunner",
            dependencies: []),
        // ============ Main app executable ============
        .executableTarget(
            name: "MacStrokeApp",
            dependencies: [
                "EventCapture",
                "WindowManager",
                "Preferences",
                "AppleScriptRunner",
                "Sparkle"
            ],
            resources: [
                .process("Resources")
            ]),
        // ============ Finder Sync Extension ============
        .target(
            name: "FinderSyncExtension",
            dependencies: ["RuleEngine"]),
        // ============ Right-click menu management ============
        .target(
            name: "RightClickMenu",
            dependencies: []),
        // ============ Test targets ============
        .testTarget(
            name: "GestureEngineTests",
            dependencies: ["GestureEngine"]),
        .testTarget(
            name: "EventCaptureTests",
            dependencies: ["EventCapture"]),
        .testTarget(
            name: "RuleEngineTests",
            dependencies: ["RuleEngine"]),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage"]),
        .testTarget(
            name: "WindowManagerTests",
            dependencies: ["WindowManager"]),
        .testTarget(
            name: "AppleScriptRunnerTests",
            dependencies: ["AppleScriptRunner"]),
        .testTarget(
            name: "RightClickMenuTests",
            dependencies: ["RightClickMenu"])
    ]
)