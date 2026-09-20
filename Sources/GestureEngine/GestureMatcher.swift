//
//  GestureMatcher.swift
//  MacStroke
//
//  Implements the DTW (Dynamic Time Warping) gesture comparison algorithm.
//  Faithfully ports the original Objective-C logic from GestureCompare.m:
//
//  - compare(template:candidate:) returns a score 0..100 (higher = more similar)
//  - Stroke.normalize() computes t/dt/alpha (translate+scale to [0,1]²)
//  - score = MAX(1.0 - 2.5 * cost, 0.0) * 100
//

import Foundation

/// The "infinity" sentinel value used in the DP distance matrix.
/// Matches the original `CGFloat const stroke_infinity = 0.2` constant.
public let strokeInfinity: Double = 0.2

/// Small epsilon used to avoid division by zero.
private let kEPS: Double = 0.000001

/// Angle difference wrapped to [-1, 1] (in units of π).
/// Matches the original `angle_differenceWithAlpha:Beta:` method.
private func angleDifference(alpha: Double, beta: Double) -> Double {
    var d = alpha - beta
    if d < -1.0 {
        d += 2.0
    } else if d > 1.0 {
        d -= 2.0
    }
    return d
}

/// Squared angle difference between two alpha values (in units of π).
private func squaredAngleDiff(alphaA: Double, alphaB: Double) -> Double {
    let d = angleDifference(alpha: alphaA, beta: alphaB)
    return d * d
}

/// Main entry point: compare two normalized strokes and return a similarity score.
///
/// - Parameters:
///   - template: The template stroke (user-defined gesture)
///   - candidate: The candidate stroke (user-drawn gesture)
/// - Returns: Score in range 0..100 (100 = identical)
public func compare(template: Stroke, candidate: Stroke) -> Double {
    var tStroke = template
    var cStroke = candidate

    // Normalize both strokes (translate+scale to [0,1]², compute t/dt/alpha)
    tStroke.normalize()
    cStroke.normalize()

    // If either stroke has fewer than 10 points, return 0
    if tStroke.count < 10 || cStroke.count < 10 {
        return 0.0
    }

    // Compute the DP cost using the original algorithm
    let cost = strokeCompareCost(template: tStroke, candidate: cStroke)

    // Score: MAX(1.0 - 2.5 * cost, 0.0) * 100
    return max(1.0 - 2.5 * cost, 0.0) * 100.0
}

/// Compute the DTW path cost between two normalized strokes.
///
/// Faithful port of the original `stroke_compareWithStrokeA` band-DP: cells are
/// relaxed forward from each reachable (x, y) by up to 4 expansion steps
/// (`k < 4`), and `step` only accepts moves whose time deltas respect the 2.2x
/// slope constraint, accumulating the segment-wise squared angle difference
/// weighted by `d * (dtx + dty)`.
private func strokeCompareCost(template a: Stroke, candidate b: Stroke) -> Double {
    let M = a.count
    let N = b.count

    if M < 2 || N < 2 { return strokeInfinity }

    let m = M - 1
    let n = N - 1

    // Original initializes all cells to `stroke_infinity` except dist[0] = 0;
    // cells only become finite through `step` relaxations.
    var dist = [Double](repeating: strokeInfinity, count: M * N)
    dist[0] = 0.0

    /// Relax the transition from cell (x, y) to cell (x2, y2).
    /// - Parameters:
    ///   - tx: `a[x].t`, the time origin on stroke a for this relaxation
    ///   - ty: `b[y].t`, the time origin on stroke b for this relaxation
    func step(x: Int, y: Int, tx: Double, ty: Double, k: inout Int, x2: Int, y2: Int) {
        let dtx = a.points[x2].t - tx
        let dty = b.points[y2].t - ty
        if dtx >= dty * 2.2 || dty >= dtx * 2.2 || dtx < kEPS || dty < kEPS {
            return
        }
        k += 1

        // Walk the two arcs [tx, tx+dtx] and [ty, ty+dty] in normalized-time
        // order, integrating the squared angle difference along the path.
        var d = 0.0
        var i = x
        var j = y
        var nextTx = (a.points[i + 1].t - tx) / dtx
        var nextTy = (b.points[j + 1].t - ty) / dty
        var curT = 0.000000001

        while true {
            let ad = squaredAngleDiff(alphaA: a.points[i].alpha, alphaB: b.points[j].alpha)
            var nextT = min(nextTx, nextTy)
            let done = nextT >= 1.0 - kEPS
            if done { nextT = 1.0 }
            d += (nextT - curT) * ad
            if done { break }
            curT = nextT
            if nextTx < nextTy {
                i += 1
                nextTx = (a.points[i + 1].t - tx) / dtx
            } else {
                j += 1
                nextTy = (b.points[j + 1].t - ty) / dty
            }
        }

        let newDist = dist[x * N + y] + d * (dtx + dty)
        if newDist >= dist[x2 * N + y2] { return }
        dist[x2 * N + y2] = newDist
    }

    for x in 0..<m {
        for y in 0..<n {
            if dist[x * N + y] >= strokeInfinity { continue }

            let tx = a.points[x].t
            let ty = b.points[y].t
            var maxX = x
            var maxY = y
            var k = 0

            while k < 4 {
                if a.points[maxX + 1].t - tx > b.points[maxY + 1].t - ty {
                    maxY += 1
                    if maxY == n {
                        step(x: x, y: y, tx: tx, ty: ty, k: &k, x2: m, y2: n)
                        break
                    }
                    var x2 = x + 1
                    while x2 <= maxX {
                        step(x: x, y: y, tx: tx, ty: ty, k: &k, x2: x2, y2: maxY)
                        x2 += 1
                    }
                } else {
                    maxX += 1
                    if maxX == m {
                        step(x: x, y: y, tx: tx, ty: ty, k: &k, x2: m, y2: n)
                        break
                    }
                    var y2 = y + 1
                    while y2 <= maxY {
                        step(x: x, y: y, tx: tx, ty: ty, k: &k, x2: maxX, y2: y2)
                        y2 += 1
                    }
                }
            }
        }
    }

    return dist[M * N - 1]
}
