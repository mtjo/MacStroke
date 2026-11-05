# 截图吸附：自家窗口（偏好设置 / 历史粘贴板）为什么吸不上

2026-11-04 用户实测报告两条：「截图工具不能设置软件的设置面板，现在的偏好设置是不能智能框选的」
「历史粘贴板弹窗现在也不会吸附」。

## 一、根因

两轮过滤把自家窗挡在外面：

1. **自家 pid 一律不吸** —— 早先 `candidateRects` 里的 `guard !window.isOwnProcess`。
   本意是挡画布、遮罩这类自家浮层，但偏好设置窗也是本进程的，被一起误杀。
2. **只收 layer 0** —— 历史粘贴板面板是浮窗层级（`NSWindow.Level(rawValue: 21)`，
   见 `HistoryClipboardListWindowController`），贴图窗是 `.floating`(3)，全被挡。

两条都说明原来的筛选维度找错了：**该问的不是「谁的窗、第几层」，而是「这扇窗会不会
出现在冻结帧里」** —— 截图圈的必须是帧里真有的像素。

实测（本机 2026-11-04，`open -a MacStroke` 后 dump `CGWindowListCopyWindowInfo`）：

| 自家窗 | layer | alpha | sharingType |
|---|---|---|---|
| 偏好设置窗 | 0 | 1.0 | 默认（可采集） |
| 状态栏项 | 25 | 1.0 | — |
| 画布 / 截图遮罩 / 录屏描边与胶囊 / 划词气泡 | shielding 及以上 / floating | 1.0 | `.none`（不进采集） |
| 历史粘贴板 | 21 | 1.0 | 默认（可采集） |
| 贴图 | 3（floating） | 1.0 | 默认（可采集） |

另：`kCGWindowSharingState` 不可靠 —— 探测进程没有录屏权限时，连自家普通窗都报 0，
所以采集性按 `NSWindow.sharingType`（本进程一手事实）配 `kCGWindowNumber` 号对。

## 二、修法

`Sources/Screenshot/ScreenshotWindowProbe.swift`

- 记录增加 `isCapturable`：自家窗里 `sharingType == .none` 的窗编号集合（取
  `NSApplication.shared.windows`）命中即为 false；别家窗一律 true。
- 筛选改成两道：
  1. `isCapturable && alpha >= 0.99` —— 帧里没有的窗不吸；
  2. `layer == 0 || (自家 && layer < 25)` —— 别家仍只吸普通层（否则程序坞那条整屏
     矩形会让「鼠标停哪都吸整屏」）；自家放宽到菜单栏之下，偏好 0、贴图 3、
     粘贴板 21 都能吸，状态栏项 25、Toast 101 不吸。
- 自家 pid 不再作为排除条件。

## 三、判据

`Tests/ScreenshotTests/ScreenshotWindowProbeTests.swift`

- `testOwnWindowsSnapOnlyWhenTheyAppearInTheFrame`：同一张表里摆偏好（0）、贴图（3）、
  粘贴板（21）、一扇 `.none` 的整屏浮窗（3）、状态栏项（25），断言**恰好前三个**进
  候选表。既咬「自家浮窗要能吸」，又咬「帧里没有的不能吸」。
- `testCandidateRectsDropUnsnappableWindows`：补一条「别家浮窗（layer 21）不吸」，
  其余四类老过滤照旧咬住。

## 四、反向变异

| 变异 | 结果 |
|---|---|
| 层级条件退回 `layer == 0`（不许自家浮窗） | KILLED —— 只得到偏好窗，贴图与粘贴板丢了 |
| 去掉 `isCapturable`（不看采集性） | KILLED —— 那扇 `.none` 的整屏浮窗混进候选表 |

恢复后源码 SHA `c02b7017c38a8bbfd1deb5b7418c78f95ba05555dfb95e394f96ba92d4714f79` 核对一致。

## 五、取证边界

- 窗口记录形状（layer/alpha/pid）由 §一 的 dump 取证；采集性按 `NSWindow.sharingType`
  的代码事实 + 单元判据；
- 「悬停到偏好窗 / 粘贴板面板上真的亮框、点下去圈住整窗」属于真链路，留给装机验收。

## 六、全量回归

改完两轮后一趟（`pkill -x MacStroke; python3 tools/xctstub/xct.py regress`），证据见
`/tmp/regress-78-prefsnap*.log`：Screenshot 套件 283 用例全绿；其余套件的红只出现在
RemoteControl E2E 的固定端口 stop/start 旧竞态上（红名单每趟漂移、单跑即绿，本轮没动
`Sources/RemoteControl/`）。
