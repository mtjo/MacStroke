//
//  ProximityLockTabView.swift
//  MacStroke
//
//  蓝牙靠近锁屏偏好页（移植版新增，原版没有）：三段 —— 开关与灵敏度、回来时要不要
//  自动解锁（存登录密码）、最后才是选设备与扫描出来的候选列表。
//  列表放最后是刻意的：它一展开就十几行，放在中间会把「自动解锁」顶出可视区，
//  看起来像功能没做。
//
//  和远程控制页一样，这一页改完立刻生效：每个开关都发
//  `.macStrokeProximityLockDidChange`，App 侧 `ProximityLockController.shared.apply()`
//  一次。设置没变时 apply 不会重启扫描，所以拖动滑块不会把「人在不在旁边」打回未知。
//

import AppKit
import ProximityLock
import Storage
import SwiftUI

struct ProximityLockTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @ObservedObject private var controller = ProximityLockController.shared

    /// 密码只停在这一页的 @State 里，绝不进 UserPreferences：视图模型是整个偏好窗口
    /// 共享的长命对象，把一个明文登录密码挂在那上面没有好处。存完/清完立刻抹掉。
    @State private var passwordDraft = ""
    @State private var hasStoredPassword = false
    @State private var passwordMessage: String?

    /// 走文件钥匙串，而文件钥匙串的 ACL 不认 `kSecUseAuthenticationUI: skip` 那个旗 ——
    /// 签名一变（每次重编译都会变）就是弹一个「某某想访问钥匙串项目」的框。
    /// 界面能弹，用户点允许就行；无头测试里没人点，进程就永远挂在那儿 ——
    /// 所以这里必须能换成内存实现。
    private let passwords: UnlockPasswordStoring

    init(viewModel: UserPreferences, passwords: UnlockPasswordStoring = KeychainPasswordStore()) {
        self.viewModel = viewModel
        self.passwords = passwords
    }

    /// 顺序是「先能开的、再是调的、最后才是扫描出来的那一大坨」：
    /// 候选列表一展开就是十几行，原先夹在中间把「自动解锁」整段顶到看不见，
    /// 用户以为功能没做。列表连同它的选择行一起挪到最后，中间不留能撑高的东西。
    var body: some View {
        SettingsPage {
            SettingsSection(title: L("Proximity Lock")) {
                SettingsCard {
                    SettingsRow(L("Enable proximity lock")) {
                        TrailingSwitch(isOn: $viewModel.enableProximityLock)
                    }
                    hint(L("Proximity Lock enable hint"))
                    RowDivider()
                    SettingsRow(L("Status:")) {
                        Text(statusLine)
                            .foregroundColor(statusColor)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let outcome = controller.lastOutcome {
                        hint(outcomeText(outcome))
                    }
                    RowDivider()
                    SettingsRow(L("Proximity unlock threshold")) {
                        rssiSlider($viewModel.proximityUnlockRSSI, in: unlockRange)
                    }
                    hint(L("Proximity unlock threshold hint"))
                    RowDivider()
                    SettingsRow(L("Proximity lock threshold")) {
                        rssiSlider($viewModel.proximityLockRSSI, in: lockRange)
                    }
                    hint(L("Proximity lock threshold hint"))
                    RowDivider()
                    SettingsRow(L("Proximity lock delay")) {
                        intPicker(Options.lockDelays, selection: $viewModel.proximityLockDelay,
                                  unit: L("Proximity seconds unit"))
                    }
                    hint(L("Proximity lock delay hint"))
                    RowDivider()
                    SettingsRow(L("Proximity signal timeout")) {
                        intPicker(Options.signalTimeouts, selection: $viewModel.proximitySignalTimeout,
                                  unit: L("Proximity seconds unit"))
                    }
                    hint(L("Proximity signal timeout hint"))
                }
            }

            SettingsSection(title: L("Proximity Auto Unlock")) {
                SettingsCard {
                    SettingsRow(L("Proximity auto unlock")) {
                        TrailingSwitch(isOn: $viewModel.proximityAutoUnlock)
                    }
                    hint(L("Proximity auto unlock hint"))
                    RowDivider()
                    passwordBlock
                    RowDivider()
                    warningBlock
                }
            }

            SettingsSection(title: L("Proximity Devices Section")) {
                SettingsCard {
                    deviceBlock
                }
            }
        }
        .onAppear {
            hasStoredPassword = passwords.hasPassword
            passwordMessage = nil
        }
        // 关页就停扫描：不这么做的话用户点过一次「扫描设备」，蓝牙会一直开着扫，
        // 而这一页已经不显示候选列表了，看着像卡住。已武装时 endDiscovery 不会停扫。
        .onDisappear {
            if controller.isDiscovering { controller.endDiscovery() }
            passwordDraft = ""
        }
    }

    // MARK: - 档位

    /// 存的是秒数本身而不是档位序号（同截图页的做法）：以后加档不用迁移，
    /// 手改过 defaults 的人停在没见过的值上也能显示出来（见 `intPicker`）。
    private enum Options {
        static let lockDelays = [0, 5, 15, 30, 60, 120, 300]
        static let signalTimeouts = [15, 30, 60, 120, 300, 600]
    }

    /// 两个滑块的可选范围互相让位，保证拖出来的任何位置都是合法的一对
    /// （滞回 ≥ 5dB）。否则用户能拖出「解锁 -90 / 锁屏 -60」这种反过来的组合，
    /// 写进库之后被 `ProximityLockSettings.current` 整对退回默认值，界面上看着像没生效。
    private var unlockRange: ClosedRange<Double> {
        let lower = Double(viewModel.proximityLockRSSI + ProximityLockSettings.minimumHysteresis)
        return max(lower, Double(ProximityLockSettings.rssiRange.lowerBound))
            ... Double(ProximityLockSettings.rssiRange.upperBound)
    }

    private var lockRange: ClosedRange<Double> {
        let upper = Double(viewModel.proximityUnlockRSSI - ProximityLockSettings.minimumHysteresis)
        return Double(ProximityLockSettings.rssiRange.lowerBound)
            ... min(upper, Double(ProximityLockSettings.rssiRange.upperBound))
    }

    // MARK: - Pieces

    /// 设备那一格：上面是当前盯的设备 + 扫描按钮，下面铺开候选列表。
    /// 扫描按钮不受总开关限制 —— 正常顺序是先扫到设备再打开开关。
    /// 第一次点扫描会构造 CBCentralManager，也就是系统蓝牙授权框在这时候弹。
    private var deviceBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("Proximity device"))
                    .frame(width: 160, alignment: .leading)
                Text(selectedDeviceText)
                    .foregroundColor(viewModel.proximityDeviceID.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                // 没有这个入口的话，想停掉判定只能去关总开关 —— 而总开关一关，
                // 下次要用还得重扫一遍。选中设备后这一颗按钮才出现。
                if !viewModel.proximityDeviceID.isEmpty {
                    Button(L("Proximity forget device")) {
                        viewModel.forgetProximityDevice()
                    }
                }
                Button(controller.isDiscovering ? L("Proximity stop scanning") : L("Proximity scan devices")) {
                    if controller.isDiscovering {
                        controller.endDiscovery()
                    } else {
                        controller.beginDiscovery()
                    }
                }
            }
            if controller.isDiscovering || !controller.devices.isEmpty {
                deviceList
            }
            if controller.isDiscovering, controller.devices.isEmpty {
                Text(L("Proximity no device found yet"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            ForEach(controller.devices) { device in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name.isEmpty ? L("Proximity unnamed device") : device.name)
                            .lineLimit(1)
                        Text(device.id)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text("\(device.rssi) dBm")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button(L("Proximity select")) {
                        viewModel.selectProximityDevice(id: device.id, name: device.name)
                    }
                    .disabled(device.id == viewModel.proximityDeviceID)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(device.id == viewModel.proximityDeviceID
                            ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                if device.id != controller.devices.last?.id {
                    Divider()
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var passwordBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("Proximity login password"))
                    .frame(width: 160, alignment: .leading)
                SecureField("", text: $passwordDraft)
                    .frame(width: 200)
                    .disabled(!viewModel.proximityAutoUnlock)
                Button(L("Proximity save password")) { savePassword() }
                    .disabled(passwordDraft.isEmpty || !viewModel.proximityAutoUnlock)
                Button(L("Proximity clear password")) { clearPassword() }
                    .disabled(!hasStoredPassword)
                Spacer(minLength: 0)
            }
            Text(hasStoredPassword ? L("Proximity password stored") : L("Proximity password missing"))
                .font(.system(size: 11))
                .foregroundColor(hasStoredPassword ? .secondary : .orange)
            if let passwordMessage {
                Text(passwordMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 四条必须说在前面的话：都是「不明说就会被当成 bug」的那一类。
    private var warningBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Proximity warning keychain"))
            Text(L("Proximity warning accessibility"))
            Text(L("Proximity warning apple watch"))
            Text(L("Proximity warning other watches"))
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var selectedDeviceText: String {
        guard !viewModel.proximityDeviceID.isEmpty else { return L("Proximity no device selected") }
        return viewModel.proximityDeviceName.isEmpty ? viewModel.proximityDeviceID : viewModel.proximityDeviceName
    }

    private var statusLine: String {
        guard controller.isRunning || controller.isDiscovering else {
            return L("Proximity status idle")
        }
        var pieces = [statusText]
        if controller.isRunning {
            pieces.append(presenceText)
            if let rssi = controller.smoothedRSSI { pieces.append("\(rssi) dBm") }
        }
        return pieces.joined(separator: " · ")
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return L("Proximity status idle")
        case .unauthorized: return L("Proximity status unauthorized")
        case .poweredOff: return L("Proximity status powered off")
        case .unsupported: return L("Proximity status unsupported")
        case .scanning: return L("Proximity status scanning")
        }
    }

    /// 控制器只交出「做了什么」的枚举，文案在这一页出 —— 这样语言切了立刻跟着变，
    /// 单测那边也不受本地化影响。
    private func outcomeText(_ outcome: ProximityLockController.Outcome) -> String {
        switch outcome {
        case .locked: return L("Proximity event locked")
        case .lockFailed: return L("Proximity event lock failed")
        case .alreadyLocked: return L("Proximity event already locked")
        case .returnedNoAutoUnlock: return L("Proximity event returned no auto unlock")
        case .unlocked: return L("Proximity event unlocked")
        case .fieldNotAcceptingPassword: return L("Proximity event field not accepting")
        case .waitingForDisplayWake: return L("Proximity event waiting for display wake")
        case .unlockCancelledByHand: return L("Proximity event unlock cancelled by hand")
        case .unlockCancelledPersonLeft: return L("Proximity event unlock cancelled left")
        case .noStoredPassword: return L("Proximity event no stored password")
        case .storedPasswordEmpty: return L("Proximity event empty password")
        case .injectionAborted: return L("Proximity event injection aborted")
        case .injectionFailed: return L("Proximity event injection failed")
        }
    }

    private var presenceText: String {
        switch controller.presence {
        case .unknown: return L("Proximity presence unknown")
        case .present: return L("Proximity presence present")
        case .absent: return L("Proximity presence absent")
        }
    }

    private var statusColor: Color {
        if !controller.isRunning, !controller.isDiscovering { return .secondary }
        switch controller.status {
        case .unauthorized, .poweredOff, .unsupported: return .red
        case .idle, .scanning: break
        }
        return controller.presence == .unknown ? .orange : .primary
    }

    private func rssiSlider(_ value: Binding<Int>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text("\(value.wrappedValue)")
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: range, step: 1)
                .frame(width: 210)
                .disabled(!viewModel.enableProximityLock)
        }
    }

    private func intPicker(_ options: [Int], selection: Binding<Int>, unit: String) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text("\(option) \(unit)").tag(option)
            }
            if !options.contains(selection.wrappedValue) {
                Text("\(selection.wrappedValue) \(unit)").tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .frame(width: 150)
        .disabled(!viewModel.enableProximityLock)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
    }

    private func savePassword() {
        let password = passwordDraft
        passwordDraft = ""
        guard !password.isEmpty else { return }
        if passwords.savePassword(password) {
            hasStoredPassword = true
            passwordMessage = nil
        } else {
            passwordMessage = L("Proximity password save failed")
        }
    }

    private func clearPassword() {
        passwordDraft = ""
        passwords.deletePassword()
        hasStoredPassword = passwords.hasPassword
        passwordMessage = nil
    }
}
