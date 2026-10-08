//
//  MouseButtonRecorder.swift
//  MacStroke
//
//  Picks the one mouse button a gesture starts from (issue #53). The original
//  never had this control — it only ever watched the right button — so this is
//  a port-level extension; it borrows the bordered-box look of the shortcut
//  recorder so the row does not read as a foreign control.
//

import AppKit
import SwiftUI
import Storage

/// Shows the bound CoreGraphics button number by name and captures a new one
/// from the next press.
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
        switch buttonNumber {
        case 1: return L("Right Button")
        case 2: return L("Middle Button")
        case 3: return L("Back Button")
        case 4: return L("Forward Button")
        default: return LFormat("Button %d", buttonNumber)
        }
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
        // be the button that is already the trigger, which would swallow it as
        // the beginning of a stroke.
        NotificationCenter.default.post(name: .gestureTriggerRecordingDidChange, object: true)
        MouseButtonWatcher.shared.start { number in
            // The left button is deliberately not a trigger (CanvasManager never
            // starts a gesture from it), so a press there just keeps waiting.
            guard number >= 1 else { return }
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
