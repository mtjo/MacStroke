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
/// builds a Stroke from the points, notifies the delegate when complete,
/// and draws the gesture path on a CanvasWindow overlay.
public class CanvasManager: EventCaptureDelegate {
    public weak var delegate: CanvasManagerDelegate?

    private var currentStroke: Stroke?
    private var isCapturing = false
    private let minimumPointsForGesture = 10

    /// The canvas overlay window shown during gesture drawing.
    /// Keyed by screen identifier for multi-screen support.
    private var canvasWindows: [String: CanvasWindow] = [:]

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
                // Add point to canvas view for visual feedback
                addPointToCanvas(point)
            }

        case .up:
            // Add final point and complete the stroke on left or right mouse up
            if (event.button == .left || event.button == .right) && isCapturing {
                if let stroke = currentStroke {
                    var mutableStroke = stroke
                    mutableStroke.addPoint(point)
                    currentStroke = mutableStroke
                }
                // Add final point to canvas view
                addPointToCanvas(point)
                completeStroke()
            }
        }
    }

    private func startStroke(with point: GesturePoint) {
        guard !isCapturing else { return }

        // Hide any existing canvas windows first, then create/show fresh ones
        hideAllCanvasWindows()
        showCanvasWindow(for: point)

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

        // Hide canvas windows after a short delay so the user sees the drawn path
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.hideAllCanvasWindows()
        }
    }

    /// Cancel the current stroke without notifying the delegate.
    public func cancelStroke() {
        currentStroke = nil
        isCapturing = false
        hideAllCanvasWindows()
    }

    /// Whether currently capturing a gesture.
    public var capturing: Bool { isCapturing }

    // MARK: - Canvas Window Management

    /// Adds a point to all visible canvas windows for visual feedback.
    private func addPointToCanvas(_ point: GesturePoint) {
        for window in canvasWindows.values {
            let viewPoint = convertPointToView(point, for: window)
            window.canvasView.addPoint(viewPoint)
        }
    }

    /// Shows a canvas window covering the screen that contains the given point.
    private func showCanvasWindow(for point: GesturePoint) {
        let screen = screenContainingPoint(point)
        let screenKey = String(describing: screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber ?? NSNumber(value: 0))
        let screenFrame = screen.frame

        let window: CanvasWindow
        if let existing = canvasWindows[screenKey] {
            // Reuse existing window, update frame if needed
            existing.setEnable(true)
            if existing.frame != screenFrame {
                existing.setFrame(screenFrame, display: false)
                existing.canvasView.resize(to: screenFrame)
            }
            window = existing
        } else {
            window = CanvasWindow(screenFrame: screenFrame)
            canvasWindows[screenKey] = window
        }

        window.show()
    }

    /// Hides all canvas windows and clears their drawing.
    private func hideAllCanvasWindows() {
        for (_, window) in canvasWindows {
            window.hide()
            window.canvasView.clear()
        }
    }

    /// Returns the screen that contains the given point.
    private func screenContainingPoint(_ point: GesturePoint) -> NSScreen {
        let location = CGPoint(x: point.x, y: point.y)
        for screen in NSScreen.screens {
            if NSPointInRect(location, screen.frame) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Converts a GesturePoint (in screen coordinates) to the local coordinate
    /// system of the given canvas window.
    private func convertPointToView(_ point: GesturePoint, for window: CanvasWindow) -> CGPoint {
        let screenLocation = CGPoint(x: point.x, y: point.y)
        let screenFrame = window.screen?.frame ?? NSScreen.main?.frame ?? .zero
        // CanvasView coordinates are relative to the window origin,
        // which is at the top-left of the screen in the original implementation.
        return CGPoint(
            x: screenLocation.x - screenFrame.origin.x,
            y: screenLocation.y - screenFrame.origin.y
        )
    }
}