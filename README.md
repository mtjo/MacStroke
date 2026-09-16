# MacStroke-Swift

macOS 全局鼠标手势应用，用 Swift 完整重构自 [mtjo/MacStroke](https://github.com/mtjo/MacStroke)。

## 功能

- 全局鼠标事件捕获（CGEventTap）
- DTW 手势识别引擎
- 规则引擎与动作执行（AppleScript / 按键 / 鼠标点击 / 剪贴板）
- 偏好设置（SwiftUI + AppKit）
- 状态栏菜单
- 右键菜单扩展（Finder Sync）
- 历史剪贴板（SQLite）
- AppleScript 支持与预设手势
- Toast 提示

## 技术栈

- Swift 5.9+，最低 macOS 13 Ventura
- Swift Package Manager
- SwiftUI + AppKit 混合 UI
- SQLite.swift 持久化

## 构建

```bash
swift build
swift test
```

## 目录结构

```
Sources/
  GestureEngine/      # Stroke / GesturePoint / GestureMatcher (DTW)
  EventCapture/       # CGEventTap 全局捕获
  RuleEngine/         # Rule / RuleAction / ActionExecutor
  Storage/            # PreferencesStorage / ClipboardHistory
  Preferences/        # SwiftUI 偏好页面
  WindowManager/      # ToastManager / WindowManager
  AppleScriptRunner/  # AppleScript 执行器
  FinderSyncExtension/# Finder 右键菜单扩展
  MacStrokeApp/       # 应用入口
Tests/                # 各模块单元测试
```
