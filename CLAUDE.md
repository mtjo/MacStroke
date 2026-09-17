# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build all targets
swift build

# Run all tests
swift test

# Run a single test target
swift test --filter GestureEngineTests
swift test --filter RuleEngineTests
# etc.

# List available tests
swift test --list-tests
```

## Architecture Overview

**MacStroke-Swift** is a macOS global mouse gesture recognition app, rewritten in Swift 5.9+ from the original Objective-C project (mtjo/MacStroke). Minimum deployment: macOS 13 Ventura.

### Package Structure (Package.swift)

13 targets organized as libraries + executable:

| Target | Role | Key Dependencies |
|--------|------|------------------|
| `GestureEngine` | Core DTW gesture matching (pure Swift, fully testable) | — |
| `EventCapture` | Global mouse capture via CGEventTap | `GestureEngine` |
| `RuleEngine` | Rules, actions, template matching | `GestureEngine`, `AppleScriptRunner` |
| `Storage` | Preferences (UserDefaults) + clipboard history (SQLite.swift) | `SQLite` |
| `Preferences` | SwiftUI + AppKit preferences UI | `Storage`, `RuleEngine`, `AppleScriptRunner`, `RightClickMenu`, `EventCapture` |
| `WindowManager` | Status bar item, toast notifications | `GestureEngine`, `RuleEngine`, `Storage`, `Preferences` |
| `AppleScriptRunner` | AppleScript execution via `osascript` | — |
| `RightClickMenu` | Finder right-click menu management | — |
| `FinderSyncExtension` | Finder Sync extension (separate bundle) | `RuleEngine` |
| `MacStrokeApp` | Main app executable (accessory policy) | `EventCapture`, `WindowManager`, `Preferences`, `AppleScriptRunner`, `Sparkle` |

External dependencies: `SQLite.swift` (clipboard history), `Sparkle` (auto-updates).

### Key Components

- **Sources/MacStrokeApp/main.swift** — App entry point. Sets `NSApplication.shared.setActivationPolicy(.accessory)`. Creates `AppDelegate` that:
  - Applies saved language preference at launch
  - Checks/requests Accessibility permission (`AXIsProcessTrustedWithOptions`)
  - Starts `EventCapture` → `CanvasManager` → `RuleEngine` pipeline
  - Creates status bar item with template images (`menu_icon_16x16.png` / disabled variant)
  - Initializes Sparkle updater (feed URL placeholder)

- **Sources/EventCapture/EventCapture.swift** — `CGEventTap` at `.cgSessionEventTap` / `.headInsertEventTap`. Captures mouse moved, left/right down/up. Converts to `GesturePoint` and forwards to delegate (`CanvasManager`).

- **Sources/GestureEngine/** — DTW algorithm ported from original `GestureCompare.m`:
  - `Stroke` / `GesturePoint` — normalized coordinates, `t` (time), `alpha` (angle), `dt`
  - `GestureMatcher.compare(template:candidate:)` → score 0…100 (higher = more similar)
  - `Stroke.normalize()` translates + scales to `[0,1]²`, computes `t/dt/alpha`

- **Sources/RuleEngine/** —
  - `Rule` (immutable `struct`, all `let` properties) with `GestureTemplate`, `RuleAction`, filter (wildcard/regex bundle ID), `minSimilarityScore`
  - `RuleAction`: `.applescript`, `.keyPress`, `.mouseClick`, `.copyToClipboard`, `.none`
  - `RuleEngine` matches incoming `Stroke` against enabled rules (with bundle filter)
  - `RuleStore` persists rules to `~/Library/Application Support/MacStroke/rules.json`; provides 15 default rules via `GestureTemplateProvider`
  - **Immutability**: to update a rule, create a new `Rule` instance and call `RuleStore.update()`

- **Sources/Preferences/** —
  - `UserPreferences` (`ObservableObject`) binds every setting to `PreferencesStorage` (UserDefaults keys in `StorageKey` enum)
  - `PreferencesView` (SwiftUI) — tabbed UI: General, Gesture, Note, Drawing, Right-Click, Clipboard, Updates
  - `DrawGestureView` — `NSViewRepresentable` wrapper around `DrawGesture` (AppKit `NSView`) for rendering gesture thumbnails in the rules table
  - `GestureTemplatePreview` / `PresetGesturePickerView` — preset gesture selection (A–Z, arrows, box symbols) and "Apply to Selected" workflow
  - Rules table columns: Enabled, Gesture (DrawGestureView 56×56), Name, Description, Action, App Filter

- **Sources/Storage/** —
  - `PreferencesStorage` — thin wrapper around `UserDefaults` with typed getters/setters and `StorageDefaults` constants
  - `HistoryClipboardManager` — SQLite-backed clipboard history with top/pinned entries, pagination, expiry cleanup
  - `ClipboardHistoryManager` — simpler SQLite clipboard store (legacy?)

- **Sources/WindowManager/** — `WindowManager` (status bar), `Toast` / `ToastManager` (on-screen notes)

- **Sources/RightClickMenu/RightClickMenuManager.swift** — Manages FinderSync extension lifecycle:
  - Registers distributed notification observers (`CustomMessageReceivedNotification`, `RequestObservingPathNotification`)
  - Syncs enable flags + localized menu titles to extension via `SyncSharedDefaultsNotification`
  - Operations: create text file (`touch` + fallback AppleScript), open in terminal (`open -a`), copy path to pasteboard
  - Enables/disables extension via `pluginkit -e use|ignore -i net.mtjo.MacStroke.FinderSyncExtension`

- **Sources/FinderSyncExtension/FinderSync.swift** — `FIFinderSync` subclass:
  - Toolbar item with `toolbarIcon` image
  - Contextual menu items (New File, Open in Terminal, Copy Path) with images from asset catalog
  - Posts distributed notifications to main app on user actions

- **Sources/AppleScriptRunner/** — Executes AppleScript strings via `osascript`; provides preset actions (close-window, minimize, hide-app, launch Safari/Chrome/Terminal).

### Localization

- `L(key)` function in `Sources/Storage/Localization.swift` loads from `Resources/en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`
- Language persisted in `UserDefaults` key `language`; runtime switch posts `.languageDidChange` notification
- `applyUserLanguage(_)` updates `Bundle.main.preferredLocalizations`

### Important Implementation Notes

- **Rule is immutable** — never mutate `rule.template` or other `let` properties; always construct a new `Rule` and call `RuleStore.update(newRule)`
- **DrawGesture scaling** — `computeScaledPoints` uses `bounds.width/height` (not hardcoded constants); `layout()` override recomputes on bounds change; `clipsToBounds = true`, clear background
- **PreferencesView rules table** — uses `DrawGestureView` in gesture column (frame 56×56); table height fills available space (`maxHeight: .infinity` on scroll view)
- **Preset gesture workflow** — tap gesture cell → selects rule → opens `PresetGesturePickerView` sheet → "Apply to Selected" creates new `Rule` with chosen template
- **FinderSync communication** — uses `DistributedNotificationCenter` with `deliverImmediately: true`; menu items sync via shared `UserDefaults` keys (`enableRightClickMenu`, `enableNewFile`, etc.)
- **Accessibility permission** — checked at launch via `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`; shows modal alert with "Open System Settings" button
- **Sparkle** — `SPUStandardUpdaterController` initialized in `AppDelegate.initSparkleUpdater()`; feed URL is a placeholder (`https://example.com/updates/feed.xml`)

### Testing

- 7 test targets (one per library): `GestureEngineTests`, `EventCaptureTests`, `RuleEngineTests`, `StorageTests`, `WindowManagerTests`, `AppleScriptRunnerTests`, `RightClickMenuTests`
- All 105 tests pass (`swift test`)

### Files Not Present

No existing `CLAUDE.md`, `.cursor/rules/`, `.cursorrules`, or `.github/copilot-instructions.md` were found in the repository.