//
//  RemoteControlTabView.swift
//  MacStroke
//
//  Preferences page for the LAN remote-control service (移植版新增页，原版没有):
//  the phone side is a WeChat mini program that opens a TCP socket to this Mac,
//  so the page needs the listening port, a pairing code, the live status and the
//  QR code the mini program scans.
//

import AppKit
import SwiftUI
import RemoteControl
import Storage

struct RemoteControlTabView: View {
    @ObservedObject var viewModel: UserPreferences
    @ObservedObject private var server = RemoteControlServer.shared

    @State private var portDraft: String = ""
    @State private var qrImage: NSImage?
    @State private var screenRecordingGranted = RemoteScreenCapture.hasScreenRecordingPermission()
    @FocusState private var portFocused: Bool

    private var address: String? { RemoteNetworkAddress.preferredAddress() }

    var body: some View {
        SettingsPage {
            SettingsSection(title: L("Remote Control")) {
                SettingsCard {
                    SettingsRow(L("Enable remote control")) {
                        TrailingSwitch(isOn: $viewModel.enableRemoteControl)
                    }
                    RowDivider()
                    SettingsRow(L("Port:")) {
                        VStack(alignment: .trailing, spacing: 2) {
                            TextField("", text: $portDraft)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .focused($portFocused)
                                .disabled(!viewModel.enableRemoteControl)
                                .onSubmit(commitPort)
                            if viewModel.lastRejectedPort != nil {
                                Text(L("This port cannot be reached by the mini program"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    RowDivider()
                    SettingsRow(L("Pairing code:")) {
                        HStack(spacing: 8) {
                            // 提示语用正文字体：等宽体下这行英文比配对码长得多，会把
                            // 右边的按钮挤到卡片边线上。
                            if viewModel.remoteControlToken.isEmpty {
                                Text(L("Generated when you switch it on"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(viewModel.remoteControlToken)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Button(L("Regenerate")) {
                                viewModel.regenerateRemoteToken()
                            }
                            .disabled(viewModel.remoteControlToken.isEmpty)
                        }
                    }
                    RowDivider()
                    SettingsRow(L("Status:")) {
                        Text(statusText)
                            .foregroundColor(statusColor)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    RowDivider()
                    SettingsRow(L("Screen recording (touchscreen view):")) {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 8) {
                                // 触屏回显唯一会「静默失败」的一关：没授权时截屏 API 不报错，
                                // 只回一张壁纸，手机上看着像 Mac 卡住了。
                                Text(screenRecordingGranted ? L("Granted") : L("Not granted"))
                                    .foregroundColor(screenRecordingGranted ? .primary : .orange)
                                Button(L("Ask for access")) {
                                    RemoteScreenCapture.requestScreenRecordingPermission()
                                    RemoteScreenCapture.openScreenRecordingSettings()
                                }
                                .disabled(screenRecordingGranted)
                            }
                            if !screenRecordingGranted {
                                Text(L("Restart MacStroke to take effect"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    RowDivider()
                    // 配对码二维码不另起分组：它编的就是上面的端口和配对码，
                    // 拆开摆会让人以为是两件事。
                    pairingBlock
                }
            }

            SettingsSection(title: L("Open the mini program")) {
                SettingsCard {
                    miniProgramBlock
                }
            }
        }
        .onAppear {
            portDraft = String(viewModel.remoteControlPort)
            refreshQR()
            recheckScreenRecording()
        }
        // 授权要在系统设置里点，来回切一次应用就回来了：这时必须重读，
        // 否则页面一直挂着「未授权」，用户以为没点上。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheckScreenRecording()
        }
        .onChange(of: viewModel.remoteControlPort) { newValue in
            if !portFocused { portDraft = String(newValue) }
            refreshQR()
        }
        .onChange(of: viewModel.remoteControlToken) { _ in refreshQR() }
        .onChange(of: viewModel.enableRemoteControl) { _ in refreshQR() }
    }

    // MARK: - Pieces

    /// 卡片里的最后一块：配对码二维码 + 怎么用它。
    private var pairingBlock: some View {
        HStack(spacing: 16) {
            qrBlock
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Scan this code inside the mini program to connect."))
                Text(L("The phone and this Mac must be on the same Wi-Fi."))
                Text(L("A new pairing code disconnects every phone already paired."))
                if let address {
                    Text(L("Address:") + " \(address):\(viewModel.remoteControlPort)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text(L("No local network address was found."))
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var miniProgramBlock: some View {
        HStack(spacing: 16) {
            VStack(spacing: 6) {
                if let code = RemoteMiniProgramCode.image {
                    Image(nsImage: code)
                        .resizable()
                        // 码是微信后台烤的白底图，深色模式下不垫一层会跟卡片
                        // 糊在一起；小程序码也只有在白底上才扫得出来。
                        .frame(width: 148, height: 148)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(Text(L("Mini program code is missing."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(8))
                        .frame(width: 148, height: 148)
                }
                Text(L("WeChat Scan"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Scan this code with WeChat to open MacStroke on your phone."))
                Text(L("Do it once: afterwards open it from WeChat's recently used list."))
            }
            .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var qrBlock: some View {
        Group {
            if viewModel.enableRemoteControl, let image = qrImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 190, height: 190)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        Text(viewModel.enableRemoteControl
                             ? L("No local network address was found.")
                             : L("Turn the switch on to show the QR code."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(8)
                    )
                    .frame(width: 190, height: 190)
            }
        }
    }

    private var statusText: String {
        if !viewModel.enableRemoteControl {
            return L("Stopped")
        }
        if let failure = server.statusMessage {
            return failure
        }
        if server.peers.isEmpty {
            return L("Listening, no device connected")
        }
        let names = server.peers.map { $0.name }.joined(separator: ", ")
        return L("Connected:") + " " + names
    }

    private var statusColor: Color {
        if !viewModel.enableRemoteControl { return .secondary }
        if server.statusMessage != nil { return .red }
        return server.peers.isEmpty ? .secondary : .primary
    }

    private func recheckScreenRecording() {
        screenRecordingGranted = RemoteScreenCapture.hasScreenRecordingPermission()
    }

    private func commitPort() {
        guard let port = Int(portDraft.trimmingCharacters(in: .whitespaces)) else {
            portDraft = String(viewModel.remoteControlPort)
            return
        }
        viewModel.remoteControlPort = port
        portDraft = String(viewModel.remoteControlPort)
    }

    private func refreshQR() {
        guard viewModel.enableRemoteControl, let address = address,
              !viewModel.remoteControlToken.isEmpty else {
            qrImage = nil
            return
        }
        qrImage = RemoteQRCode.image(
            from: RemotePairing.payload(host: address,
                                        port: viewModel.remoteControlPort,
                                        token: viewModel.remoteControlToken),
            side: 380
        )
    }
}

/// 小程序码：微信后台按 AppID 烤出来的固定图，本机算不出来，只能当素材入库。
/// 它跟上面那张配对码是两回事——这张给微信「扫一扫」打开小程序，那张给小程序自己扫。
private enum RemoteMiniProgramCode {
    static let image: NSImage? = {
        guard let url = appResourceBundle().url(forResource: "MiniProgramCode", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
