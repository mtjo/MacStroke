//
//  GestureTemplateProvider.swift
//  MacStroke
//
//  Provides preset gesture templates for common gestures.
//

import Foundation
import GestureEngine

/// Preset gesture names available in the app.
public enum PresetGesture: String, CaseIterable {
    case closeWindow = "Close Window"
    case minimize = "Minimize"
    case hideApp = "Hide App"
    case launchSafari = "Launch Safari"
    case launchChrome = "Launch Chrome"
    case launchTerminal = "Launch Terminal"
    case scrollUp = "Scroll Up"
    case scrollDown = "Scroll Down"
    case swipeLeft = "Swipe Left"
    case swipeRight = "Swipe Right"
    case circle = "Circle"
    case check = "Check Mark"
    case arrowUp = "Arrow Up"
    case arrowDown = "Arrow Down"
    case arrowLeft = "Arrow Left"
    case arrowRight = "Arrow Right"
    case letterZ = "Z Shape"
    case letterC = "C Shape"
    case letterV = "V Shape"
    case letterW = "W Shape"

    /// The template stroke for this preset gesture.
    public var template: Stroke {
        var stroke = Stroke(capacity: 50)
        let points = Self.points(for: self)
        for p in points {
            stroke.addPoint(p)
        }
        return stroke
    }

    /// Generate the points for each preset gesture.
    private static func points(for gesture: PresetGesture) -> [GesturePoint] {
        switch gesture {
        case .closeWindow:
            return makeArrowPoints(up: false)  // Close = X shape, simplified as downward arrow
        case .minimize:
            return makeArrowPoints(up: true)   // Minimize = downward arrow
        case .hideApp:
            return makeArrowPoints(up: true)   // Hide = similar to minimize
        case .launchSafari:
            return makeArrowPoints(up: true)   // Launch Safari = upward arrow
        case .launchChrome:
            return makeArrowPoints(up: true)   // Launch Chrome = upward arrow
        case .launchTerminal:
            return makeArrowPoints(up: true)   // Launch Terminal = upward arrow
        case .scrollUp:
            return makeSwipePoints(direction: .up)
        case .scrollDown:
            return makeSwipePoints(direction: .down)
        case .swipeLeft:
            return makeSwipePoints(direction: .left)
        case .swipeRight:
            return makeSwipePoints(direction: .right)
        case .circle:
            return makeCirclePoints()
        case .check:
            return makeCheckMarkPoints()
        case .arrowUp:
            return makeArrowPoints(up: true)
        case .arrowDown:
            return makeArrowPoints(up: false)
        case .arrowLeft:
            return makeArrowPoints(direction: .left)
        case .arrowRight:
            return makeArrowPoints(direction: .right)
        case .letterZ:
            return makeZShapePoints()
        case .letterC:
            return makeCShapePoints()
        case .letterV:
            return makeVShapePoints()
        case .letterW:
            return makeWShapePoints()
        }
    }

    // MARK: - Shape generators

    private enum SwipeDirection { case up, down, left, right }
    private enum ArrowDirection { case up, down, left, right }

    private static func makeSwipePoints(direction: SwipeDirection) -> [GesturePoint] {
        switch direction {
        case .up:
            return (0..<20).map { i in GesturePoint(x: 50.0, y: Double(i) * 5.0) }
        case .down:
            return (0..<20).map { i in GesturePoint(x: 50.0, y: 100.0 - Double(i) * 5.0) }
        case .left:
            return (0..<20).map { i in GesturePoint(x: 100.0 - Double(i) * 5.0, y: 50.0) }
        case .right:
            return (0..<20).map { i in GesturePoint(x: Double(i) * 5.0, y: 50.0) }
        }
    }

    private static func makeArrowPoints(up: Bool) -> [GesturePoint] {
        let count = 20
        if up {
            return (0..<count).map { i in
                let t = Double(i) / Double(count - 1)
                return GesturePoint(
                    x: 50.0 + (t < 0.5 ? t * 40 : (1 - t) * 40),
                    y: t * 80
                )
            }
        } else {
            return (0..<count).map { i in
                let t = Double(i) / Double(count - 1)
                return GesturePoint(
                    x: 50.0 + (t < 0.5 ? t * 40 : (1 - t) * 40),
                    y: 100.0 - t * 80
                )
            }
        }
    }

    private static func makeArrowPoints(direction: ArrowDirection) -> [GesturePoint] {
        let count = 20
        switch direction {
        case .left:
            return (0..<count).map { i in
                let t = Double(i) / Double(count - 1)
                return GesturePoint(x: 100.0 - t * 80, y: 50.0)
            }
        case .right:
            return (0..<count).map { i in
                let t = Double(i) / Double(count - 1)
                return GesturePoint(x: t * 80, y: 50.0)
            }
        case .up:
            return makeArrowPoints(up: true)
        case .down:
            return makeArrowPoints(up: false)
        }
    }

    private static func makeCirclePoints() -> [GesturePoint] {
        let count = 50
        return (0..<count).map { i in
            let angle = Double(i) * 2 * .pi / Double(count)
            return GesturePoint(x: 50.0 + cos(angle) * 40, y: 50.0 + sin(angle) * 40)
        }
    }

    private static func makeCheckMarkPoints() -> [GesturePoint] {
        // Interpolate between three key points
        return [
            GesturePoint(x: 20.0, y: 50.0),
            GesturePoint(x: 40.0, y: 70.0),
            GesturePoint(x: 80.0, y: 20.0),
        ]
    }

    private static func makeZShapePoints() -> [GesturePoint] {
        return (0..<20).map { i in
            let t = Double(i) / 19.0
            let y: Double
            if t < 0.33 {
                y = 20.0
            } else if t < 0.66 {
                y = 50.0
            } else {
                y = 80.0
            }
            return GesturePoint(x: t * 100.0, y: y)
        }
    }

    private static func makeCShapePoints() -> [GesturePoint] {
        let count = 30
        return (0..<count).map { i in
            let t = Double(i) / 29.0
            let angle = .pi * (1.0 - t)
            return GesturePoint(x: 50.0 + cos(angle) * 40.0, y: 50.0 + sin(angle) * 40.0)
        }
    }

    private static func makeVShapePoints() -> [GesturePoint] {
        return (0..<20).map { i in
            let t = Double(i) / 19.0
            let y = t < 0.5 ? t * 100.0 : (1.0 - t) * 100.0
            return GesturePoint(x: t * 100.0, y: y)
        }
    }

    private static func makeWShapePoints() -> [GesturePoint] {
        return (0..<30).map { i in
            let t = Double(i) / 29.0
            let y: Double
            if t < 0.25 {
                y = t * 100.0
            } else if t < 0.5 {
                y = 25.0 - (t - 0.25) * 100.0
            } else if t < 0.75 {
                y = (t - 0.5) * 100.0
            } else {
                y = 25.0 - (t - 0.75) * 100.0
            }
            return GesturePoint(x: t * 100.0, y: y)
        }
    }
}

/// Provides gesture templates matching user-defined gesture patterns.
public final class GestureTemplateProvider {
    public static let shared = GestureTemplateProvider()

    private init() {}

    /// All available preset gestures.
    public var presets: [PresetGesture] {
        PresetGesture.allCases
    }

    /// Get the template stroke for a preset gesture.
    public func template(for gesture: PresetGesture) -> Stroke {
        gesture.template
    }

    /// Get all templates as (name, stroke) pairs.
    public func allTemplates() -> [(name: String, stroke: Stroke)] {
        PresetGesture.allCases.map { ($0.rawValue, $0.template) }
    }
}
