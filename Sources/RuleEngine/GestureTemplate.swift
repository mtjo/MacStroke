//
//  GestureTemplate.swift
//  MacStroke
//
//  A template stroke that a rule matches against.
//  Stores the normalized points of a reference gesture.
//

import Foundation
import GestureEngine

/// A template stroke used for rule matching.
///
/// A template is a normalized stroke that represents the expected gesture
/// for a rule. When a user draws a stroke, it's compared against the template
/// using the DTW algorithm in `compare()`.
public struct GestureTemplate: Codable {
    /// The normalized points of the template stroke.
    public let points: [GesturePoint]
    /// Human-readable name for this template.
    public let name: String

    /// Create a new template from a list of points.
    /// - Parameters:
    ///   - points: The raw points of the template stroke
    ///   - name: Human-readable name
    public init(points: [GesturePoint], name: String) {
        self.points = points
        self.name = name
    }

    /// Create a template from a Stroke.
    /// - Parameter stroke: The stroke to convert
    public init(from stroke: Stroke, name: String) {
        self.points = stroke.points
        self.name = name
    }

    /// Convert this template to a Stroke for comparison.
    public var stroke: Stroke {
        Stroke(points: points)
    }
}