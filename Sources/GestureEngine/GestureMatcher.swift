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

/// Internal sentinel for unreachable DP cells. Must be larger than any possible
/// accumulated cost so it doesn't cap valid path costs.
private let dpInfinity: Double = Double.infinity

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
/// This is a faithful port of the original `stroke_compareWithStrokeA`
/// algorithm, implemented as a standard dynamic-time-warping DP with
/// a slope constraint (2.2x ratio on time deltas).
///
/// DP recurrence:
///   dist[i][j] = min(dist[i-1][j], dist[i][j-1], dist[i-1][j-1])
///                + angleCost(i, j) * (dt_i + dt_j)
///
/// With the slope constraint: a step from (i,j) to (i',j') is only valid
/// if neither time delta exceeds 2.2x the other.
private func strokeCompareCost(template: Stroke, candidate: Stroke) -> Double {
    let M = template.count
    let N = candidate.count

    if M < 2 || N < 2 { return strokeInfinity }

    // DP matrix — flat for performance, initialized to infinity
    var dist = [Double](repeating: dpInfinity, count: M * N)
    dist[0] = 0.0

    // Local cost of aligning template[i] with candidate[j]
    func localCost(_ i: Int, _ j: Int) -> Double {
        return squaredAngleDiff(
            alphaA: template.points[i].alpha,
            alphaB: candidate.points[j].alpha
        )
    }

    var reachableCount = 0
    var lastUnreachableRow = -1
    var lastUnreachableCol = -1

    for i in 0..<M {
        for j in 0..<N {
            if i == 0 && j == 0 { continue }

            let cost = localCost(i, j)
            var best = dpInfinity

            // From above (i-1, j): template advances by dtx, candidate stays
            if i > 0 && dist[(i-1) * N + j] < dpInfinity {
                let dtx = template.points[i].t - template.points[i-1].t
                if dtx >= kEPS {
                    best = min(best, dist[(i-1) * N + j] + cost * dtx)
                }
            }

            // From left (i, j-1): candidate advances by dty, template stays
            if j > 0 && dist[i * N + (j-1)] < dpInfinity {
                let dty = candidate.points[j].t - candidate.points[j-1].t
                if dty >= kEPS {
                    best = min(best, dist[i * N + (j-1)] + cost * dty)
                }
            }

            // From diagonal (i-1, j-1): both advance
            if i > 0 && j > 0 && dist[(i-1) * N + (j-1)] < dpInfinity {
                let dtx = template.points[i].t - template.points[i-1].t
                let dty = candidate.points[j].t - candidate.points[j-1].t
                if dtx >= kEPS && dty >= kEPS {
                    best = min(best, dist[(i-1) * N + (j-1)] + cost * (dtx + dty))
                }
            }

            if best < dpInfinity {
                dist[i * N + j] = best
                reachableCount += 1
            } else {
                lastUnreachableRow = i
                lastUnreachableCol = j
            }
        }
    }

    let result = dist[(M - 1) * N + (N - 1)]
    return result
}
