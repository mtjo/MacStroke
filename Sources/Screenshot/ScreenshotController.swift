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
//  入口只有一个 `toggle()`：状态栏菜单、以后的快捷键和手势都走这里。会话期间
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
}

public final class ScreenshotController {
    public static let shared = ScreenshotController()

    /// 遮罩显示/关闭时通知 App 层（true = 选区中，该挂起手势捕获了）。
    public var onActiveStateChanged: ((Bool) -> Void)?
    /// 出图后的反馈由 App 层弹（Toast 在 WindowManager，不让下层反向依赖它）。
    public var onOutcome: ((ScreenshotOutcome) -> Void)?

    private var window: ScreenshotOverlayWindow?

    public var isActive: Bool { window != nil }

    private init() {}

    /// 再按一次就是取消：菜单/快捷键在遮罩已经摊开时不该什么反应都没有。
    public func toggle() {
        isActive ? cancel() : start()
    }

    public func start() {
        guard window == nil, ensureScreenRecordingPermission() else { return }
        guard let screen = ScreenshotGrabber.targetScreen(),
              let shot = ScreenshotGrabber.grab(screen: screen) else { return }

        let view = ScreenshotSelectionView(shot: shot)
        // 窗口表和帧一起取：吸附预览圈的就是「这一帧里的这些窗」，隔几秒再查就会
        // 圈到一个已经关掉或已经挪走的窗。必须在建遮罩窗之前取完。
        // 偏好里关了吸附就不查（也不铺候选），拖选完全交给用户的手。
        let settings = ScreenshotSettings.current()
        view.windows = settings.snapToWindows
            ? ScreenshotWindowProbe.candidateRects(screenFrame: screen.frame) : []
        view.magnifierEnabled = settings.magnifier
        view.magnification = ScreenshotMagnification(stored: settings.magnification)
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

        let window = ScreenshotOverlayWindow(screenFrame: screen.frame)
        window.contentView = view
        self.window = window
        onActiveStateChanged?(true)

        // .accessory 应用不激活就成不了 key 窗，Esc/回车会全丢。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    public func cancel() {
        close()
    }

    private func close() {
        guard let window else { return }
        self.window = nil
        window.orderOut(nil)
        window.close()
        onActiveStateChanged?(false)
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
