import Foundation

/// A part of a picture as fractions of it: 0 is the left or top edge, 1 the
/// right or bottom one.
public struct UnitRect: Codable, Equatable, Sendable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
}
