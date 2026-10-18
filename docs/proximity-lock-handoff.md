# 蓝牙靠近锁屏（BLE Proximity Lock）交接文档

分支：`feature/ble-proximity-lock`（从 `main` 的 `80b7d79` = 3.1.6 起）
状态：**代码写完、离线全绿、一次真链路都没跑过**。所有需要真蓝牙 / 真锁屏 / 真键盘注入的验证都在你的机器上。

这份文档的读者是「接手的人（大概率是我自己 + Qoder）」。它只记**代码里看不出来的东西**：
为什么这么设计、哪些是实测哪些是照抄上游、哪些坑我踩过、下一步按什么顺序做。
代码本身的注释已经写得很密，不重复。

---

## 0. 红线（先读这一节）

1. **这台无人值守的开发机绝不能被锁屏、绝不能被注入按键、绝不能弹蓝牙授权框。**
   它是远程执行的，边上没人。锁一次屏就等于把整条会话掐断。所以：
   - `ProximityLockController.shared.apply()` 在 main.swift 里接了，但**默认关 + 没选设备 = 不武装**，
     一个 `CBCentralManager` 都不构造，所以蓝牙 TCC 框不会在启动时弹；
   - 全部单测走假信号源 / 假会话 / 假注入闭包，没有一条测试会碰真蓝牙或真键盘；
   - `ScreenLockTests.testPrivateLockSymbolIsStillExported` 只 `dlsym` 拿地址，**不调用**。
2. **`ts1/BLEUnlock` 没有 LICENSE 文件**（默认版权保留）。只读它的机制和实测常数，
   **一行代码都没抄**。纪律和处理 GPL 的 `macshot` 时一样。
3. 自动解锁存的是**明文可还原的登录密码**（钥匙串里）。这条我提过是安全红线，
   用户明确要求做（「存密码自动解锁」）。所以默认关、界面上四条警告写明代价、
   日志里只记 OSStatus 和结果枚举，**永不记密码内容或长度**。
4. 私钥 / token / 密码一律不进仓库、不进对话。

---

## 1. 三条调研结论（用户问的「能不能做」）

### 1.1 「蓝牙断开就锁屏」——可行，且不需要任何授权以外的东西

macOS 没有公开的「立刻锁屏」API。可用的三条路：

| 路 | 结论 | 依据 |
| --- | --- | --- |
| 私有 `SACLockScreenImmediate()` | **采用** | `login.framework`（`/System/Library/PrivateFrameworks/login.framework/login`）导出。本机 `dlsym` 实测能拿到（`ScreenLockTests.testPrivateLockSymbolIsStillExported` 每次跑都验一遍，符号哪天没了测试就红） |
| 合成 ⌃⌘Q | **兜底** | keycode `0x0C` + `.maskControl`/`.maskCommand`，发到 `.cghidEventTap`。私有符号取不到时走这条 |
| 启动屏幕保护 | **已死** | Ventura 起 `CGSession -suspend` / screensaver 那条路不再锁屏，只黑屏 |

不需要 TCC（不是辅助功能、不是屏幕录制），但**兜底那条需要辅助功能授权**才能发事件。

### 1.2 「蓝牙连上就解锁」——没有免密码的接口，只能替用户把密码打进去

锁屏状态下唯一能解锁的东西就是那个密码框。我们录过一条实测证据：
锁屏时 `CGSSessionScreenIsLocked = 1`，`kCGSSessionSecureInputPID` 指向 `loginwindow`，
而**发到 `.cgSessionEventTap` 的 keyDown 全被丢掉** —— 必须发到 `.cghidEventTap`（在会话路由之前）。

所以「自动解锁」= 把存的登录密码逐字符注入 + 回车。这是 BLEUnlock 的做法，也是唯一做法。

### 1.3 「支持 BLE 设备吗 / 想支持手表」——支持，但分档

用 **只扫描、永不连接** 的做法（`scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])`）。
永不 `connect()` 是关键：连接会打断设备自己的省电策略、会被系统记成配对、也会让手表那边弹提示。

| 设备 | 预期 | 说明 |
| --- | --- | --- |
| Apple Watch | 最好 | 一直在发 BLE 广播，`CBAdvertisementDataLocalNameKey` 能拿到名字 |
| 小米 / Amazfit 手环手表 | **要一台一台试** | 很多型号只在「未被连接」时才发广播；被手机 App 连着就可能一条都收不到 |
| 华为 / 荣耀手表 | 同上 | 同上 |
| Garmin / WearOS / 其他安卓表 | 同上 | WearOS 一般发广播，但名字可能是随机化的 |

**扫不到就是没法用**，这不是 bug，界面上第四条警告写了。所以「扫描设备」那一格必须能把
收到的每一个候选都列出来（含 RSSI 和 UUID），用户才判断得出是「没发广播」还是「我们漏了」。

---

## 2. 已经做完的（这台机器上能做的都做了）

### 2.1 模块 `Sources/ProximityLock/`

| 文件 | 干什么 |
| --- | --- |
| `ProximityLockSettings.swift` | 偏好快照。照 `RemoteControlSettings` 的写法**读的时候重新校验并夹取**：两个 RSSI 阈值必须一起看（越界或滞回 < 5dB 就整对退回默认），因为「解锁 -90 / 锁屏 -60」这种反过来的组合会让人永远解不开锁 |
| `ProximityDecision.swift` | 纯逻辑状态机。滑动窗口均值 + 双阈值滞回 + 走开延时 + 信号超时。不碰蓝牙不碰屏幕，所以整条判定链能离线单测 |
| `ProximitySignalSource.swift` | 信号源协议 + `ProximitySample` / `ProximityDevice` / `ProximitySignalStatus`。单测靠它塞假帧 |
| `BluetoothProximityScanner.swift` | 真扫描器。**`CBCentralManager` 是懒构造的**（在 `start()` 里），因为 CoreBluetooth 没有 `requestAccess`，授权框是构造时系统弹的 —— 懒构造才能保证「用户没点扫描就不弹框」 |
| `ScreenLock.swift` | 锁屏原语 + 锁屏状态读取 + `isAcceptingPassword` 判定 |
| `PasswordInjector.swift` | 密码注入。分块 20 字符、每块前重查守卫、最多 3 次 |
| `UnlockPasswordStore.swift` | 钥匙串存取（`net.mtjo.MacStroke.proximitylock` / `login-password`），另有 `InMemoryPasswordStore` 给测试 |
| `ProximityLockController.swift` | 调度器。`shared` + `apply()` + `.macStrokeProximityLockDidChange`，照 `RemoteControlServer` 的生命周期写 |

常数取自 BLEUnlock 的长期实测（**只是数值，不是代码**）：
`unlockRSSI -60`、`lockRSSI -80`、窗口 5 帧、`signalTimeout 60s`、`lockDelay 5s`。

### 2.2 存储键（`Sources/Storage/Storage.swift`）

8 个键，全部登记进 `registerUserDefaultsDefaults()`：
`enableProximityLock`(false) / `proximityDeviceID`("") / `proximityDeviceName`("") /
`proximityUnlockRSSI`(-60) / `proximityLockRSSI`(-80) / `proximityLockDelay`(5) /
`proximitySignalTimeout`(60) / `proximityAutoUnlock`(false)。

### 2.3 偏好页

- `Sources/Preferences/ProximityLockTabView.swift`：三段，顺序是「先能开的 → 再是调的 →
  最后才是扫描出来的那一大坨」：①开关 + 状态 + 两个阈值/锁屏延迟/信号超时，②回来时自动解锁
  + 存密码 + 四条警告，③设备与扫描（当前设备行 + 候选列表）。列表放最后是刻意的 ——
  它原先夹在中间，一展开十几行就把「自动解锁」整段顶出可视区，看着像功能没做。
  当前设备行在**选中了设备**之后多一颗「移除设备」：这一套只存一台设备（`proximityDeviceID`），
  没有它的话想停掉判定只能去关总开关，下次要用还得重扫一遍。候选列表不是已保存的名录 ——
  30 秒收不到广播就自己掉出去（`BluetoothProximityScanner.pruneInterval`），所以列表里没有删除项。
  密码只停在页面的 `@State`，**不进 `UserPreferences`**
  （视图模型是整个偏好窗口共享的长命对象）。
- `PreferencesTab.proximityLock`，排在截图页之后、关于页之前，图标 `antenna.radiowaves.left.and.right`。
- `UserPreferences` 里 8 个 `@Published` + `selectProximityDevice(id:name:)` + `forgetProximityDevice()`，
  每个 didSet 都发通知
  （这一组和截图那组不同：人已经走开了才想起阈值不对，等下次启动生效没有意义）。
  「移除」只清 id/name 并发通知：id 一空 `isArmed` 就是假，App 侧 `apply()` 自己 `stop()`，
  界面不去手动关总开关。
- 文案：`en` / `zh-Hans` 的 `Localizable.strings` 各 54 条，`InfoPlist.strings` 各 1 条
  （`NSBluetoothAlwaysUsageDescription`，蓝牙授权框里唯一那句解释）。

### 2.4 App 接线（`Sources/MacStrokeApp/main.swift`）

```swift
ProximityLockController.shared.apply()
ProximityLockController.shared.isExternallyBusy = {
    !RemoteControlServer.shared.peers.isEmpty || ScreenshotController.shared.isActive
}
// + .macStrokeProximityLockDidChange → proximityLockSettingsDidChange → apply()
```

`isExternallyBusy` 是这一版新加的缝：**远程控制接管中、截图遮罩摊开时不锁屏**，
和 `pause(for:reason:)` 同效（走开计时清零）。手表搁在桌上信号一晃，
不该把正在进行的那场远程操作锁断。

### 2.5 打包（`build_app.sh`）

Info.plist 加了 `NSBluetoothAlwaysUsageDescription`。主 App **没有沙盒**
（只有 FinderSync appex 有 entitlements），所以不需要 `com.apple.security.device.bluetooth`，
只要 TCC 授权。

### 2.6 测试

**610 用例 / 1 skipped / 0 failures —— 那是交接机（Ventura 13.6 x86）上的数。**
新增：`Tests/ProximityLockTests/`（68 → 70 → 77 条）+ `Tests/WindowManagerTests/ProximityLockPreferencesTests.swift`（12 条）。

> **2026-10-17 macOS 27 这台闸门口径不一样，别拿 610/0 去对：**
> - `swift test --filter ProximityLockTests` **77/77 绿**；`ProximityLockPreferencesTests` **12/12 绿**。
> - 全量 `swift test`：**580 绿 / 25 红 / 12 skipped**。25 条红全在
>   Screenshot(19) / WindowManager(3) / Storage(1) / RemoteControl(2) 这四块，
>   **一条都不属于本功能**。已拿 `db99a68` 原样开一个 detached worktree 跑同样那批类复现：
>   **25 条红在 HEAD 上一模一样**（同一个类、同一条数），所以它们是这台机器的环境红，不是这轮改出来的。
>   成因看判据就知道是量像素/发真事件那一类：`("nan")`、`("0.0") is not greater than ("0.8")`、
>   「侧栏找不到高亮条，测量本身失效」—— 无窗口会话时这些量不到东西。
> - **但 HEAD 在这台跑不完**：`ProximityLockPreferencesTests.testPageRendersOffscreen`
>   会挂在钥匙串授权框上（见 §5「钥匙串这道门」那条），57 分钟 0% CPU 那种挂。
>   页面收下一个可注入的 `passwords` 之后才跑得通 —— 这条是为了能闸门，不是为了好看。

反向变异做过 11 次（A–G 在交接机上做过，H–K 在 macOS 27 这台重做并补了四条新的），
每一次都让套件变红（证明守卫都是承重的，不是装饰）：

| 变异 | 改了什么 | 结果 |
| --- | --- | --- |
| A | 冷启动 presence 从 `unknown` 改成 `absent` | 红（`testColdStartNeverLocks`） |
| B | 去掉 `isAcceptingPassword` 的入口守卫 | 红（注入类 3 条） |
| C | 去掉每块密码前的重查 | 红（`testAbortsMidTyping…`） |
| D | 窗口均值改成用最后一帧 | 红（`testSlidingWindowAbsorbsAShortDip`） |
| E | Esc 唤醒不再检查安全输入归属 | 红 |
| F | `lockDelay` 不生效 | 红 |
| G | 挂起时不清零走开计时 | 红 |
| H | 熄屏那道门取消（`performUnlock` 不再问 `isDisplayAsleep`） | 红（熄屏类 4 条，全打在黑屏上）· 2026-10-17 本机复做 |
| I | 亮屏补注入摘掉（`.none` 分支不调 `retryUnlockWhenDisplayWakes`） | 红（`testPendingUnlockIsRetriedOnceWhenTheDisplayWakes`）· 本机复做 |
| J | 补注入不清欠账（每次亮屏都重打一轮） | 红（同一条，实测报 `("11") is not equal to ("1")` —— 取消欠账就是每秒重打一遍密码）· 本机复做 |
| K | 提交后改回「只读一次」（`waitUntilUnlocked()` → `if !screen.isLocked`） | 红（注入类 2 条，实测报 `["hunter2","hunter2","hunter2"]`、`[36,36,36]`，正是真机那个三轮注入的形状）· 本机新增 |


---

## 3. 没做的 / 做不了的（按建议顺序）

### 3.1 真链路验证（**必须在你的机器上，边上有人的时候**）

按这个顺序，每一步都单独确认再往下走：

1. **构建装机**：`./build_app.sh`，装到 `/Applications`，`pluginkit` 那套照旧。
2. **蓝牙授权框**：偏好页 → 靠近锁屏 → 点「扫描设备…」。这时才会弹框。
   - 弹框文案应该是 `InfoPlist.strings` 里那句中文；
   - 授权之后如果页面还挂在「蓝牙未授权」，说明 `centralManagerDidUpdateState` 的
     `.poweredOn` 分支没重新 `resumeScan()` —— 先看 Console 里 `[ProximityLock]` 的日志。
3. **候选表**：把 Apple Watch 摘下来放桌上，看它出不出现、名字对不对、RSSI 大概多少。
   - 记下**贴着 Mac**、**同一张桌子**、**隔一堵墙**三个距离的 dBm，
     这是给用户写推荐阈值的唯一依据（现在 -60/-80 是 BLEUnlock 的数，未必合我们的场景）。
4. **只开锁屏半**（先别开自动解锁）：选设备 → 打开总开关 → 走开 → 数几秒锁屏。
   - 判据：`lastOutcome == .locked`，页面上「最近事件」显示「人已走开，屏幕已锁」；
   - 走回来 → 手动输密码解锁 → 页面 presence 应该悄悄回到「人在旁边」，**且不注入任何东西**
     （`testManualUnlockResyncsWithoutInjecting` 离线证过，真机再确认一次）。
5. **重复锁屏**：锁着的时候再走开一次，不该重复提交（`testNoDoubleLockWhenAlreadyLocked`）。
6. **App Nap**：锁屏之后等 10 分钟再走回来，看判定有没有被节流。
   `beginActivity(.userInitiatedAllowingIdleSystemSleep)` 是拦 App Nap 的，
   但**它不拦系统睡眠** —— 睡了就是睡了，`NSWorkspace.didWakeNotification` 会重新开扫。
7. **最后才开自动解锁**：存密码 → 走开 → 锁屏 → 走回来 → 看能不能自己解开。
   - **动手之前先证明辅助功能授权还在**：随便画一个手势，识别得到就是还在。
     每次重编译都是重新签名，TCC 那条记录有可能失效 —— 而**没有辅助功能权限时
     `CGEventPost(.cghidEventTap)` 的按键会被静默丢掉**，日志照样是
     「第 N 轮之后屏幕仍锁着 → exhaustedAttempts」，跟密码错、键码错长得一模一样。
     这一条我这边查不了（`~/Library/Application Support/com.apple.TCC/TCC.db` 没有全盘访问读不到）。
   - **走回来先别碰机器**：屏是熄的，这时页面上「最近事件」应该是
     「人已回来，但屏幕是熄的，等亮起来再解锁」（`lastOutcome == .waitingForDisplayWake`），
     日志一行 `人已回来，但屏幕是熄的，等亮起来再补注入`；**这一轮一个字都不该打**。
   - 然后碰一下触控板把屏弄亮 → 一秒内应该补上：日志 `屏幕已点亮，补那一次没打成的解锁`。
     **注入现在在后台队列上跑，结果最长晚 3.6 秒才落地**（回车之后要轮询 1.2 秒才判这轮成没成），
     所以别一亮屏就去读页面 —— 看日志里 `注入结果：submitted` 那一行，
     页面「最近事件」随后变成「已自动解锁」。**这两行就是这条功能成不成的判据。**
   - 日志出现 `第 1 轮之后屏幕仍锁着` ×3 → `exhaustedAttempts`：这时候屏幕上的画面才有诊断价值，
     三种样子分别对应三种原因（点串在长但不提交=键码；出现点串后抖动/清空/红字=密码错；
     框始终是空的=面板没唤起）。**这一条只有站在屏幕前才看得见，我这边的日志看不到画面。**
   - 亮屏后还是解不开 → 才轮到 3.2 的回车键码；提交 3 次都失败是
     `lastOutcome == .injectionFailed`（密码错或者密码框没接受）。
   - 熄屏期间他自己把锁解了 / 又走开了 → 欠账作废，下次亮屏不该凭空打一遍密码
     （`testPendingUnlockIsCancelledByAManualUnlock`、`testPendingUnlockIsCancelledWhenThePersonLeavesAgain`）。
   - 打不进去先看辅助功能授权；**再看有没有弹钥匙串授权框** —— 每次重编译签名都变，
     文件钥匙串的 ACL 就会重新问一次「MacStroke 想访问钥匙串项目 login-password」。
     不点允许，读密码那一步永远不返回（现在它跑在后台队列上，所以界面不冻，
     但解锁就是不动作，日志停在「屏幕已点亮，补那一次没打成的解锁」之后没有下文）。

### 3.2 提交键码：36 还是 52（**已结案：36 / `0x24`，真机 2026-10-18 16:52 第 1 轮就解开**）

BLEUnlock 发的是 virtualKey **52**（`0x34`），注释写「Return key」；HIToolbox 的 `Events.h` 里
`kVK_Return = 0x24`（**36**），52 在 `kVK_Delete = 0x33` 和 `kVK_Escape = 0x35` 之间，是个未分配的码。
两边打字的部分一模一样（`virtualKey 49` + `keyboardSetUnicodeString`、20 字符一块、keyUp 不带字符），
**唯一的实质差别就是这个提交键**。

> **2026-10-17 22:20 真机：前提「密码进了框」出现过，而且它解开了一个更大的疑点。**
> 那一次屏是亮的（不是熄屏闸门挡的，见 3.3），三轮注入全跑完，`exhaustedAttempts`。
> 但去问 loginwindow 的日志（命令在下面），整个 22:20:15–40 窗口里：
> - `LWPAMManager _beginServiceNamed:` **只有一次**，在 22:20:21.441 —— 那是人自己输密码那次；
> - `startUnlock:` 里 `_numFailedAuthAttempts = 0`；
> - 我们那三轮（17.37 / 18.6 / 19.97 附近）**一次认证服务都没启动**。
>
> ⇒ **「密码存错了」这个候选可以划掉**：密码不对会走到认证并失败，计数器不会是 0。
> 问题在「字符/回车根本没落到登录窗」这一侧。而 17.269 那次 `keyPressed:` 是人的按键，
> 它把隐藏的密码框刚唤出来（17.282 才 `makePasswordFieldFirstResponder`），我们 90ms 后就开打 ——
> 面板刚画出来这一点也还没排除。
>
> 取证命令（不用任何人盯屏幕，判据是机器可读的）：
> ```
> /usr/bin/log show --style compact --start "YYYY-MM-DD HH:MM:SS" --end "…+25s" \
>   --predicate 'process == "loginwindow"' | grep -E "keyPressed|_beginServiceNamed|numFailedAuthAttempts|PasswordField"
> ```
> 看三样：有没有 `makePasswordFieldFirstResponder`（框在不在）、有没有 `_beginServiceNamed`
> （**有没有真去认证**）、`_numFailedAuthAttempts` 是不是 0（0 = 一次都没提交成功过）。

**已结案（2026-10-18 16:52:48 真机）**：那一次「人已回来 → 屏已点亮 → 补注入」的日志写着
`第 1 轮解锁成功（提交键 0x24）` → `已自动解锁` → `注入结果：submitted`。
**赢的是最普通的 Return（0x24 / 36）**，BLEUnlock 那个 52 是输的一发。
实验装置已经拆掉：轮换没了，`PasswordInjector.submitKeyCode` 固定 0x24。
**每轮开打前的 `clearField()` 留着** —— 成功那一发本来就是带着它跑的，而且它管的是真实的一档子事：
上一轮中途守卫翻脸会留下半截密码在框里，不清掉下一轮必然接歪。

同一天日志里还有两条不是失败的失败，别把它们当回归：
- 16:57:07 `锁屏密码框不在前台，未注入密码`（`（锁屏=true 安全输入=无)`）——
  屏刚亮那一下面板还没拿到安全输入，这一发本来就该停手，一个字都没打。
  要治的是「亮屏之后等多久再打」，不是键码。
- 15:36:55 / 17:19:27 `屏幕已经解开，补注入取消` —— 人自己先解了，账销掉（见 3.2 末）。

三个键全失败时本来准备的下一个候选（面板刚画出来 90ms 就打 → 开打前加 settle 等待）这一版没用到，
但如果哪天在别的机器上复现「打了不提交」，那条仍然是第一候选。

> **2026-10-18 08:14 另外修掉的一条**：熄屏挂账之后人是自己解开的，代码把账销了**却没改口**，
> 界面上一直挂着「人已回来，但屏幕是熄的，等亮起来再解锁」而屏幕早就开了。
> 现在销账要同时报 `.unlockCancelledByHand` / `.unlockCancelledPersonLeft`。

### 3.3 macOS 26 / 27 的未知数

- ✅ **`CGSSessionScreenIsLocked` 在 macOS 27 上还在**（2026-10-17 本机实测，
  Darwin 27.0.0 / arm64）。锁着时字典里该键 = 1，两条分布式通知也都到
  （应用日志 01:47:52.712 `screenIsLocked`、01:50:39.407 `screenIsUnlocked`）；
  锁屏期间 `kCGSSessionSecureInputPID` 一直是 loginwindow（0.5 秒一行的采样，整段没翻脸）。
  所以通知缓存那条兜底**在 27 上没被触发过**，还是只能算离线证过。
  一个不对称要记住：**没锁的时候这个键压根不在字典里**（Ventura 也一样），
  也就是「解开」这一条边靠的是通知缓存 —— 冷启动恰好卡在锁屏上时，
  字典读不到键、通知又已经错过，会误判成「没锁」，方向上是保守的（不打密码）。
- 🔴 **本机实测到的新坑：锁屏后约 5 秒系统自己把屏关了，熄屏时注入是白打。**
  `pmset -g log` 两轮都对得上：01:33:26 锁 → 01:33:31 屏熄 → 01:33:55 那三轮注入
  → 01:36:24 才亮；01:47:52 锁 → 01:47:57 熄 → 01:48:35 注入 → 01:50:07 才亮。
  熄屏期间 `isAcceptingPassword` **仍然是真**（锁=1 + 安全输入=loginwindow），
  老守卫拦不住。已按「只在屏亮着时注入 + 亮起来补一次」改掉：`ScreenLock.isDisplayAsleep`
  （`CGDisplayIsAsleep(CGMainDisplayID())`，抽成可注入的缝）+ `Outcome.waitingForDisplayWake`
  + `retryUnlockWhenDisplayWakes()`，一次唤醒只补一轮，人又走开或他自己解了锁就销账。
- 🔴 **第二条链上的坑（改熄屏时自己撞出来的）：注入原来跑在主线程，而它等的那个通知
  正是主线程收进来的。** `startTimer()` 把 `tick()` 挂在 `RunLoop.main`
  （[ProximityLockController.swift:228](file:///Users/mtjo/work/MacStroke-Swift/Sources/ProximityLock/ProximityLockController.swift#L228)），
  以前同步打密码最长占住主线程 1.2 秒（`settleDelay` 0.4 × 3 轮），加了轮询之后是 3.6 秒。
  问题是 macOS 27 上解开的那一瞬间字典里那个键**消失**了，`isLocked` 只能回落到达通知缓存，
  而通知要主线程空出来才送得进来 —— 于是**一次成功的注入也会被轮询读成失败**，
  接着排第二轮。修法：注入挪进串行后台队列、结果回主线程报（`runInjection` 那道缝），
  `ScreenLock.notificationLocked` 因此加了 `stateLock`（主线程写、后台读）。
  顺带把「偏好页开着时界面冻三秒半」和「钥匙串读取弹窗卡死 UI」一起消掉了。
  为什么不起第二轮不用在途标志：`PasswordInjector` 每轮开头本来就有入口守卫，
  屏幕已解开的那一轮一个字都不会打；队列又是串行的，两轮不会交错。
- 上游 issue #169：锁屏后**唤醒显示器**在有些版本上失败（屏幕黑了但不亮密码框）。
  我们的选择是**不主动唤醒**，等用户自己碰一下键盘/触控板把屏弄亮再补注入。
  如果实测下来「人不碰机器就不解」这个体验不能接受，再考虑 `CGDisplayWake` / IOKit
  `HIDPostEvent`，并且唤醒本身也要有守卫。

- 上游还报过 MediaRemote 段错误 —— 我们没碰 MediaRemote，无关。

### 3.4 Apple Watch「自动解锁」打架

系统自带的 Watch 自动解锁需要 Apple Silicon / T2。**本机是 x86 且没有 T2，测不了。**
如果用户两边都开着，系统的可能在我们锁屏之后马上把屏幕解开（或者反过来）。
界面上第三条警告已经写了「只留一个」。**这条只能靠用户实测反馈。**

> **交接机（macOS 27，MacBook Pro M5 Pro）是 Apple Silicon，这条在那台能测**：
> 系统设置 → 触控 ID 与密码 → 「使用 Apple Watch 解锁」开着，再走一轮 §3.1 第 7 步。
> 判据是两边的抢：我们锁屏后如果几秒内自己解开且日志没有 `unlocked`，就是系统那条赢了；
> 反过来我们注入之后又立刻被锁回去，也要照样记下来。

### 3.5 每型手表的测试矩阵（用户点名要支持的四类）

| 设备 | 扫得到吗 | 名字 | RSSI 距离曲线 | 走开锁屏 | 回来解锁 |
| --- | --- | --- | --- | --- | --- |
| Apple Watch | ? | ? | ? | ? | ? |
| 小米 / Amazfit | ? | ? | ? | ? | ? |
| 华为 / 荣耀 | ? | ? | ? | ? | ? |
| Garmin / WearOS | ? | ? | ? | ? | ? |

「扫得到吗」是**唯一的门槛**：扫不到的机型后面三列都不用填。
填完这张表就能决定 README / 更新说明页里怎么写「支持哪些设备」。

### 3.6 还没接的东西（可选）

- **状态栏菜单入口**：粘贴板、远程控制、截图三项都有（`statusMenuItem(to:titleKey:tab:)`），
  靠近锁屏还没加。加不加看用户要不要「一键临时停用」。
- **`pause(for:reason:)` 目前没人调**（`isExternallyBusy` 那条缝替代了它）。
  录屏 / 长截图期间要不要也挂起？现在 `ScreenshotController.isActive` 已经覆盖了遮罩摊开的整段时间，
  但**录屏是后台跑的**，遮罩收了之后 `isActive` 就是 false 了 —— 录一段 10 分钟的屏，
  人坐在旁边不动，手表信号稳，理论上不会锁；但如果录屏时人走开了，会锁。
  要不要在录屏期间也挂起，是个产品决定，我没替用户做。
- **偏好页的「恢复默认」没包含这 8 个键**（远程控制、截图那两组也一样没包含）。
  要保持一致就别加；要加就三组一起加。

---

## 4. 关键设计决定（为什么不是别的样子）

1. **冷启动是 `unknown`，而且从 `unknown` 绝不锁屏。**
   程序刚起来时手表可能压根不在旁边，那不是「走开」。这一条是
   「不该锁的时候一次都别锁」的底线，`testColdStartNeverLocks` 盯着它
   （喂 300 秒 -95 也不锁；一条广播都不喂也不锁）。
2. **「设备消失」只能是计时器。** CoreBluetooth 永远不会告诉你「它走了」，
   收不到广播和「设备就在旁边但省电不发」在 API 层完全一样。所以 `signalTimeout` 是必需的，
   而且它算「走开」。
3. **状态一切换就清空滑动窗口。** 留着旧样本会让新状态在第一帧就被旧数据推翻，来回弹。
   副作用：切完之后 `smoothedRSSI` 是 nil，第一帧均值就是那一帧 —— 这是有意的。
4. **注入守卫是双条件，而且每块密码前重查一次。**
   `isAcceptingPassword = isLocked && (安全输入 PID 的进程名 == "loginwindow")`。
   这是对 BLEUnlock issue #182（密码被注入到别的应用的输入框里，明文泄露）的修法：
   - 只要屏幕解锁了，或者安全输入换了主人（比如用户切到了终端的 `ssh` 密码提示、
     或者 1Password 的解锁框），**当场中止整个注入**；
   - Esc 唤醒密码框也只在「锁着 **且** 没有任何进程持有安全输入」时才发
     （否则这个 Esc 会打到别人的模态框上）；
   - 最多 3 次（`maxAttempts`），防止密码错时无限重试撞锁屏。
5. **走开只锁一次。** `.lock` 这个动作在 `present → absent` 的跳变上发一次，
   之后 presence 停在 absent，不会再发。所以「锁着的时候又走远了一点」不会重复提交。
6. **手动解锁要能悄悄纠正状态。** `tick(screenLocked:)` 里 `.absent` 分支只在
   `screenLocked` 为真时返回 `.unlock`，否则只把 presence 改回 `.present` ——
   用户自己输了密码，我们不该再注入一次。
7. **忙的时候不 tick，而不是 tick 完丢掉结果。** 如果照常 tick 再把 `.lock` 扔掉，
   presence 已经翻成 absent 了，忙完之后状态机在 absent 上等着「变强」才发 `.unlock`，
   **那次锁屏就永远丢了**。所以现在忙时直接不调 `decision.tick`，只 `cancelPendingLock()`，
   presence 停在原状态（`testExternallyBusyKeepsTheReadoutButNotThePresence` 盯着这条）。
8. **控制器交出的是枚举 `Outcome`，不是文案。** 文案要跟着偏好页语言走（`L()`），
   而单测需要一个不会被本地化改写的稳定判据 —— 让测试去比 `L(key)` 等于让被测对象自己出题自己判卷。

---

## 5. 踩过的坑（别再踩）

- **`keyboardGetUnicodeString` 会把没有 unicode 串的事件按当前键盘布局翻译出隐形控制符**
  （0x1b / 0x0d）。测试里断言「打了什么字」只能看 keycode 49 的事件，
  别的键码单独记一份（`EventRecorder.typedChunks` vs `controlKeyCodes`）。
- **`static` 方法不能出现在默认参数里**（"is internal and cannot be referenced from a
  default argument value"）。`ScreenLock.init` 因此收可选闭包，在函数体里解默认值。
- **`controller.apply()` 不带参数会去读真的 UserDefaults**。测试里必须先把注入的那份
  存成 `currentSettings` 再 `apply(currentSettings)`，否则测试之间会互相污染。
- **didSet 里赋回 oldValue 会再触发一次 didSet**（写库 + 发通知各多一次）。
  这和 `remoteControlPort` 的行为一致，是无害的（写回去的就是原值，`apply()` 看到设置没变不重启），
  但测试的判据要取「库里最终是什么」，不能取「通知来过几次」。
- **钥匙串这道门在无头测试里会把整个闸门挂死**（2026-10-17 本机：`swift test` 跑了
  57 分钟不动，`ps` 一看 0% CPU 睡着）。根因不是慢，是弹窗：`ProximityLockTabView`
  的 `onAppear` 读 `hasPassword` → `SecItemCopyMatching` → `SecKeychainItemCopyContent`，
  而 `kSecUseAuthenticationUI: skip` 那个旗只管数据保护钥匙串，
  **文件钥匙串的 ACL 不认** —— 签名一变（每次重编译都变）就是「某某想访问钥匙串项目」，
  有人值守点一下就行，`xctest` 里没人点就永远挂在那行。
  诊断办法别再猜：`/usr/bin/sample <pid> 1 -f /tmp/x.txt` 直接看主线程栈停在哪个测试的哪一行。
  已把 `passwords` 做成 `ProximityLockTabView.init` 的可注入参数（默认还是真钥匙串），
  测试里换 `InMemoryPasswordStore`。**别为了跑测试去删钥匙串里那条 `login-password`。**
- **zsh 里 `echo ====` 会炸**（equals expansion），分隔线用 `echo "-----"`。
- **变异测试的输出别 grep `Executed [0-9]+ tests`** —— 单条时是 "Executed 1 test"，
  正则匹配不上会以为没跑。grep `^Test Suite 'Selected tests'`。

---

## 6. 一句话给下一轮

代码层面这条线是完整的、离线可证的（本功能 77+12 条全绿，11 次反向变异全被抓）。
真机上已经抓到并改掉了两个会让「解锁」这半边永远不成的死结：**锁屏 5 秒后屏就熄了，
打给黑屏是白打**；**注入占住主线程，等的那条解锁通知因此送不进来，成功也会被读成失败**。
剩下的全是**只能在有人值守的真机上做的事**：蓝牙授权、四类手表的扫描矩阵、
真锁屏、真注入（§3.1 第 7 步，现在按「先等屏亮、再看日志」走）、回车键码 36 还是 52、
以及 macOS 26/27 上锁屏状态读取的兜底路径。
按 §3.1 的顺序走，每步单独确认。
