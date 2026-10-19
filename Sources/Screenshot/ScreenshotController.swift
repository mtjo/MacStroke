//
//  ScreenshotController.swift
//  MacStroke
//
//  截图会话的总控：权限门 → 定格一帧 + 抓一份窗口表 → 铺遮罩让用户选区、下注解 →
//  把成品写进系统剪贴板或存成 PNG。
//
//  选和改都在遮罩这一层做完（QQ/微信那条路）：注解条浮在选区下沿，出口是选区内双击、
//  回车或条子上的图标。曾经试过「选完收遮罩、另开编辑窗改」，实测多一次窗口的代价是
//  改一张图要来回切注意力，用户明确要求回到就地编辑。
//
//  屏顶那条模式条（截图 / 滚动截图 / 录屏 / 文字识别）决定选区落定之后干什么，分流点
//  在遮罩的 `routeAfterSelection()`。后两档是**实况采集**，机制和冻结帧相反：遮罩必须
//  收掉、屏幕还给被截的那个 App，只留一圈描边和控制胶囊（`ScreenshotLivePanel`），然后
//  由这里驱动滚动拼接循环（`ScreenshotScrollCapture`）或录像会话（`ScreenshotRecorder`）。
//  所以这个类同时管着两种会话的生命周期，`toggle()` 也得认出「现在是在选区里还是在实况里」。
//
//  对外两个入口：`toggle()`（状态栏菜单、截图快捷键、手势规则）和 `toggleText()`
//  （「提取文字」专用快捷键，issue #74），两者共用的只是「开一场遮罩」这半条。会话期间
//  用回调通知 App 层挂起手势捕获 —— Screenshot 够不到 CanvasManager，反向依赖
//  会把模块拖回 App 层。
//

import AppKit
import CoreGraphics
import RemoteControl
import Storage
import UniformTypeIdentifiers

/// 用户在注解条上点「复制」还是「存文件」，或者拿图钉钉在屏幕上。
public enum ScreenshotOutput {
    case copy, save, pin
}

/// 一次出图的结果，一条报完。App 层的提示气泡不会自己错开位置，两条会叠成一坨，
/// 所以「复制 + 自动保存」这种同时发生两件事的情况必须由这里合成一条。
public enum ScreenshotOutcome {
    case copied(width: Int, height: Int)
    case saved(file: String)
    case copiedAndSaved(width: Int, height: Int, file: String)
    /// 自动保存那条路没有面板可兜底，写盘失败只能喊出来，否则用户以为存好了。
    case saveFailed(reason: String)
    /// 提取文字成功：行数就是用户要的「认出来多少」，不必把整段文本回显一遍。
    case textCopied(lines: Int)
    /// 这块里没字 —— 和下面「引擎没跑成」分开给，否则换选区还是报障都无从判断。
    case textNotFound
    case textFailed(reason: String)
    /// 录屏落盘成功（长截图复用上面的 `.copied` 那几支：它就是一张很高的 PNG）。
    case videoSaved(file: String, seconds: TimeInterval)
    /// 实况采集这一场没成：抓帧失败、编码器起不来、或者一帧都没录到。
    case captureFailed(reason: String)
}

public final class ScreenshotController {
    public static let shared = ScreenshotController()

    /// 遮罩显示/关闭时通知 App 层（true = 选区中，该挂起手势捕获了）。
    public var onActiveStateChanged: ((Bool) -> Void)?
    /// 出图后的反馈由 App 层弹（Toast 在 WindowManager，不让下层反向依赖它）。
    public var onOutcome: ((ScreenshotOutcome) -> Void)?

    private var window: ScreenshotOverlayWindow?

    public var isActive: Bool { window != nil }

    // MARK: - 实况采集（滚动截图 / 录屏）

    /// 浮层（描边 + 控制胶囊）。和下面两个会话同生同死，所以只有一份。
    private var live: ScreenshotLivePanel?
    private var scroll: ScreenshotScrollCapture?
    private var recorder: ScreenshotRecorder?
    /// 这一场录屏正在写的那个文件：取消时按它删掉半成品，所以得单独留着。
    private var recordURL: URL?
    /// 收带中（点过停止、文件还没闭合）：这期间再按一次停止要当没听见。
    private var finishingLive = false

    /// 正在录屏或长截图：`toggle()` 用它决定「停下来出图」还是「摊开遮罩」。
    public var isLiveCapturing: Bool { live != nil }

    private init() {}

    /// 再按一次就是取消：菜单/快捷键在遮罩已经摊开时不该什么反应都没有。
    /// 实况采集期间这一下是「停止并出图」而不是「丢掉」—— 录了半天的东西被一次
    /// 肌肉记忆的快捷键清空，是最糟的一种取消。
    public func toggle() {
        if isLiveCapturing { finishLive(); return }
        isActive ? cancel() : start()
    }

    /// 「提取文字」专用快捷键（issue #74）的入口：同一个遮罩，只是开出来就停在
    /// 提取文字那一档上。走的是和 `toggle()` 一样的三步判定 —— 实况采集里先收尾，
    /// 遮罩已摊开就当取消，否则带着那一档开一场。
    ///
    /// 不把 `ScreenshotMode` 放进签名：它是模块内的类型，公开它等于把模式条那四档
    /// 全变成对外的调用面，而现在只有这一档需要一个外部键位。
    public func toggleText() {
        if isLiveCapturing { finishLive(); return }
        if isActive { cancel(); return }
        start(mode: .text)
    }

    public func start() {
        start(mode: .still)
    }

    private func start(mode: ScreenshotMode) {
        guard window == nil, ensureScreenRecordingPermission() else { return }
        guard let screen = ScreenshotGrabber.targetScreen(),
              let shot = ScreenshotGrabber.grab(screen: screen) else { return }

        let view = ScreenshotSelectionView(shot: shot)
        // 先摆档再摆条：`showModeBar()` 里的 `sync(mode:)` 和屏上那句按键说明读的都是
        // 这个值，晚一步就是一条「亮着截图、说的却是提取文字」的错档提示。
        view.mode = mode
        // 窗口表和帧一起取：吸附预览圈的就是「这一帧里的这些窗」，隔几秒再查就会
        // 圈到一个已经关掉或已经挪走的窗。必须在建遮罩窗之前取完。
        // 偏好里关了吸附就不查（也不铺候选），拖选完全交给用户的手。
        let settings = ScreenshotSettings.current()
        view.windows = settings.snapToWindows
            ? ScreenshotWindowProbe.candidateRects(screenFrame: screen.frame) : []
        view.magnifierEnabled = settings.magnifier
        view.magnification = ScreenshotMagnification(stored: settings.magnification)
        view.defaultTool = settings.defaultTool
        view.onFinish = { [weak self] image, output, screenRect in
            // 复制/存盘即算完成，收遮罩把屏幕还给用户。
            self?.close()
            self?.deliver(image, output: output, settings: settings, screenRect: screenRect)
        }
        view.onCancel = { [weak self] in self?.close() }
        view.onText = { [weak self] outcome in
            // 认出字来才算完成；这块压根没字或引擎没跑成，遮罩得留着让用户换个选区
            // 再按一次，而不是把整张图丢掉。
            if case .lines = outcome { self?.close() }
            self?.deliverText(outcome)
        }
        view.onLiveCapture = { [weak self] mode, viewRect, screenRect in
            self?.beginLive(mode: mode, viewRect: viewRect, screenRect: screenRect,
                            screen: screen, settings: settings)
        }

        let window = ScreenshotOverlayWindow(screenFrame: screen.frame)
        window.contentView = view
        self.window = window
        onActiveStateChanged?(true)

        // .accessory 应用不激活就成不了 key 窗，Esc/回车会全丢。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        // 模式条要在窗挂好、`view.window.screen` 读得到之后才摆：它得量菜单栏在这一块屏
        // 里占多高才知道自己该贴哪儿。
        view.showModeBar()
    }

    public func cancel() {
        if isLiveCapturing { cancelLive(); return }
        close()
    }

    private func close() {
        guard let window else { return }
        self.window = nil
        // 取色面板（点调色板最后一格那枚彩色块弹的）挂在比遮罩还高的层上：遮罩收了
        // 它还开着，就是桌面上的一块无主窗。属性面板自己管收起那条，这里管会话结束这条。
        (window.contentView as? ScreenshotSelectionView)?.closeToolColorPicker()
        window.orderOut(nil)
        window.close()
        onActiveStateChanged?(false)
    }

    // MARK: - 实况采集（滚动截图 / 录屏）

    /// 遮罩收掉到起采集之间等的一拍，理由见 `beginLive`。
    static let overlaySettle: TimeInterval = 0.3

    /// 遮罩收了、屏幕还给被截的那个 App，浮层摆出来，再按档位起对应的采集会话。
    /// 调用方（遮罩）已经把模式条收掉并把选区交过来。
    private func beginLive(mode: ScreenshotMode, viewRect: CGRect, screenRect: NSRect,
                           screen: NSScreen, settings: ScreenshotSettings) {
        close()
        // 遮罩没了不等于会话结束：长截图往底下那个 App 里注入滚轮，录屏期间用户一次
        // 右键拖拽就能把整段录像带跑。手势捕获继续挂起到这一场收尾。
        onActiveStateChanged?(true)
        let panel = ScreenshotLivePanel(region: screenRect, visible: screen.visibleFrame,
                                        kind: mode == .record ? .record : .scroll)
        panel.onAction = { [weak self] action in
            switch action {
            case .finish: self?.finishLive()
            case .cancel: self?.cancelLive()
            }
        }
        panel.present()
        live = panel
        // 遮罩是刚刚 orderOut 的，而窗口服务是另一个进程：这一两帧里它可能还挂在屏上。
        // 抢在这之前起采集，长截图的第一屏和录像的头几帧会把遮罩自己拍进去（那扇窗没有
        // `sharingType = .none`，和描边/胶囊不一样，抓屏 API 照样看得见它），投出去的
        // 第一下滚轮也可能落在它身上 —— 而第一下没落地，整场就按「画面一动没动」收场了。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlaySettle) { [weak self, weak panel] in
            // 这一拍里用户可能已经按了取消（浮层收掉、live 置空）：那就别再把采集起起来。
            guard let self, let panel, self.live === panel else { return }
            if mode == .record {
                self.startRecord(viewRect: viewRect, screen: screen, settings: settings)
            } else {
                self.startScroll(viewRect: viewRect, screen: screen, settings: settings)
            }
        }
    }

    private func startScroll(viewRect: CGRect, screen: NSScreen, settings: ScreenshotSettings) {
        let capture = ScreenshotScrollCapture(screen: screen, region: viewRect)
        // 偏好在会话开始时已经取成快照（这一场中途改偏好不影响它），并且夹过了范围。
        capture.pointsPerStep = CGFloat(settings.scrollStep)
        capture.maxScreens = settings.scrollMaxScreens
        capture.onReadout = { [weak self] text in self?.live?.update(readout: text) }
        capture.onOutcome = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .composed(let image, let appended):
                self.endLive()
                guard appended > 0 else {
                    // 一段都没接上：出图就等于一张普通截图，报「已复制 1920×300」用户只会
                    // 认为长截图坏了。这条路上的图不进剪贴板，直接把原因说给他。
                    self.onOutcome?(.captureFailed(reason: L("Screenshot scroll nothing moved")))
                    return
                }
                // 长截图的出口和注解条上那枚绿✓一致：进剪贴板，开了自动保存再落一张 PNG。
                // 它没有贴图那一路（一张两万行的图钉在屏幕上没法看），所以 screenRect 用不上。
                self.deliver(image, output: .copy, settings: settings, screenRect: .zero)
            case .failed(let reason):
                self.endLive()
                self.onOutcome?(.captureFailed(reason: reason))
            }
        }
        scroll = capture
        capture.start()
    }

    private func startRecord(viewRect: CGRect, screen: NSScreen, settings: ScreenshotSettings) {
        guard let displayID = ScreenshotGrabber.displayID(for: screen) else {
            endLive()
            onOutcome?(.captureFailed(reason: L("Screenshot record no display")))
            return
        }
        let url = settings.videoURL()
        let machine = ScreenshotRecorder()
        machine.frameRate = Int32(settings.recordFrameRate)
        machine.maxSeconds = TimeInterval(settings.recordMaxSeconds)
        machine.capturesCursor = settings.recordCursor
        machine.onTick = { [weak self] seconds in
            self?.live?.update(readout: Self.duration(seconds))
        }
        // 录制中途编码器废掉时走这条（用户还没按停止）：不收浮层的话它会一直挂在屏幕上，
        // 而用户看到的是「时间不走、点停止也没视频」。
        machine.onFailure = { [weak self] reason in
            guard let self else { return }
            self.endLive()
            self.onOutcome?(.captureFailed(reason: reason))
        }
        let crop = ScreenshotRecorder.cropRect(viewRect: viewRect, screenHeight: screen.frame.height)
        machine.start(displayID: displayID, cropRect: crop, url: url) { [weak self] reason in
            guard let self else { return }
            if let reason {
                self.endLive()
                self.onOutcome?(.captureFailed(reason: reason))
                return
            }
            self.live?.update(readout: Self.duration(0))
        }
        recordURL = url
        recorder = machine
    }

    /// 停止并出图。录屏这条路要等文件写完才收浮层 —— 否则提示都报「已保存」了，
    /// 盘上还是半个没闭合的 mp4。
    private func finishLive() {
        guard scroll == nil else {
            // 长截图的收场由 capture 自己的 onOutcome 报（它得先把各段铺成长图）。
            scroll?.stop()
            return
        }
        // 收带那几百毫秒里再按一次停止：什么都不做。修复前这一按会走下面的
        // `guard let recorder`（recorder 已经撒手了）把胶囊提前收掉，用户以为没录上。
        guard !finishingLive else { return }
        guard let recorder else { endLive(); return }
        finishingLive = true
        self.recorder = nil
        recorder.stop { [weak self] outcome in
            guard let self else { return }
            self.endLive()
            switch outcome {
            case .saved(let url, let seconds):
                self.onOutcome?(.videoSaved(file: url.lastPathComponent, seconds: seconds))
            case .empty:
                self.onOutcome?(.captureFailed(reason: L("Screenshot record empty")))
            case .failed(let reason):
                self.onOutcome?(.captureFailed(reason: reason))
            }
        }
    }

    /// 丢掉这一场。录屏要先停会话让文件闭合，再把那个 mp4 删掉：留一个用户明确不要的
    /// 半成品在下载目录里，比浮层多挂几百毫秒糟。
    private func cancelLive() {
        if let recorder {
            self.recorder = nil
            let doomed = recordURL
            recorder.stop { _ in if let doomed { try? FileManager.default.removeItem(at: doomed) } }
        }
        scroll?.cancel()
        endLive()
    }

    private func endLive() {
        live?.dismiss()
        live = nil
        scroll = nil
        recorder = nil
        recordURL = nil
        finishingLive = false
        onActiveStateChanged?(false)
    }

    /// 胶囊上的时长读数：`分:秒`，秒补零。读数宽度决定胶囊多宽，所以格式得稳
    /// （`1:05` 和 `12:34` 都占五位，不会每秒把浮层抖一下宽度）。App 层的提示气泡
    /// 用同一个读法报录像时长，两边不该各写一份格式化。
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - 输出

    /// 把遮罩烘出来的图送出去，结果一条报给 App 层。
    ///
    /// 开了「自动保存」就不弹保存面板：复制那条路同时进剪贴板和落盘，存文件那条路
    /// 直接落到默认位置。会话开始时取的那份偏好快照一路带到这里，用户在遮罩里选区的
    /// 那几秒去改了偏好也不影响这一张图的去处。
    private func deliver(_ image: CGImage, output: ScreenshotOutput, settings: ScreenshotSettings,
                        screenRect: NSRect) {
        switch output {
        case .pin:
            // 贴图不弹提示：那扇小窗自己就是反馈，再冒一个气泡反而挡住刚钉上的图。
            ScreenshotPinBoard.show(image: image, screenRect: screenRect)
        case .copy:
            Self.write(image, to: NSPasteboard.general)
            guard settings.autoSave else {
                onOutcome?(.copied(width: image.width, height: image.height))
                return
            }
            // 复制和落盘两件事都发生了，提示却只能给一条：气泡不会自己错开位置，
            // 两条会叠成一坨。
            switch Self.writeToDisk(image, settings: settings) {
            case .ok(let file):
                onOutcome?(.copiedAndSaved(width: image.width, height: image.height, file: file))
            case .failed(let reason):
                onOutcome?(.saveFailed(reason: reason))
            }
        case .save:
            guard settings.autoSave else {
                presentPanel(for: image, settings: settings)
                return
            }
            onOutcome?(Self.writeToDisk(image, settings: settings).outcome)
        }
    }

    /// 提取文字的去向：只进剪贴板，不落盘、不建面板（薄的那一层）。
    ///
    /// 行与行之间用 `\n` 拼：这是用户粘贴进编辑器/聊天窗时期望的样子。
    private func deliverText(_ outcome: ScreenshotTextOutcome) {
        switch outcome {
        case .lines(let lines):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
            onOutcome?(.textCopied(lines: lines.count))
        case .nothing:
            onOutcome?(.textNotFound)
        case .failed(let reason):
            onOutcome?(.textFailed(reason: reason))
        }
    }

    private enum DiskResult {
        case ok(file: String)
        case failed(reason: String)

        var outcome: ScreenshotOutcome {
            switch self {
            case .ok(let file): return .saved(file: file)
            case .failed(let reason): return .saveFailed(reason: reason)
            }
        }
    }

    /// 静默落盘到默认位置（撞名自动加后缀）。
    private static func writeToDisk(_ image: CGImage, settings: ScreenshotSettings) -> DiskResult {
        let url = settings.fileURL()
        guard let data = pngData(image) else {
            return .failed(reason: L("Screenshot encode failed"))
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        return .ok(file: url.lastPathComponent)
    }

    // MARK: - 权限

    /// 没有屏幕录制授权就压根别铺遮罩：抓回来的是只有壁纸的干净图，用户会以为
    /// 截图功能坏了。
    private func ensureScreenRecordingPermission() -> Bool {
        if RemoteScreenCapture.hasScreenRecordingPermission() { return true }
        if RemoteScreenCapture.requestScreenRecordingPermission() { return true }
        showPermissionAlert()
        return false
    }

    /// `CGRequestScreenCaptureAccess` 只在「系统还没问过」时弹框；App 一旦进了那张
    /// 列表（包括拒绝态）它就只静默返回 false，所以这里必须自己给一条去设置页的路。
    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Needs Screen Recording Permission")
        alert.informativeText = L("MacStroke needs screen recording permission to take screenshots.\n\nClick \"Open System Settings\" and enable MacStroke under \"Privacy & Security\" → \"Screen Recording\".\n\nPlease restart the application after granting permission.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            RemoteScreenCapture.openScreenRecordingSettings()
        }
    }

    // MARK: - 输出

    private static func write(_ image: CGImage, to pasteboard: NSPasteboard) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        pasteboard.clearContents()
        // 和粘贴板历史面板的回写用同一组类型：只给 PNG 时有些接收方（老版本
        // Office、部分聊天窗）粘不上，TIFF 是它们的兜底。
        pasteboard.declareTypes([.tiff, .png], owner: nil)
        if let tiff = bitmap.representation(using: .tiff, properties: [:]) {
            pasteboard.setData(tiff, forType: .tiff)
        }
        if let png = bitmap.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        // 这里**不需要**再调 HistoryClipboardManager.insertLocalImage：剪贴板监控是
        // 轮询 pasteboard 变化，认的就是「只有图片类型」这一支（见 handleTimer 的
        // 分支顺序），所以这次复制会像任何其他 App 的复制一样自己进历史；开了历史
        // 才有、没开就不留，正是我们要的语义。
    }

    /// 存成 PNG。用 `begin` 而不是 `runModal`：`.accessory` 应用里模态面板会卡在
    /// 没有 key 窗的状态，异步那条路 AppKit 自己会等窗就绪。
    /// 面板起点用偏好里那个位置：用户设了「下载」，每次还在桌面里翻，等于没设。
    private func presentPanel(for image: CGImage, settings: ScreenshotSettings) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = settings.directory
        panel.nameFieldStringValue = settings.suggestedName() + ".png"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let data = Self.pngData(image) else { return }
            guard (try? data.write(to: url)) != nil else {
                self?.onOutcome?(.saveFailed(reason: url.path))
                return
            }
            self?.onOutcome?(.saved(file: url.lastPathComponent))
        }
    }

    private static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
