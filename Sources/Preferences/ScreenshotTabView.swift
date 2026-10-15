//
//  ScreenshotTabView.swift
//  MacStroke
//
//  截图偏好页（移植版新增，原版没有）：怎么触发（全局快捷键 + 手势），以及出图之后
//  要不要直接落盘、落到哪、拖选时吸不吸附窗口边界。
//
//  快捷键和其余几项只管写库（UserPreferences 的 didSet 已经写穿到 UserDefaults）：
//  快捷键由 App 层监听 UserDefaults 变化重新挂载，截图侧每次会话开始时现取一份快照
//  （ScreenshotSettings.current），所以这里都不发通知 —— 改完下一次生效，正铺着的
//  遮罩不会被中途改坏。
//
//  手势不一样：它就是一条普通的规则（动作类型「截图」），规则表才是手势的存放处。
//  这一页只是替用户把那条规则建好、录好，细节（最低分、应用过滤）仍在规则页改。
//

import AppKit
import RuleEngine
import Screenshot
import Storage
import SwiftUI

struct ScreenshotTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @ObservedObject private var ruleStore = RuleStore.shared

    var body: some View {
        SettingsPage {
            SettingsSection(title: L("Screenshot Trigger")) {
                SettingsCard {
                    SettingsRow(L("Screenshot Shortcut")) {
                        ShortcutRecorder(text: $viewModel.screenshotShortcut)
                            .frame(width: 200, height: 28)
                    }
                    hint(L("Screenshot Shortcut hint"))
                    RowDivider()
                    gestureBlock
                }
            }

            SettingsSection(title: L("Screenshot")) {
                SettingsCard {
                    SettingsRow(L("Screenshot auto save")) {
                        TrailingSwitch(isOn: $viewModel.screenshotAutoSave)
                    }
                    hint(L("Screenshot auto save hint"))
                    RowDivider()
                    directoryBlock
                    RowDivider()
                    SettingsRow(L("Screenshot snap to windows")) {
                        TrailingSwitch(isOn: $viewModel.screenshotSnapToWindows)
                    }
                    hint(L("Screenshot snap hint"))
                    RowDivider()
                    SettingsRow(L("Screenshot magnifier")) {
                        TrailingSwitch(isOn: $viewModel.screenshotMagnifier)
                    }
                    hint(L("Screenshot magnifier hint"))
                    RowDivider()
                    SettingsRow(L("Screenshot magnifier zoom")) {
                        Picker("", selection: $viewModel.screenshotMagnification) {
                            ForEach(ScreenshotMagnification.allCases, id: \.rawValue) { step in
                                Text(step.title).tag(step.rawValue)
                            }
                            // 手改过 defaults 的人可能停在别的倍数上，给个能显示出来的选项。
                            if !ScreenshotMagnification.allCases.contains(where: {
                                $0.rawValue == viewModel.screenshotMagnification
                            }) {
                                Text("\(viewModel.screenshotMagnification)×")
                                    .tag(viewModel.screenshotMagnification)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .disabled(!viewModel.screenshotMagnifier)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    /// 手势区块：照远程控制页配对码那一格的排法 —— 左边图、右边说明、按钮排在最后。
    /// 原来是「标题 + 按钮占一行，图压在下面」：两条按钮悬在缩略图上方，看不出是冲着
    /// 这张图来的，换手势时视线得在标题和图之间来回跳。
    private var gestureBlock: some View {
        HStack(alignment: .center, spacing: 16) {
            GestureThumb(points: gestureRule?.template.points.map {
                CGPoint(x: $0.x, y: $0.y)
            } ?? [])
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Screenshot Gesture"))
                Text(hasGestureRule ? L("Screenshot gesture hint") : L("Screenshot gesture unset"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button(L("Draw Gesture")) { drawGesture() }
                    if hasGestureRule {
                        Button(L("Screenshot remove gesture")) { removeGesture() }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var gestureRule: Rule? {
        ruleStore.rule(named: RuleStore.screenshotRuleName)
    }

    private var hasGestureRule: Bool {
        gestureRule != nil
    }

    /// 规则不在就先按默认值（S 预设手势）建一条，再进录制流程：录屏和预设网格都是
    /// 原版的二选一，画完即自存。
    private func drawGesture() {
        if ruleStore.installScreenshotRule() {
            NotificationCenter.default.post(name: .macStrokeRuleStoreDidChange, object: nil)
        }
        GestureRecordFlow.record(ruleName: RuleStore.screenshotRuleName, store: ruleStore)
    }

    private func removeGesture() {
        ruleStore.remove(named: RuleStore.screenshotRuleName)
        NotificationCenter.default.post(name: .macStrokeRuleStoreDidChange, object: nil)
    }

    /// 保存位置单独占一块：路径动辄六七十字符，塞在行尾的窄栏里只能看见尾部。
    private var directoryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Screenshot Save Location"))
                Spacer(minLength: 12)
                Button(L("Screenshot Choose Location")) { chooseDirectory() }
            }
            Text(ScreenshotSettings.directory(from: viewModel.screenshotSaveDirectory).path)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text(isStoredLocationGone
                 ? L("Screenshot location missing")
                 : L("Screenshot Save Location hint"))
                .font(.system(size: 11))
                .foregroundColor(isStoredLocationGone ? .orange : .secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 用户选过、但那个目录已经不在了 —— 截图会回退到桌面，这里必须说一声，
    /// 否则用户会以为图丢了。
    private var isStoredLocationGone: Bool {
        let stored = viewModel.screenshotSaveDirectory
        return !stored.isEmpty && !FileManager.default.fileExists(atPath: stored)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = L("Screenshot Save Location")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // 从当前生效的位置起步，用户点开就能看见自己现在存到哪。
        panel.directoryURL = ScreenshotSettings.directory(from: viewModel.screenshotSaveDirectory)
        guard let keyWindow = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: keyWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.screenshotSaveDirectory = url.path
        }
    }
}

/// 规则表同款手势缩略图（鼠标悬停会重放笔画顺序，正眼分辨得出 S 和它的反向孪生）。
private struct GestureThumb: NSViewRepresentable {
    let points: [CGPoint]

    func makeNSView(context: Context) -> GestureThumbView {
        GestureThumbView()
    }

    func updateNSView(_ nsView: GestureThumbView, context: Context) {
        nsView.points = points
    }
}
