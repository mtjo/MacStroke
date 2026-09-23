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
    // Letters A-Z
    case letterA = "A Shape"
    case letterB = "B Shape"
    case letterC = "C Shape"
    case letterD = "D Shape"
    case letterE = "E Shape"
    case letterF = "F Shape"
    case letterG = "G Shape"
    case letterH = "H Shape"
    case letterI = "I Shape"
    case letterJ = "J Shape"
    case letterK = "K Shape"
    case letterL = "L Shape"
    case letterM = "M Shape"
    case letterN = "N Shape"
    case letterO = "O Shape"
    case letterP = "P Shape"
    case letterQ = "Q Shape"
    case letterR = "R Shape"
    case letterS = "S Shape"
    case letterT = "T Shape"
    case letterU = "U Shape"
    case letterV = "V Shape"
    case letterW = "W Shape"
    case letterX = "X Shape"
    case letterY = "Y Shape"
    case letterZ = "Z Shape"
    // Diagonal symbols
    case arrowDownLeft = "↙"
    case arrowDownRight = "↘"
    case arrowUpLeft = "↖"
    case arrowUpRight = "↗"
    // Box drawing symbols
    case boxTopLeft = "┏"
    case boxTopRight = "┓"
    case boxBottomLeft = "┗"
    case boxBottomRight = "┛"
    // Arrows
    case arrowLeftSymbol = "←"
    case arrowUpSymbol = "↑"
    case arrowRightSymbol = "→"
    case arrowDownSymbol = "↓"

    /// The template stroke for this preset gesture.
    public var template: Stroke {
        let points = Self.points(for: self)
        return Stroke(points: points, capacity: max(points.count, 1))
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
        case .letterA:
            return makeALettersPoints()
        case .letterB:
            return makeBShapePoints()
        case .letterD:
            return makeDShapePoints()
        case .letterE:
            return makeEShapePoints()
        case .letterF:
            return makeFShapePoints()
        case .letterG:
            return makeGShapePoints()
        case .letterH:
            return makeHShapePoints()
        case .letterI:
            return makeIShapePoints()
        case .letterJ:
            return makeJShapePoints()
        case .letterK:
            return makeKShapePoints()
        case .letterL:
            return makeLShapePoints()
        case .letterM:
            return makeMShapePoints()
        case .letterN:
            return makeNShapePoints()
        case .letterO:
            return makeOShapePoints()
        case .letterP:
            return makePShapePoints()
        case .letterQ:
            return makeQShapePoints()
        case .letterR:
            return makeRShapePoints()
        case .letterS:
            return makeSShapePoints()
        case .letterT:
            return makeTShapePoints()
        case .letterU:
            return makeUShapePoints()
        case .letterX:
            return makeXShapePoints()
        case .letterY:
            return makeYShapePoints()
        case .arrowDownLeft:
            return makeDiagonalPoints(right: false, up: false)
        case .arrowDownRight:
            return makeDiagonalPoints(right: true, up: false)
        case .arrowUpLeft:
            return makeDiagonalPoints(right: false, up: true)
        case .arrowUpRight:
            return makeDiagonalPoints(right: true, up: true)
        case .boxTopLeft:
            return makeCornerPoints(up: true, right: true)
        case .boxTopRight:
            return makeCornerPoints(up: true, right: false)
        case .boxBottomLeft:
            return makeCornerPoints(up: false, right: true)
        case .boxBottomRight:
            return makeCornerPoints(up: false, right: false)
        case .arrowLeftSymbol:
            return makeCardinalPoints(horizontal: true, positive: false)
        case .arrowUpSymbol:
            return makeCardinalPoints(horizontal: false, positive: true)
        case .arrowRightSymbol:
            return makeCardinalPoints(horizontal: true, positive: true)
        case .arrowDownSymbol:
            return makeCardinalPoints(horizontal: false, positive: false)
        }
    }

    // MARK: - Shape generators

    private enum SwipeDirection { case up, down, left, right }
    private enum ArrowDirection { case up, down, left, right }

    private static func makeArrowPoints(direction: ArrowDirection) -> [GesturePoint] {
        let count = 35
        switch direction {
        case .up:
            return makeArrowPoints(up: true)
        case .down:
            return makeArrowPoints(up: false)
        case .left:
            return (0..<count).map { i in GesturePoint(x: 100.0 - Double(i) * 3, y: 50.0) }
        case .right:
            return (0..<count).map { i in GesturePoint(x: Double(i) * 3, y: 50.0) }
        }
    }

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

    private static func makeVShapePoints() -> [GesturePoint] {
        // PreGesture.m case 21: y drops then climbs while x advances, i.e. a
        // valley. Drawn in the (non-flipped) gesture canvas that reads as "V".
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<20 { y -= 1; x += 0.4; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y += 1; x += 0.4; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeWShapePoints() -> [GesturePoint] {
        // PreGesture.m case 22: four 20-point legs, down-up-down-up.
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for delta in [-1.0, 1.0, -1.0, 1.0] {
            for _ in 0..<20 {
                y += delta
                x += 0.3
                points.append(GesturePoint(x: x, y: y))
            }
        }
        return points
    }

    private static func makeZShapePoints() -> [GesturePoint] {
        // PreGesture.m case 25: top bar right, diagonal down-left, bottom bar right.
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<20 { x += 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { x -= 1; y -= 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { x += 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }
    // MARK: - Letter shape generators (A-Z based on original PreGesture.m)

    private static func makeALettersPoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for i in 0..<30 {
            points.append(GesturePoint(x: x, y: y))
            y += Double(i)
            x += 0.4 * Double(i)
        }
        for i in 0..<30 {
            points.append(GesturePoint(x: x, y: y))
            y -= Double(i)
            x += 0.4 * Double(i)
        }
        return points
    }

    private static func makeBShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0...80 {
            y += 1
            points.append(GesturePoint(x: x, y: y))
        }
        x = 230
        points.append(GesturePoint(x: x, y: y))
        for i in 0...40 {
            x = 200 + 30 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
            y -= 1
        }
        x = 210
        points.append(GesturePoint(x: x, y: y))
        for i in 0...40 {
            y -= 1
            x = 200 + 35 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
        }
        x = 200
        y = 200
        points.append(GesturePoint(x: x, y: y))
        return points
    }

    private static func makeCShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 220.0, y = 200.0
        for i in 0..<40 {
            if i > 2 { points.append(GesturePoint(x: x, y: y)) }
            x -= 1
            y = 200 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
        }
        x = 179
        y = 200
        for i in 0..<15 {
            y -= 1
            points.append(GesturePoint(x: x, y: y))
        }
        for i in 0..<40 {
            points.append(GesturePoint(x: x, y: y))
            x += 1
            y = 184 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
        }
        points.append(GesturePoint(x: x, y: y))
        return points
    }

    private static func makeDShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0...40 { y += 1; points.append(GesturePoint(x: x, y: y)) }
        x = 210
        points.append(GesturePoint(x: x, y: y))
        for i in 0...40 {
            x = 200 + 10 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
            y -= 1
        }
        x = 200
        y = 200
        points.append(GesturePoint(x: x, y: y))
        return points
    }

    private static func makeEShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<80 { y += 1 }
        x = 200
        points.append(GesturePoint(x: x, y: y))
        for i in 0..<40 {
            y -= 1
            x = 200 - 20 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
        }
        x = 200
        y = 240
        points.append(GesturePoint(x: x, y: y))
        for i in 0...40 {
            y -= 1
            x = 200 - 20 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
        }
        x = 210
        y = 200
        points.append(GesturePoint(x: x, y: y))
        return points
    }

    private static func makeFShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<15 { x -= 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y -= 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeGShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 220.0, y = 200.0
        for i in 0..<40 {
            if i > 3 { points.append(GesturePoint(x: x, y: y)) }
            x -= 1
            y = 200 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
        }
        x = 179
        y = 200
        for i in 0..<10 { y -= 1; points.append(GesturePoint(x: x, y: y)) }
        for i in 0...40 {
            points.append(GesturePoint(x: x, y: y))
            x += 1
            y = 190 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
        }
        for i in 0..<15 { x -= 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeHShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 220.0, y = 200.0
        for _ in 0..<80 { points.append(GesturePoint(x: x, y: y)); y -= 1 }
        for _ in 0..<30 { points.append(GesturePoint(x: x, y: y)); y += 1 }
        let startY = y, startX = x
        for i in 0...40 {
            points.append(GesturePoint(x: x, y: y))
            x += 1
            y = startY + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
        }
        for _ in 0..<30 { points.append(GesturePoint(x: x, y: y)); y -= 1 }
        return points
    }

    private static func makeIShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 220.0, y = 200.0
        for _ in 0..<80 { points.append(GesturePoint(x: x, y: y)); y -= 1 }
        return points
    }

    private static func makeJShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 220.0, y = 200.0
        for _ in 0..<80 { points.append(GesturePoint(x: x, y: y)); y -= 1 }
        let startY = y
        for i in 0...40 {
            y = startY - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
            x -= 1
        }
        return points
    }

    private static func makeKShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<20 { x -= 0.7; y -= 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y += 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { x += 0.7; y -= 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeLShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<20 { y -= 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<15 { x += 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeMShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0...20 { y += 1; x += 0.2; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<15 { y -= 1; x += 0.5; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<15 { y += 1; x += 0.5; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y -= 1; x += 0.2; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeNShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0...20 { y += 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y -= 1; x += 0.7; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y += 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeOShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 241.0
        points.append(GesturePoint(x: x, y: y))
        for i in 0...40 {
            y -= 1
            x = 200 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
        }
        for i in 0...40 {
            x = 199 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
            y += 1
        }
        return points
    }

    private static func makePShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0...80 { y += 1; points.append(GesturePoint(x: x, y: y)) }
        x = 230
        points.append(GesturePoint(x: x, y: y))
        for i in 0...40 {
            x = 200 + 30 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
            y -= 1
        }
        x = 210
        points.append(GesturePoint(x: x, y: y))
        return points
    }

    private static func makeQShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 241.0
        for i in 0...40 {
            y -= 1
            x = 200 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            if i > 6 { points.append(GesturePoint(x: x, y: y)) }
        }
        for i in 0...40 {
            x = 199 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
            y += 1
        }
        for i in 0...6 { y -= 1; x = 200 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i))); points.append(GesturePoint(x: x, y: y)) }
        for i in 0...33 { y -= 1; x += 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeRShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0...80 { y += 1; points.append(GesturePoint(x: x, y: y)) }
        x = 230
        points.append(GesturePoint(x: x, y: y))
        for i in 0...40 {
            x = 200 + 30 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
            y -= 1
        }
        x = 210
        points.append(GesturePoint(x: x, y: y))
        for i in 0...40 {
            y -= 1
            x += 1
            points.append(GesturePoint(x: x, y: y))
        }
        return points
    }

    private static func makeSShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 220.0, y = 200.0
        for i in 0...40 {
            if i > 1 { points.append(GesturePoint(x: x, y: y)) }
            x -= 1
            y = 200 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
        }
        for i in 0...20 { x += 1; y = 200 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i))); points.append(GesturePoint(x: x, y: y)) }
        for i in 0...20 { y -= 1; x = 200 + sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i))); points.append(GesturePoint(x: x, y: y)) }
        for i in 0...40 { points.append(GesturePoint(x: x, y: y)); x -= 1; y = 160 - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i))) }
        return points
    }

    private static func makeTShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<15 { x += 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y -= 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeUShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 220.0, y = 240.0
        for _ in 0...40 { points.append(GesturePoint(x: x, y: y)); y -= 1 }
        let startY = y
        for i in 0...40 {
            y = startY - sqrt(20.0 * 20.0 - (20.0 - Double(i)) * (20.0 - Double(i)))
            points.append(GesturePoint(x: x, y: y))
            x += 1
        }
        for _ in 0..<40 { y += 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeXShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<20 { y += 1; x += 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { x -= 1; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y -= 1; x += 1; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    private static func makeYShapePoints() -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<10 { y -= 1; x += 0.6; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<10 { y += 1; x += 0.6; points.append(GesturePoint(x: x, y: y)) }
        for _ in 0..<20 { y -= 1; x -= 0.6; points.append(GesturePoint(x: x, y: y)) }
        return points
    }

    // MARK: - Picker strokes, translated straight from PreGesture.m

    /// `PreGesture.m` cases 26-29: 40 points at a 1pt step on both axes.
    private static func makeDiagonalPoints(right: Bool, up: Bool) -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<40 {
            x += right ? 1 : -1
            y += up ? 1 : -1
            points.append(GesturePoint(x: x, y: y))
        }
        return points
    }

    /// `PreGesture.m` cases 34-37: 35 points at a 1pt step on one axis.
    private static func makeCardinalPoints(horizontal: Bool, positive: Bool) -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<35 {
            if horizontal { x += positive ? 1 : -1 } else { y += positive ? 1 : -1 }
            points.append(GesturePoint(x: x, y: y))
        }
        return points
    }

    /// `PreGesture.m` cases 30-33: a 20-point vertical leg then a 15-point
    /// horizontal leg, both starting from the corner's free end.
    private static func makeCornerPoints(up: Bool, right: Bool) -> [GesturePoint] {
        var points: [GesturePoint] = []
        var x = 200.0, y = 200.0
        for _ in 0..<20 {
            y += up ? 1 : -1
            points.append(GesturePoint(x: x, y: y))
        }
        for _ in 0..<15 {
            x += right ? 1 : -1
            points.append(GesturePoint(x: x, y: y))
        }
        return points
    }
}

/// Provides gesture templates matching user-defined gesture patterns.
public final class GestureTemplateProvider {
    public static let shared = GestureTemplateProvider()

    private init() {}

    /// The preset gesture picker exactly as the original builds it
    /// (AppPrefsWindowController.m:628-662): 8 direction arrows, then the four
    /// box corners and the 26 letters each with a " Revered" (sic) twin.
    /// The arrows have no reversed entry, and the invented action presets
    /// ("Minimize", "Circle", …) are not part of the picker either.
    public var presetPickerEntries: [(name: String, stroke: Stroke)] {
        var entries: [(name: String, stroke: Stroke)] = [
            ("←", PresetGesture.arrowLeftSymbol.template),
            ("↑", PresetGesture.arrowUpSymbol.template),
            ("→", PresetGesture.arrowRightSymbol.template),
            ("↓", PresetGesture.arrowDownSymbol.template),
            ("↙", PresetGesture.arrowDownLeft.template),
            ("↗", PresetGesture.arrowUpRight.template),
            ("↘", PresetGesture.arrowDownRight.template),
            ("↖", PresetGesture.arrowUpLeft.template),
        ]
        for gesture in [PresetGesture.boxTopLeft, .boxTopRight, .boxBottomLeft, .boxBottomRight] {
            entries.append((gesture.rawValue, gesture.template))
            entries.append((gesture.rawValue + " Revered", reversedTemplate(for: gesture)))
        }
        for gesture in letterGestures {
            // Letters are stored as "A Shape" but the picker lists the bare letter.
            let letter = String(gesture.rawValue.dropLast(" Shape".count))
            entries.append((letter, gesture.template))
            entries.append((letter + " Revered", reversedTemplate(for: gesture)))
        }
        return entries
    }

    /// A-Z, in picker order.
    private var letterGestures: [PresetGesture] {
        [
            .letterA, .letterB, .letterC, .letterD, .letterE, .letterF, .letterG,
            .letterH, .letterI, .letterJ, .letterK, .letterL, .letterM, .letterN,
            .letterO, .letterP, .letterQ, .letterR, .letterS, .letterT, .letterU,
            .letterV, .letterW, .letterX, .letterY, .letterZ,
        ]
    }

    /// All available preset gestures.
    public var presets: [PresetGesture] {
        PresetGesture.allCases
    }

    /// Get the template stroke for a preset gesture.
    public func template(for gesture: PresetGesture) -> Stroke {
        gesture.template
    }

    /// Returns the reversed (point-order flipped) template for a preset
    /// gesture — the original's `IsRevered:YES` variants (same shape drawn
    /// in the opposite direction).
    public func reversedTemplate(for gesture: PresetGesture) -> Stroke {
        let stroke = gesture.template
        var reversed = Stroke(capacity: max(stroke.count, 1))
        for point in stroke.points.reversed() {
            reversed.addPoint(point)
        }
        return reversed
    }

    /// Get all templates as (name, stroke) pairs.
    public func allTemplates() -> [(name: String, stroke: Stroke)] {
        PresetGesture.allCases.map { ($0.rawValue, $0.template) }
    }

    /// Get all templates including reversed variants, named like the original
    /// preset picker (e.g. "A", "A Revered").
    public func allTemplatesIncludingReversed() -> [(name: String, stroke: Stroke)] {
        var result: [(name: String, stroke: Stroke)] = []
        for gesture in PresetGesture.allCases {
            result.append((gesture.rawValue, gesture.template))
            result.append((gesture.rawValue + " Revered", reversedTemplate(for: gesture)))
        }
        return result
    }
}
