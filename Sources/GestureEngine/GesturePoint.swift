//
//  GesturePoint.swift
//  MacStroke
//
//  Represents a single point in a gesture stroke with temporal and angular metadata.
//

import Foundation

/// A single point in a gesture stroke, including position, normalized time,
/// time delta, and direction angle (normalized by π).
public struct GesturePoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var t: Double = 0.0
    public var dt: Double = 0.0
    public var alpha: Double = 0.0

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
