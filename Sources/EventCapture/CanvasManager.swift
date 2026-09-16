//
//  CanvasManager.swift
//  MacStroke
//
//  Manages the gesture drawing canvas - collects mouse events into strokes,
//  detects gesture start/end, and provides the stroke for recognition.
//

import Foundation
import AppKit
import GestureEngine

/// Delegate for CanvasManager to notify when a stroke is complete.
public protocol CanvasManagerDelegate: AnyObject {
    /// Called when a gesture stroke is completed and ready for recognition.
    /// - Parameters:
    ///   - manager: The canvas manager
    ///   - stroke: The completed stroke (normalized, ready for comparison)
    ///   - bundleID: The bundle ID of the frontmost application (for filtering)
    func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String)
}

/// Manages the gesture drawing canvas.
///
/// Collects mouse events during a gesture (from mouse down to mouse up),
/// builds a Stroke from the points, and notifies the delegate when complete.
public class CanvasManager: EventCaptureDelegate {
    public weak var delegate: CanvasManagerDelegate?

    private var currentStroke: Stroke?
    private var isCapturing = false
    private let minimumPointsForGesture = 10

    /// Create a new canvas manager.
    public init() {}

    /// Handle mouse event from EventCapture.
    public func eventCapture(_ capture: EventCapture, didReceive event: MouseEvent) {
        let point = event.point

        switch event.phase {
        case .down:
            // Start a new stroke on left or right mouse down
            if event.button == .left || event.button == .right {
                startStroke(with: point)
            }

        case .moved:
            // Add point to current stroke if capturing
            if isCapturing, let stroke = currentStroke {
                var mutableStroke = stroke
                mutableStroke.addPoint(point)
                currentStroke = mutableStroke
            }

        case .up:
            // Add final point and complete the stroke on left or right mouse up
            if (event.button == .left || event.button == .right) && isCapturing {
                if let stroke = currentStroke {
                    var mutableStroke = stroke
                    mutableStroke.addPoint(point)
                    currentStroke = mutableStroke
                }
                completeStroke()
            }
        }
    }

    private func startStroke(with point: GesturePoint) {
        guard !isCapturing else { return }

        var stroke = Stroke(capacity: 256)
        stroke.addPoint(point)
        currentStroke = stroke
        isCapturing = true
    }

    private func completeStroke() {
        guard let stroke = currentStroke else { return }

        // Only notify if we have enough points for a valid gesture
        if stroke.count >= minimumPointsForGesture {
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            delegate?.canvasManager(self, didCompleteStroke: stroke, bundleID: bundleID)
        }

        currentStroke = nil
        isCapturing = false
    }

    /// Cancel the current stroke without notifying the delegate.
    public func cancelStroke() {
        currentStroke = nil
        isCapturing = false
    }

    /// Whether currently capturing a gesture.
    public var capturing: Bool { isCapturing }
}