//
//  MouseButtonRecorder.swift
//  MacStroke
//
//  Binds an extra mouse button as a gesture trigger (issue #53). The original
//  never had this control — it only ever watched the right button — so this is
//  a port-level extension; it borrows the bordered-box look of the shortcut
//  recorder so the row does not read as a foreign control.
//

import AppKit
import SwiftUI
import Storage

/// Shows the bound CoreGraphics button number (0 = none recorded) and captures
/// a new one from the next press.
struct MouseButtonRecorder: View {
    @Binding var buttonNumber: Int
    @State private var isWaiting = false

    var body: some View {
        Button(action: toggle) {
            Text(label)
                .frame(width: 132, alignment: .center)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .onExitCommand { stop() }
        .onDisappear { if isWaiting { stop() } }
    }

    private var label: String {
        if isWaiting { return L("Press a mouse button") }
        guard buttonNumber > 0 else { return L("Not recorded") }
        return LFormat("Button %d", buttonNumber)
    }

    private func toggle() {
        if isWaiting {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        isWaiting = true
        // Suspend gesture starts while waiting: the trial press could otherwise
        // be a button that is already an enabled trigger, which would swallow it
        // as the beginning of a stroke.
        NotificationCenter.default.post(name: .gestureTriggerRecordingDidChange, object: true)
        MouseButtonWatcher.shared.start { number in
            // Left (0) and right (1) are not this control's business: right is
            // always a trigger and left deliberately never starts a gesture.
            guard number >= 2 else { return }
            buttonNumber = number
            stop()
        }
    }

    private func stop() {
        guard isWaiting else { return }
        isWaiting = false
        MouseButtonWatcher.shared.stop()
        NotificationCenter.default.post(name: .gestureTriggerRecordingDidChange, object: false)
    }
}

/// Catches the next mouse-down while the recorder is waiting. A local monitor
/// suffices because the preferences window is key while the user presses, and
/// the event is returned untouched so the click still lands normally.
private final class MouseButtonWatcher {
    static let shared = MouseButtonWatcher()

    private var monitor: Any?

    func start(_ handler: @escaping (Int) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            handler(Int(event.buttonNumber))
            return event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
