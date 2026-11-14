import CoreGraphics
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

    /// A rectangle drawn over a picture of `size`, in AppKit's coordinates
    /// (origin at the bottom left), kept within the picture.
    public init(selection: CGRect, in size: CGSize) {
        let width = max(1, Double(size.width)), height = max(1, Double(size.height))
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        let rect = selection.standardized
        x0 = clamp(Double(rect.minX) / width)
        x1 = clamp(Double(rect.maxX) / width)
        y0 = clamp(1 - Double(rect.maxY) / height)
        y1 = clamp(1 - Double(rect.minY) / height)
    }

    public static let whole = UnitRect(x0: 0, y0: 0, x1: 1, y1: 1)
}
