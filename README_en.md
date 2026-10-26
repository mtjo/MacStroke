MacStroke
================================

[中文版](https://github.com/mtjo/MacStroke/blob/main/README.md)

![MacStroke](https://github.com/mtjo/MacStroke/raw/release/logo.png)

### Configurable global mouse gesture for macOS.
> MacStroke is a gesture-recognition application for macOS. A gesture is a movement you make with the mouse while holding down a specific mouse button. If MacStroke recognizes the stroke, it performs the action attached to it.
> Today that means: emulate a key or shortcut, type text or a password, run an AppleScript, click at a coordinate, copy text into the clipboard, or open the screenshot capture. On top of the gestures, 3.x adds the clipboard history, phone remote control over the LAN, screenshot / scrolling screenshot / screen recording, Bluetooth proximity lock, and a bubble on selected text. MacStroke tries to provide an intuitive and efficient user interface while remaining highly configurable and offering many advanced features.

## Versions and system support

| Version | Source branch | Requirement | Status |
| --- | --- | --- | --- |
| **3.0.0 and later** (current **3.2.3**) | [`main`](https://github.com/mtjo/MacStroke/tree/main) (Swift rewrite) | **macOS 13 Ventura or later** | Maintained line. Universal binary (native Apple Silicon + Intel); the interface and the interactions stay the same as the original |
| 2.0.5 and earlier | [`master`](https://github.com/mtjo/MacStroke/tree/master) / `release` (Objective-C) | macOS 10.10 or later | No longer maintained; kept only as a fallback for old systems |

- **Upgrading from the old build works in place:** 2.0.5 and earlier find 3.0.0 through "Check for Updates" inside the app, because the update feed is shared (every entry carries both the Sparkle 1.x DSA signature and the Sparkle 2 EdDSA signature). Rules, AppleScripts and the clipboard history are read from the same storage, so nothing has to be migrated.
- **Systems below macOS 13 never see the upgrade:** the feed declares `minimumSystemVersion 13.0`, so macOS 12 and older stay on 2.0.5. Upgrade the OS first if you want the new features.
- **Re-grant Accessibility after the upgrade:** the Swift build is a different binary identity, so macOS may ask for permission again (see below).
- The version number lives in exactly one place, `APP_VERSION` at the top of [`build_app.sh`](build_app.sh); packaging, the appcast entry and the release notes page all read it. Per-version changes are in [`Changelog/`](Changelog) (Chinese and English).

> Building from source: the Swift target needs a macOS 13 deployment target (`.macOS(.v13)` in `Package.swift`); the Sparkle dependency itself requires macOS 12 or later.

## Permissions

### Since 10.14 you have to add the app under System Settings -> Privacy & Security -> Accessibility. Without it nothing works.

![Permissions](https://github.com/mtjo/MacStroke/raw/release/help.png)

### "Screen Recording" is only needed by two things: the remote-control thumbnail, and screenshot / recording

macOS asks once. If you clicked "Don't Allow" it never asks again and silently hands back a picture of the wallpaper, which looks like a broken feature. So both paths check the state themselves and, when the grant is missing, show a button that jumps straight to Privacy & Security -> Screen Recording; after granting, the app has to be restarted once. Pure gesture use needs no such permission.

The mode bar at the top of the screenshot mask has four positions: screenshot, scrolling screenshot, record, extract text. Scrolling capture and recording have to give the screen back to the app being operated, so the mask disappears as soon as the selection is final and only an outline plus one control pill stay — neither layer is captured, so neither shows up in the output. Long screenshots work by injecting wheel scroll into the middle of the selection; recording uses AVCaptureScreenInput on the selected region and writes MP4. Neither carries audio.

Everything you draw — arrows, boxes, text — stays editable afterwards: click on an annotation to edit that one (the four corners and the edge handles resize, dragging the body moves it, Delete removes just that item) without un-selecting the tool first; the stroke you just finished is already in the selected state. Selecting a tool pops its property panel above it, with seven preset colors plus a custom one, and each tool remembers its own thickness and color (an arrow wants to be thick, a box thin — no need to re-tune every stroke); text also has font size, bold, italic, border and background. Those values live only inside this screenshot — closing the mask resets to red at the default thickness. Double-clicking existing text lays an input box over the original to change the content only; position and size stay put.

### "Bluetooth" is only used by the Proximity Lock page

The first click on "Scan for devices" triggers the system Bluetooth prompt; auto-unlock additionally needs Accessibility (Input Monitoring alone is not enough). While the master switch is on but no device is picked, nothing is armed — the app does not even construct a central manager, so it asks for nothing. Remote control adds no privacy declaration at all (the bundled Info.plist carries only the Bluetooth one): it just listens on a port on this Mac, shows the local address and the pairing QR codes in the UI, and never goes through a server. The only part of that page that needs Screen Recording is the desktop thumbnail.

### If repeated upgrades leave incompatible old data behind and the app crashes on launch, clear the old data and start again: General -> Reset to defaults, then quit and reopen manually — or delete ~/Library/Preferences/net.mtjo.MacStroke.plist and reopen.

### Preset gestures

![Preset gestures](https://github.com/mtjo/MacStroke/raw/release/MacStroke.gif)

## What this version has (in the order of the 12 pages on the left of Preferences)

The eight pages from the original keep their behavior and layout as they are. The four extra pages are port additions, all off by default — when off they do not even install a listener, so recognition time and latency are identical to a build without these features.

| Page | What it controls | Since |
| --- | --- | --- |
| General | Trigger button (right by default; middle, side or a custom button also work), sensitivity, release response, "Hold Modifiers To Skip Gesture" (gestures pause while the chosen modifiers are held, so keyboard shortcuts do not fire by accident), gesture note (show note icon, note color), import/export, reset to defaults | 3.0.0, 3.1.x |
| Rules | One action per gesture: shortcut, key/text/password input, AppleScript, click at coordinate, copy to clipboard, open screenshot; per-app rules (filter); pick the shape from the preset gesture icon grid | 3.0.0 |
| Filters | Blacklist / whitelist, one app per line — which apps don't get gestures at all | 3.0.0, fixed in 3.2.3 (lists were lost on restart) |
| AppleScript | Script list and migration, `sdef` so external scripts can call it (`openPreferences` etc.) | 3.0.0 |
| RightClick | The original page: a column of bundle IDs, `*` wildcards supported (e.g. `com.jetbrains.*`). In an app on this list, a trigger-button press with no drag that matches no rule makes MacStroke synthesize Ctrl+left-click so the app shows its own context menu; apps not on the list just get the button replayed | 3.0.0 |
| Right-click extras | Master switch plus three sub-switches (new text file, open in terminal — Terminal/iTerm —, copy file path); the bundled Finder Sync extension reads exactly this. Two sections hang below it: "trigger button + wheel" (up and down each get one action: previous/next tab, volume ±1 step, custom shortcut. One notch counts as one trigger and that notch is swallowed, so the page doesn't scroll with it; once the wheel fired, releasing no longer opens the menu and the half-arc you drew along the way is not fed to the matcher) and "gesture lands on the window under the cursor" (3.2.2, off by default; on, the app owning the window under your release point gets the rule match and the keystrokes, with an option to hand focus back afterwards; off, the on-screen window list is never captured at all) | 3.0.0, 3.2.1, 3.2.2 |
| Clipboard | History entries (images and file entries included), dedup and pinning, retention count and cleanup | 3.0.0, 3.1.x |
| Remote Control | Drive this Mac from a phone on the same LAN: the mini program's live desktop thumbnail, taps and drags, keyboard and shortcuts, wheel. The page shows the local address, the pairing QR code and the mini-program code | 3.1.0–3.1.3 |
| Screenshot / Record | Save location, default shortcut (⌘⇧A), magnifier zoom, the four mode-bar positions (screenshot / scrolling screenshot / record / extract text), annotation tools with in-place editing, Vision text recognition | 3.1.4–3.1.9 |
| Proximity Lock | The Bluetooth device you wear is the key: the screen locks when you walk away and can unlock itself when you come back (the password lives in this Mac's keychain; off by default). Presence is decided with a two-threshold hysteresis, and the gap, the dwell seconds and the lost-device timeout are all tunable | 3.1.7 |
| Selection Bubble | Selecting text pops a four-cell pill: copy, search, translate, read aloud. Two triggers — release after a left-drag selection, or ⌃⌘B (default), which asks the focused element for its current selection; "which engine to search with" is configurable (6 engines + 8 web AIs + a custom URL template); apps with no accessibility outlet (Mail bodies) can have ⌘C pressed for you once; pages that won't take the query in the URL can turn on "paste ⌘V once after opening" | 3.2.0 |
| About | Version, update check cadence and the gentle reminder, "skipped versions" and restoring the reminder | 3.0.0, 3.1.2–3.1.3, fixed in 3.2.1 |

The status bar menu is: Preferences, Clipboard (opens the history panel directly, not the preferences window), Screenshot / Record (opens the mask directly), Remote Control (lands on that page), Check for Updates, Quit. When a new version has been found in the background there is an extra "Update Available: x.y.z" on top, and clicking it is what brings the update window forward. The Clipboard, Screenshot / Record, Remote Control and Check for Updates items are all port additions — the original menu had Preferences and Quit only. Finder's menu entries come from the bundled Finder Sync extension, which reads the switches on the "Right-click extras" page. Updates run on Sparkle, and every feed entry carries both DSA and EdDSA signatures, which is how 2.0.5 can still receive 3.x.

## Download & Install

Installer: [MacStroke](https://github.com/mtjo/MacStroke/releases/latest)

homebrew
```
brew tap mtjo/tap
brew install --cask mtjo/tap/macstroke
```

> Write the full token `mtjo/tap/macstroke`. The identically named cask in homebrew-cask itself was marked `disable! date: "2026-09-01", because: :fails_gatekeeper_check` (release builds use a self-signed certificate, so `spctl` rejects them), and it is still pinned at 2.0.5 — plain `brew install --cask macstroke` only tells you the cask is disabled. My own tap is not affected.
>
> The first launch still gets stopped by Gatekeeper once (self-signed, no Developer ID): right-click the app -> "Open", or run `xattr -dr com.apple.quarantine /Applications/MacStroke.app`.
>
> To bring the official cask back: move the release build to a Developer ID signature plus notarization, then send homebrew-cask a PR bumping the version and dropping `disable!`. After installing, remember to grant Accessibility by hand (see "Permissions" above).

### Feedback
[Bugs & suggestions](https://github.com/mtjo/MacStroke/issues)

### If the software is useful, share it with your friends and family — and a star and a fork help (homebrew has hard requirements about it)
### If the software is useful, share it with your friends and family — and a star and a fork help (homebrew has hard requirements about it)
### If the software is useful, share it with your friends and family — and a star and a fork help (homebrew has hard requirements about it)
![homebrew](https://github.com/mtjo/MacStroke/raw/master/homebrew.png)

Power by [![mtjo](https://github.com/mtjo/MacStroke/raw/release/logo-mtjo.png)](http://mtjo.net)

---

## Source and build (Swift version)

- Swift 5.9+, Swift Package Manager, SwiftUI + AppKit mixed UI, SQLite.swift for persistence
- The event layer is CGEventTap: one tap captures gestures, the wheel trigger uses a second one that is created disabled and only armed while the trigger button is held; injected events always go through the session layer
- Recognition is DTW template matching, actions come from the rule table, rules can be filtered per app (bundle ID)

```bash
swift build            # compile
swift test             # unit tests (each module has a same-named *Tests target; needs a toolchain with XCTest)
./build_app.sh         # produce MacStroke.app (universal binary + embedded Sparkle + Finder extension)
./make_release.sh      # produce the release zip and the dual-signed appcast entry (release_out/)
```

```
Sources/
  GestureEngine/       # Stroke / GesturePoint / GestureMatcher (DTW) / preset gestures
  EventCapture/        # CGEventTap global capture, wheel reading and throttling
  RuleEngine/          # Rule / RuleAction / ActionExecutor / wheel action lookup
  Storage/             # PreferencesStorage / HistoryClipboard / localization
  Preferences/         # SwiftUI preference pages
  WindowManager/       # ToastManager / WindowManager / shortcut recorder
  AppleScriptRunner/   # AppleScript execution and script list
  RemoteControl/       # LAN TCP service, click/keyboard/wheel synthesis, screen capture streaming
  Screenshot/          # frozen-frame capture, selection mask, annotation model and compositing, scrolling capture, recording, OCR
  ProximityLock/       # Bluetooth presence state machine, lock and injected unlock
  SelectionPopup/      # reading the selected text (Accessibility, with several fallbacks), the four-cell bubble
  RightClickMenu/      # context menu construction
  FinderSyncExtension/ # Finder right-click extension
  MacStrokeApp/        # app entry point and wiring
Tests/                 # per-module unit tests
docs/                  # release and evidence ledgers (signing, issues #22/#75/#76, selection bubble, proximity-lock handoff)
```

Notes on local development and the self-signed certificate: [docs/signing.md](docs/signing.md) (Chinese).
