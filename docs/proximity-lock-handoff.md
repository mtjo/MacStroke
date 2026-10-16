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

- `Sources/Preferences/ProximityLockTabView.swift`：两段 —— 盯哪台设备/多远算走开/多久锁屏，
  和「回来时自动解锁 + 存密码」。密码只停在页面的 `@State`，**不进 `UserPreferences`**
  （视图模型是整个偏好窗口共享的长命对象）。
- `PreferencesTab.proximityLock`，排在截图页之后、关于页之前，图标 `antenna.radiowaves.left.and.right`。
- `UserPreferences` 里 8 个 `@Published` + `selectProximityDevice(id:name:)`，每个 didSet 都发通知
  （这一组和截图那组不同：人已经走开了才想起阈值不对，等下次启动生效没有意义）。
- 文案：`en` / `zh-Hans` 的 `Localizable.strings` 各 50 条，`InfoPlist.strings` 各 1 条
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

**610 用例 / 1 skipped / 0 failures**（基线 528 → 3.1.6 时 596 → 现在 610）。
新增：`Tests/ProximityLockTests/`（68 → 70 条）+ `Tests/WindowManagerTests/ProximityLockPreferencesTests.swift`（12 条）。

反向变异做过 7 次，每一次都让套件变红（证明守卫都是承重的，不是装饰）：

| 变异 | 改了什么 | 结果 |
| --- | --- | --- |
| A | 冷启动 presence 从 `unknown` 改成 `absent` | 红（`testColdStartNeverLocks`） |
| B | 去掉 `isAcceptingPassword` 的入口守卫 | 红（注入类 3 条） |
| C | 去掉每块密码前的重查 | 红（`testAbortsMidTyping…`） |
| D | 窗口均值改成用最后一帧 | 红（`testSlidingWindowAbsorbsAShortDip`） |
| E | Esc 唤醒不再检查安全输入归属 | 红 |
| F | `lockDelay` 不生效 | 红 |
| G | 挂起时不清零走开计时 | 红 |

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
   - 打不进去先看辅助功能授权；
   - 打得进去但不提交 → 见 3.2 的回车键码；
   - 提交 3 次都失败 → `lastOutcome == .injectionFailed`，密码错或者密码框没接受。

### 3.2 回车键码：36 还是 52（**一个待做的真机实验**）

BLEUnlock 发的是 virtualKey **52**，注释写「Return key」；
但 HIToolbox 的 `Events.h` 里 `kVK_Return = 0x24`（**36**），52 在 `kVK_Delete = 0x33`
和 `kVK_Escape = 0x35` 之间，**是个未分配的码**。我在 BLEUnlock 全仓 grep 过 `0x24`/`36`，一个都没有。

我们现在用 36（`PasswordInjector.submitKeyCode`，可配）。
**真机实验**：如果密码打进去了解不开，把 `submitKeyCode` 改成 52 再试一次，
把结果记回这一节。别两条都发（会打两个回车，第二次可能落到桌面）。

### 3.3 macOS 26 / 27 的未知数

- 上游 BLEUnlock PR #190 说 `CGSSessionScreenIsLocked` 在 macOS 26 的
  `CGSessionCopyCurrentDictionary` 里**被移除了**。我们的 `ScreenLock.isLocked`
  已经做了兜底：会话字典里没这个键就回落到 `com.apple.screenIsLocked` /
  `com.apple.screenIsUnlocked` 两条分布式通知喂的缓存
  （内部缝 `noteLockState(_:source:)`，`testFallsBackToDistributedNotificationsWhenTheKeyIsGone` 离线证过）。
  **但这条兜底在 26/27 上没实测过。** 本机是 13.x（22.6.0 = Ventura）。
- 上游 issue #169：锁屏后**唤醒显示器**在有些版本上失败（屏幕黑了但不亮密码框）。
  我们现在只在「已经锁着且安全输入属于 loginwindow」时注入，**没有主动唤醒显示器**。
  如果真机上发现走回来屏幕不亮、密码打不进去，就要补一次唤醒
  （`CGDisplayWake` 或 IOKit 的 `HIDPostEvent`），并且唤醒本身也要有守卫。
- 上游还报过 MediaRemote 段错误 —— 我们没碰 MediaRemote，无关。

### 3.4 Apple Watch「自动解锁」打架

系统自带的 Watch 自动解锁需要 Apple Silicon / T2。**本机是 x86 且没有 T2，测不了。**
如果用户两边都开着，系统的可能在我们锁屏之后马上把屏幕解开（或者反过来）。
界面上第三条警告已经写了「只留一个」。**这条只能靠用户实测反馈。**

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
- **zsh 里 `echo ====` 会炸**（equals expansion），分隔线用 `echo "-----"`。
- **变异测试的输出别 grep `Executed [0-9]+ tests`** —— 单条时是 "Executed 1 test"，
  正则匹配不上会以为没跑。grep `^Test Suite 'Selected tests'`。

---

## 6. 一句话给下一轮

代码层面这条线是完整的、离线可证的（610 绿 + 7 次反向变异全被抓）。
剩下的全是**只能在有人值守的真机上做的事**：蓝牙授权、四类手表的扫描矩阵、
真锁屏、真注入、回车键码 36 还是 52、以及 macOS 26/27 上锁屏状态读取的兜底路径。
按 §3.1 的顺序走，每步单独确认。
