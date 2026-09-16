//
//  Stroke.swift
//  MacStroke
//
//  A collection of GesturePoints representing a single gesture stroke.
//  Provides normalization: translate + scale to [0,1]², compute cumulative
//  time (t), time deltas (dt), and direction angles (alpha) in radians/π.
//

import Foundation

/// A stroke composed of gesture points. After normalization, points are
/// centered at (0.5, 0.5) and scaled so the largest dimension fits in [0,1].
public struct Stroke: Codable {
    public private(set) var points: [GesturePoint] = []
    public private(set) var capacity: Int

    public init(capacity: Int = 256) {
        assert(capacity > 0, "Capacity must be positive" )
        self.capacity = capacity
    }

    public init(points: [GesturePoint], capacity: Int = 256) {
        assert(!points.isEmpty, "Points array must not be empty" )
        self.capacity = capacity
        self.points = points
    }

    /// Number of points in the stroke.
    public var count: Int { points.count }

    /// Add a point if capacity allows.
    @discardableResult
    public mutating func addPoint(_ p: GesturePoint) -> Bool {
        guard points.count < capacity else { return false }
        points.append(p)
        return true
    }

    /// Add multiple points.
    public mutating func addPoints(_ ps: [GesturePoint]) {
        for p in ps {
            if !addPoint(p) { break }
        }
    }

    /// Normalize stroke: compute t (cumulative distance normalized to [0,1]),
    /// dt (inter-point distance), and alpha (atan2 direction / π, range [-1,1]).
    /// Then translate and scale so the bounding box is centered at (0.5, 0.5)
    /// and fits within [0,1]².
    public mutating func normalize() {
        let n = points.count
        guard n > 1 else {
            // Single point: set defaults
            if let p = points.first {
                points[0] = GesturePoint(x: 0.5, y: 0.5)
                points[0].t = 0
                points[0].dt = 0
                points[0].alpha = 0
            }
            return
        }

        // 1. Cumulative distance → t
        var totalDistance: Double = 0.0
        var distances: [Double] = [0.0]
        for i in 1..<n {
            let dx = points[i].x - points[i-1].x
            let dy = points[i].y - points[i-1].y
            let d = hypot(dx, dy)
            totalDistance += d
            distances.append(totalDistance)
        }

        // Avoid division by zero for identical points
        let safeTotal = totalDistance > 0.0001 ? totalDistance : 1.0

        for i in 0..<n {
            points[i].t = distances[i] / safeTotal
        }

        // 2. dt (distance between consecutive points)
        for i in 0..<n-1 {
            let dx = points[i+1].x - points[i].x
            let dy = points[i+1].y - points[i].y
            points[i].dt = hypot(dx, dy)
        }
        points[n-1].dt = 0.0

        // 3. alpha (direction / π)
        for i in 0..<n-1 {
            let dx = points[i+1].x - points[i].x
            let dy = points[i+1].y - points[i].y
            points[i].alpha = atan2(dy, dx) / .pi
        }
        points[n-1].alpha = points[n-2].alpha

        // 4. Translate + scale to [0,1]² centered at (0.5, 0.5)
        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for p in points {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }

        let scaleX = maxX - minX
        let scaleY = maxY - minY
        var scale = scaleX > scaleY ? scaleX : scaleY
        if scale < 0.001 {
            scale = 1.0
        }

        let centerX = (minX + maxX) / 2.0
        let centerY = (minY + maxY) / 2.0

        for i in 0..<n {
            points[i].x = (points[i].x - centerX) / scale + 0.5
            points[i].y = (points[i].y - centerY) / scale + 0.5
        }
    }
}
