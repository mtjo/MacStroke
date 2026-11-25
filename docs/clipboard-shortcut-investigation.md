# 粘贴板快捷键「经常失效」取证（2026-11-25）

报障原话：「粘贴板的快捷经常失效，现在就是失效的」「⌥⌘V 才是默认，你不要修改我的默认按键」。

## 结论

一共两条，按证据强弱排：

1. **失效的直接原因：库里的绑定不是 ⌥⌘V，而是 ⌃⌘A。** App 只认库里的值，所以按
   ⌥⌘V 永远不会响。默认值（`Sources/Storage/Storage.swift:379`，
   `keyCode=9, flags=1572864` = ⌥⌘V）从 `a159558` 起就没变过；但启动时
   偏好里的旧值优先，改代码里的默认值压不回来。
2. **「经常」的那一档：tap 被系统停用后没人兜底（潜在，本机没抓到现场）。**
   `kCGEventTapDisabledByTimeout` / `ByUserInput` 时旧代码只在回调里原地重开；
   主线程正忙那一下伪事件排不上队，tap 就停在「`isMonitoring` 还是 true、但一个键
   都收不到」的状态，只能重启 App。这回加了 2 秒一次的巡检兜底。

库里那个 ⌃⌘A 是怎么写进去的：**代码里没有任何默认值、迁移或重置路径会写出
`keyCode=0, flags=1310720`**（`git log -S` 全库只有划词气泡的 ⌃⌘B 碰过
`1310720` 这个数）。能写这个键的只有偏好页那个录制框
（`Sources/Preferences/PreferencesView.swift:1885`）—— 框是「点一下即进入录制、
按任何键即落盘」，界面上也不标「当前值 ≠ 默认值」，误碰一次就静默改掉了。

## 证据

### 库里一直是 ⌃⌘A（11-24 14:15 起，连续 6 次启动）

```
2026-11-24 14:15:45 [ShortcutMonitor] Started monitoring keyCode=0 flags=1310720   ← 粘贴板（⌃⌘A）
2026-11-24 14:15:45 [ShortcutMonitor] Started monitoring keyCode=0 flags=1179648   ← 截图（⌘⇧A）
2026-11-24 14:15:45 [ShortcutMonitor] Started monitoring keyCode=0 flags=655360    ← 提取文字（⌥⇧A）
2026-11-24 14:15:45 [ShortcutMonitor] Started monitoring keyCode=11 flags=1310720  ← 划词气泡（⌃⌘B）
…11-24 14:26 / 14:33 / 16:45 / 17:46、11-25 09:38 五次启动全是同一组
```

`⌥⌘V` 应该长这样：`keyCode=9 flags=1572864`（原版 DefaultPreferences.plist 的
SRShortcut 原值）。键码都不一样，命中条件第一关就被刷掉。

### 10:57 库里换成 ⌥⌘V 之后，物理按键立刻命中并开窗

```
10:57:09  net.mtjo.MacStroke.plist 落盘（库里改成 keyCode=9, flags=1572864）
10:57:11.410  Matched keyCode=9 flags=1573160   ← 1573160 = 1572864 + 设备位，掩码 0x1E0000 后相等
10:57:11.438  order window front conditionally: 322
10:57:11.747  Matched keyCode=9 flags=1573160   ← 连按第二下：旧窗 322 关、新窗 324 开（原版行为）
10:58:17.515  Matched keyCode=9 flags=1573160
10:58:17.549  Window … windowNumber=32c ordered front
```

### 探针复验（本轮装机前，进程 11757）

只读 tap 注入一次 ⌥⌘V，MacStroke 侧：

```
PROBE saw keyDown keyCode=9 flags=538443776
[ShortcutMonitor] Matched keyCode=9 …
WIN number=824 layer=21 alpha=1 bounds={660x480}   ← +1s 在屏
WIN number=824 layer=21 alpha=1 bounds={660x480}   ← +6s 仍在屏（不是闪一下就没）
```

### 装新包后复验（进程 27515）

```
11:39:33  Started monitoring keyCode=9 flags=1572864     ← 粘贴板按默认 ⌥⌘V 挂上（不再是 ⌃⌘A）
11:39:45  Matched keyCode=9 flags=538443776 → window 1806（660×480, layer 21）
11:39:57  Matched keyCode=9 flags=538443776 → 旧窗关、新窗 1811（连按 = 重开，原版行为）
```

两分钟里巡检没有打过一行 `Health:`，说明 2 秒节拍没在乱重建。
注入的 Esc/点击在探针这条路上送不到 App 的窗口（合成事件只验到 tap 那层），
所以「Esc 关窗、打字过滤」仍归装机清单。

### tap 停用这一档本机没有现场

`log show --last 20h` 里 `Tap disabled` 与 `Failed to create event tap` 都是 0 条，
所以第 2 条是**按代码路径定的潜在洞**，不是本次的触发原因 —— 不写成「已实测复现」。

## 改动

`Sources/EventCapture/ShortcutMonitor.swift`

- `start()` 里挂 2 秒一次的健康巡检（`healthInterval`，RunLoop `.common` 模式）；
  `stop()` 里拆掉。
- 巡检判定抽成纯函数 `healthAction(hasTap:portIsValid:tapIsEnabled:)` →
  `.ok / .reEnable / .rebuild`：健康不碰；只是被系统关了就原地打开；端口没了才
  `stop()` + `start()` 重建。
- 回调里被系统停用时补一条日志（带原因和当前 keyCode），不再只有一句「re-armed」。

## 反向变异（tools/mutation/shortcut-health.json）

本机测试进程没有输入监控权限，建不出真 tap，所以判据只能押判定表。

| 编号 | 坏法 | 结果 |
|---|---|---|
| SH1 | 丢掉 `portIsValid`（端口废了也当还活着） | KILLED |
| SH2 | 丢掉 `hasTap`（没拿到 tap 也当能救） | KILLED |
| SH3 | 永判 `.ok`（系统关掉的 tap 不去开） | KILLED |
| SH4 | 健康/停用判反 | KILLED |

本趟跑 4 条，该抓的 4 条全抓到，漏 0；还原核对 SHA 全部回到起跑前
（`.build/mutation/20261125-110814`）。

## 没做的 / 已知洞

- **录制框仍然「点一下即录制、按任何键即落盘」**，界面上也没有「已自定义（默认
  ⌥⌘V）」的提示。这轮不动 UI（对齐原版控件），所以「误碰改掉绑定」这条路还在；
  下次再撞上，看一眼剪贴板页那个框里显示的是不是 ⌥⌘V 就能定位。
- 巡检的**挂表动作**（`start()` 里 `startHealthTimer()`）离线咬不住：没有真 tap 就
  没有「关掉再等 2 秒」这一档，只能进装机清单。
- 重建分支（`stop()` + `start()`）在真机上同样只在巡检该重建时才会走，离线只验了
  判定，没有验重建后还能不能收键。

## 装机验收

1. 打开 偏好设置 → 剪贴板页，快捷键那一行应该显示 **⌥⌘V**（不是 ⌃⌘A）。
2. 随便切到别的 App 按 ⌥⌘V：弹出粘贴板历史面板；再按 Esc 关掉。
3. 面板开着时再按一次 ⌥⌘V：面板重开（原版行为，会重载列表），不报错。
4. 连按两下 ⌥⌘V（间隔 <1 秒）：不崩、最终只剩一扇面板。
5. 放置 10 分钟以上再按 ⌥⌘V：仍然弹（对应「经常失效」——巡检每 2 秒兜一次）。
6. 若第 1 步显示的**不是** ⌥⌘V：把库里那个值记下来（`defaults read
   net.mtjo.MacStroke historyCilpboardListShortcut`），说明又有人/手滑碰了录制框。
