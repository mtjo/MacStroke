# CLAUDE.md

本文件为将来在此仓库中工作的 Claude Code（claude.ai/code）提供开发指导。

## 构建与测试命令

```bash
# 构建全部目标
swift build

# 运行全部测试
swift test

# 运行单个测试目标
swift test --filter GestureEngineTests
swift test --filter RuleEngineTests
# 其他测试目标同理

# 列出可用测试
swift test --list-tests
```

## 架构概览

**MacStroke-Swift** 是一个 macOS 全局鼠标手势识别应用，使用 Swift 5.9+ 从原始 Objective-C 项目（mtjo/MacStroke）完整重写。最低部署版本为 macOS 13 Ventura。

### 包结构（Package.swift）

13 个 target，由多个库和一个可执行文件组成：

| Target | 作用 | 关键依赖 |
|--------|------|----------|
| `GestureEngine` | 核心 DTW 手势匹配（纯 Swift，完全可测试） | — |
| `EventCapture` | 通过 CGEventTap 进行全局鼠标捕获 | `GestureEngine` |
| `RuleEngine` | 规则、动作、模板匹配 | `GestureEngine`, `AppleScriptRunner` |
| `Storage` | 偏好设置（UserDefaults）+ 剪贴板历史（SQLite.swift） | `SQLite` |
| `Preferences` | SwiftUI + AppKit 偏好设置 UI | `Storage`, `RuleEngine`, `AppleScriptRunner`, `RightClickMenu`, `EventCapture` |
| `WindowManager` | 状态栏项目、Toast 通知 | `GestureEngine`, `RuleEngine`, `Storage`, `Preferences` |
| `AppleScriptRunner` | 通过 `osascript` 执行 AppleScript | — |
| `RightClickMenu` | Finder 右键菜单管理 | — |
| `FinderSyncExtension` | Finder Sync 扩展（独立 bundle） | `RuleEngine` |
| `MacStrokeApp` | 主应用可执行文件（accessory policy） | `EventCapture`, `WindowManager`, `Preferences`, `AppleScriptRunner`, `Sparkle` |

外部依赖：`SQLite.swift`（剪贴板历史）、`Sparkle`（自动更新）。

### 关键组件

- **Sources/MacStrokeApp/main.swift** — 应用入口。设置 `NSApplication.shared.setActivationPolicy(.accessory)`。创建 `AppDelegate`，其职责包括：
  - 在启动时应用已保存的语言偏好
  - 检查/请求无障碍权限（`AXIsProcessTrustedWithOptions`）
  - 启动 `EventCapture` → `CanvasManager` → `RuleEngine` 处理链
  - 创建状态栏项目，使用模板图片（`menu_icon_16x16.png` / disabled 版本）
  - 初始化 Sparkle 更新器（feed URL 为占位符）

- **Sources/EventCapture/EventCapture.swift** — 在 `.cgSessionEventTap` / `.headInsertEventTap` 使用 `CGEventTap`。捕获鼠标移动、左键/右键按下和抬起。将事件转换为 `GesturePoint` 并转发给 delegate（`CanvasManager`）。

- **Sources/GestureEngine/** — 从原始 `GestureCompare.m` 移植的 DTW 算法：
  - `Stroke` / `GesturePoint` — 归一化坐标、`t`（时间）、`alpha`（角度）、`dt`
  - `GestureMatcher.compare(template:candidate:)` → 分数 0…100（越高越相似）
  - `Stroke.normalize()` 平移 + 缩放到 `[0,1]²`，计算 `t/dt/alpha`

- **Sources/RuleEngine/** —
  - `Rule`（不可变 `struct`，所有 `let` 属性）包含 `GestureTemplate`、`RuleAction`、过滤器（通配符/正则 bundle ID）、`minSimilarityScore`
  - `RuleAction`: `.applescript`、`.keyPress`、`.mouseClick`、`.copyToClipboard`、`.none`
  - `RuleEngine` 将传入的 `Stroke` 与启用的规则进行匹配（带 bundle 过滤）
  - `RuleStore` 将规则持久化到 `~/Library/Application Support/MacStroke/rules.json`；通过 `GestureTemplateProvider` 提供 15 条默认规则
  - **不可变性**：更新规则时，创建新的 `Rule` 实例并调用 `RuleStore.update()`

- **Sources/Preferences/** —
  - `UserPreferences`（`ObservableObject`）将每个设置绑定到 `PreferencesStorage`（`StorageKey` enum 中的 UserDefaults key）
  - `PreferencesView`（SwiftUI）— 标签页 UI：General、Gesture、Note、Drawing、Right-Click、Clipboard、Updates
  - `DrawGestureView` — 用于在规则表格中渲染手势缩略图的 `NSViewRepresentable` 包装器，内部是 AppKit `DrawGesture`（`NSView`）
  - `GestureTemplatePreview` / `PresetGesturePickerView` — 预设手势选择（A–Z、方向箭头、方框符号）以及 "Apply to Selected" 流程
  - 规则表格列：Enabled、Gesture（DrawGestureView 56×56）、Name、Description、Action、App Filter

- **Sources/Storage/** —
  - `PreferencesStorage` — 对 `UserDefaults` 的薄封装，提供类型化 getter/setter 以及 `StorageDefaults` 常量
  - `HistoryClipboardManager` — 基于 SQLite 的剪贴板历史，支持置顶/收藏条目、分页、过期清理
  - `ClipboardHistoryManager` — 更简单的 SQLite 剪贴板存储（遗留实现？）

- **Sources/WindowManager/** — `WindowManager`（状态栏）、`Toast` / `ToastManager`（屏幕上的提示）

- **Sources/RightClickMenu/RightClickMenuManager.swift** — 管理 FinderSync 扩展生命周期：
  - 注册分布式通知观察者（`CustomMessageReceivedNotification`、`RequestObservingPathNotification`）
  - 通过 `SyncSharedDefaultsNotification` 将启用开关 + 本地化菜单标题同步到扩展
  - 操作：创建文本文件（`touch` + AppleScript 回退）、在终端中打开（`open -a`）、复制路径到剪贴板
  - 通过 `pluginkit -e use|ignore -i net.mtjo.MacStroke.FinderSyncExtension` 启用/禁用扩展

- **Sources/FinderSyncExtension/FinderSync.swift** — `FIFinderSync` 子类：
  - 工具栏项目，使用 `toolbarIcon` 图片
  - 上下文菜单项（新建文件、在终端中打开、复制路径），图片来自资源目录
  - 在用户操作时向主应用发送分布式通知

- **Sources/AppleScriptRunner/** — 通过 `osascript` 执行 AppleScript 字符串；提供预设动作（close-window、minimize、hide-app、launch Safari/Chrome/Terminal）。

### 本地化

- `L(key)` 函数位于 `Sources/Storage/Localization.swift`，从 `Resources/en.lproj/Localizable.strings` 和 `zh-Hans.lproj/Localizable.strings` 加载
- 语言持久化在 `UserDefaults` 的 `language` key 中；运行时切换会发送 `.languageDidChange` 通知
- `applyUserLanguage(_)` 会更新 `Bundle.main.preferredLocalizations`

### 重要实现注意事项

- **Rule 是不可变的** — 不要修改 `rule.template` 或其他 `let` 属性；始终构造新的 `Rule` 并调用 `RuleStore.update(newRule)`
- **DrawGesture 缩放** — `computeScaledPoints` 使用 `bounds.width/height`（不是硬编码常量）；`layout()` 覆写会在 bounds 变化时重新计算；`clipsToBounds = true`，背景透明
- **PreferencesView 规则表格** — Gesture 列使用 `DrawGestureView`（frame 56×56）；表格高度填充可用空间（滚动视图上使用 `maxHeight: .infinity`）
- **预设手势流程** — 点击手势单元格 → 选择规则 → 打开 `PresetGesturePickerView` sheet → "Apply to Selected" 创建带所选模板的新 `Rule`
- **FinderSync 通信** — 使用 `DistributedNotificationCenter`，`deliverImmediately: true`；菜单项通过共享 `UserDefaults` key 同步（`enableRightClickMenu`、`enableNewFile` 等）
- **无障碍权限** — 启动时通过 `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` 检查；会显示带 "Open System Settings" 按钮的模态提示
- **Sparkle** — `SPUStandardUpdaterController` 在 `AppDelegate.initSparkleUpdater()` 中初始化；feed URL 是占位符（`https://example.com/updates/feed.xml`）

### 测试

- 7 个测试 target（每个库一个）：`GestureEngineTests`、`EventCaptureTests`、`RuleEngineTests`、`StorageTests`、`WindowManagerTests`、`AppleScriptRunnerTests`、`RightClickMenuTests`
- 全部 105 个测试通过（`swift test`）

### 仓库中不存在的文件

未发现现有的 `CLAUDE.md`、`.cursor/rules/`、`.cursorrules` 或 `.github/copilot-instructions.md`。
