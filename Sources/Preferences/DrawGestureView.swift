//
//  DrawGestureView.swift
//  MacStroke
//
//  SwiftUI wrapper for DrawGesture NSView to display gesture templates
//  in the preferences window.
//

import Foundation
import SwiftUI
import AppKit
import GestureEngine
import EventCapture
import Storage

/// Coordinator that bridges DrawGestureDelegate to SwiftUI callbacks.
final class DrawGestureCoordinator: NSObject, DrawGestureDelegate {
    var ruleIndex: Int
    var onRequestPresetGesture: (Int) -> Void

    init(ruleIndex: Int, onRequestPresetGesture: @escaping (Int) -> Void) {
        self.ruleIndex = ruleIndex
        self.onRequestPresetGesture = onRequestPresetGesture
    }

    func drawGesture(_ drawGesture: DrawGesture, didRequestPresetGestureForRuleAt ruleIndex: Int) {
        onRequestPresetGesture(ruleIndex)
    }
}

/// SwiftUI wrapper for DrawGesture NSView.
struct DrawGestureView: NSViewRepresentable {
    var points: [GesturePoint]
    var ruleIndex: Int = 0
    var onRequestPresetGesture: (Int) -> Void

    func makeNSView(context: Context) -> DrawGesture {
        let view = DrawGesture(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
        view.ruleIndex = ruleIndex
        view.delegate = context.coordinator
        view.setPoints(points)
        return view
    }

    func updateNSView(_ nsView: DrawGesture, context: Context) {
        nsView.ruleIndex = ruleIndex
        nsView.setPoints(points)
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> DrawGestureCoordinator {
        DrawGestureCoordinator(ruleIndex: ruleIndex, onRequestPresetGesture: onRequestPresetGesture)
    }
}

/// A SwiftUI view that displays a gesture template preview with a
/// "Draw Gesture" button when no template is set.
struct GestureTemplatePreview: View {
    let stroke: Stroke?
    let ruleIndex: Int
    let onRequestPresetGesture: (Int) -> Void

    @State private var points: [GesturePoint] = []

    init(stroke: Stroke?, ruleIndex: Int = 0, onRequestPresetGesture: @escaping (Int) -> Void = { _ in }) {
        self.stroke = stroke
        self.ruleIndex = ruleIndex
        self.onRequestPresetGesture = onRequestPresetGesture
        self._points = State(initialValue: stroke?.points ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if points.isEmpty {
                Text(L("No gesture template set"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            DrawGestureView(
                points: points,
                ruleIndex: ruleIndex,
                onRequestPresetGesture: onRequestPresetGesture
            )
            .frame(width: 60, height: 60)

            Button(L("Draw Gesture")) {
                onRequestPresetGesture(ruleIndex)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onChange(of: stroke?.points.count ?? 0) { newCount in
            points = stroke?.points ?? []
        }
    }
}
