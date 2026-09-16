# MacStroke Swift 重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 Swift 完整重构 mtjo/MacStroke，实现全局鼠标手势捕获、识别、规则引擎、偏好设置、状态栏菜单、右键菜单扩展、历史剪贴板、AppleScript、Toast 提示等全部功能。

**Architecture:** 高度模块化 Swift Package Manager 项目，核心算法 (GestureEngine) 纯 Swift 可独立测试；UI 采用 SwiftUI + AppKit 混合；数据使用 Codable 模型 + JSON/SQLite 持久化；通过 CGEventTap 捕获全局鼠标事件。

**Tech Stack:** Swift 5.9+ (Xcode 15+), Swift Package Manager, SwiftUI, AppKit, CoreGraphics, Sparkle (二进制分发), MASShortcut (SPM), SQLite.swift, XCTest

**Spec:** docs/superpowers/specs/2026-09-15-macstroke-swift-design.md

## Global Constraints

- 最低目标 macOS 13 Ventura
- 语言 Swift 5.9+ (兼容 Swift 6)
- 全新数据模型，不兼容旧版 plist 配置
- 使用 Swift Package Manager 管理依赖
- 所有核心算法必须有单元测试覆盖
- 每个功能块必须能独立编译和测试
---

### Phase 0: 项目骨架

**目标**: 创建 Swift Package Manager 项目结构、初始化 git、设置 CI

#### Task 0.1: 初始化 Swift Package

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`

**Interfaces:** None (初始化任务)

- [ ] **Step 1: 创建 Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacStroke",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Library targets for testability
        .library(
            name: "GestureEngine",
            targets: ["GestureEngine"]),
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
        // App executable
        .executable(
            name: "MacStrokeApp",
            targets: ["MacStrokeApp"])
    ],
    dependencies: [
        // Sparkle for updates (binary distribution)
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            .branch("2.x")),
        // MASShortcut for global hotkeys
        .package(
            url: "https://github.com/shpakovski/MASShortcut.git",
            .upToNextMajor(from: "1.27.3")),
        // SQLite.swift for clipboard history
        .package(
            url: "https://github.com/stephencelis/SQLite.swift.git",
            .upToNextMajor(from: "0.14.0"))
    ],
    targets: [
        // Core gesture recognition algorithms (pure Swift, testable)
        .target(
            name: "GestureEngine",
            dependencies: []),
        // Global event capture
        .target(
            name: "EventCapture",
            dependencies: ["GestureEngine"]),
        // Rule engine and action execution
        .target(
            name: "RuleEngine",
            dependencies: ["GestureEngine"]),
        // Persistence layer
        .target(
            name: "Storage",
            dependencies: []),
        // Preferences management (SwiftUI + AppKit)
        .target(
            name: "Preferences",
            dependencies: ["Storage"]),
        // Window management (status bar, canvas, toast)
        .target(
            name: "WindowManager",
            dependencies: ["GestureEngine", "RuleEngine", "Storage", "Preferences"]),
        // AppleScript execution
        .target(
            name: "AppleScriptRunner",
            dependencies: []),
        // Main app executable
        .executableTarget(
            name: "MacStrokeApp",
            dependencies: [
                "EventCapture",
                "WindowManager",
                "Preferences",
                "AppleScriptRunner"
            ],
            resources: [
                // Info.plist and other resources will be handled via build scripts
                // For now, we'll create a basic one
                .process("Resources")
            ]),
        // Finder Sync Extension (separate target)
        .target(
            name: "FinderSyncExtension",
            dependencies: ["RuleEngine"]),
        // Test targets
        .testTarget(
            name: "GestureEngineTests",
            dependencies: ["GestureEngine"]),
        .testTarget(
            name: "RuleEngineTests",
            dependencies: ["RuleEngine"]),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage"]),
        .testTarget(
            name: "WindowManagerTests",
            dependencies: ["WindowManager"])
    ]
)
```

- [ ] **Step 2: 创建 .gitignore**

```gitignore
# SwiftPM
.build/
Package.responder
Packages/
.xcodeproj/
.xcworkspace/
swiftpm-

# Derived Data
DerivedData/
*.xcodeproj/
project.xcworkspace/

# Build artifacts
*.o
*.lo
*.la
*.pc
.libs
*.so
*.dylib
*.exe
*.out
*.app
*.ipa
*.dSYM/
*.su
*.idb
*.pdb
*.linkinfo
*.ilk
*.manifest
*.exp
*.map

# Logs and caches
*.log
cache/
*.xcuserstate
project.xcworkspace/
xcuserdata/

# Dependency directories
Carthage/
Pods/

# macOS
.DS_Store
.AppleDouble
.LSOverride
._*
.DocumentRevisions-V100
.fseventsd
.Spotlight-V100
.TemporaryItems
.Trashes
.VolumeIcon.icns
.com.apple.timemachine.donotpresent
.Trashes
.NetworkTrashFolder
.TemporaryItems
.apdisk

# Xcode
*.xcodeproj/*
!*.xcodeproj/project.pbxproj
!*.xcodeproj/xcshareddata/
!*.xcodeproj/xcshareddata/
xcuserdata/
*.xccheckout
*.moved-aside
DerivedData/
*.hmap
*.ipa
*.xcuserstate
project.xcworkspace/

# CocoaPods
Pods/
Podfile.lock

# fastlane
fastlane/Report.xml
fastlane/Preview.html
fastlane/screenshots
**/fastlane.json

# Testing
/test_results
```

- [ ] **Step 3: 提交初始化**

```bash
git add Package.swift .gitignore
git commit -m "feat: 初始化 Swift Package Manager 项目结构"
```

#### Task 0.2: 创建资源目录和基本 Info.plist

**Files:**
- Create: `Resources/Info.plist`
- Create: `Resources/Assets.xcassets` (placeholder)

**Interfaces:** None

- [ ] **Step 1: 创建 Resources 目录**

```bash
mkdir -p Resources
```

- [ ] **Step 2: 创建基本 Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>net.mtjo.MacStroke</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MacStroke</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>MacStroke 需要运行 AppleScript。某些脚本必须被授权才能正常执行！</string>
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 mtjo.net. All rights reserved.</string>
    <key>NSMainNibFile</key>
    <string>MainMenu</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>OSAScriptingDefinition</key>
    <string>AppleScript.sdef</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/mtjo/MacStroke/release/AppCast.xml</string>
    <key>SUPublicDSAKeyFile</key>
    <string>dsa_pub.pem</string>
</dict>
</plist>