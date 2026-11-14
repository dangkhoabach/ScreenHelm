import CoreGraphics
import Foundation
import Testing
@testable import ScreenHelmCore

@Suite struct StreamGeometryTests {
    private let full = UnitRect(x0: 0, y0: 0, x1: 1, y1: 1)
    /// The lower half of a TV, for an ultra-wide desktop on it.
    private let lowerHalf = UnitRect(x0: 0, y0: 0.5, x1: 1, y1: 1)

    @Test func theCropCountsFromTheTopAndTheLayerFromTheBottom() {
        #expect(StreamGeometry.contentsRect(for: full) == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(StreamGeometry.contentsRect(for: lowerHalf) == CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(StreamGeometry.contentsRect(for: UnitRect(x0: 0.25, y0: 0, x1: 0.75, y1: 0.25)) == CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.25))
    }

    @Test func aCropTooSmallOrOutsideIsRefused() {
        #expect(StreamGeometry.isUsable(full) && StreamGeometry.isUsable(lowerHalf))
        #expect(!StreamGeometry.isUsable(UnitRect(x0: 0.5, y0: 0, x1: 0.5, y1: 1)))
        #expect(!StreamGeometry.isUsable(UnitRect(x0: -0.1, y0: 0, x1: 1, y1: 1)))
        #expect(!StreamGeometry.isUsable(UnitRect(x0: 0, y0: 0, x1: 1, y1: 1.2)))
    }

    @Test func theShapeFollowsCropAndTurn() {
        let tv = CGSize(width: 3840, height: 2160)
        #expect(abs(StreamGeometry.aspect(sourceSize: tv, crop: full, rotation: 0) - 16.0 / 9) < 1e-9)
        #expect(abs(StreamGeometry.aspect(sourceSize: tv, crop: lowerHalf, rotation: 0) - 32.0 / 9) < 1e-9)
        #expect(abs(StreamGeometry.aspect(sourceSize: tv, crop: full, rotation: 90) - 9.0 / 16) < 1e-9)
        #expect(StreamGeometry.aspect(sourceSize: .zero, crop: full, rotation: 0) == 1)
    }

    @Test func fitLeavesBarsFillCutsStretchDistorts() {
        let container = CGSize(width: 1000, height: 1000)
        #expect(StreamGeometry.frame(aspect: 2, in: container, scaling: .fit) == CGRect(x: 0, y: 250, width: 1000, height: 500))
        #expect(StreamGeometry.frame(aspect: 2, in: container, scaling: .fill) == CGRect(x: -500, y: 0, width: 2000, height: 1000))
        #expect(StreamGeometry.frame(aspect: 2, in: container, scaling: .stretch) == CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(StreamGeometry.frame(aspect: 0.5, in: container, scaling: .fit) == CGRect(x: 250, y: 0, width: 500, height: 1000))
        #expect(StreamGeometry.frame(aspect: 2, in: .zero, scaling: .fit) == .zero)
    }

    @Test func turnsAndFlips() {
        let none = StreamGeometry.transform(rotation: 0, flipHorizontal: false, flipVertical: false)
        #expect(none == .identity)
        // A teleprompter's mirror: left and right swapped.
        let mirrored = CGPoint(x: 1, y: 0).applying(StreamGeometry.transform(rotation: 0, flipHorizontal: true, flipVertical: false))
        #expect(abs(mirrored.x + 1) < 1e-9 && abs(mirrored.y) < 1e-9)
        // A quarter turn clockwise takes "up" to "right".
        let turned = CGPoint(x: 0, y: 1).applying(StreamGeometry.transform(rotation: 90, flipHorizontal: false, flipVertical: false))
        #expect(abs(turned.x - 1) < 1e-9 && abs(turned.y) < 1e-9)
    }

    /// A small picture-in-picture window doesn't need the source's full resolution.
    @Test func onlyThePixelsShownAreCaptured() {
        let source = CGSize(width: 3840, height: 2160)
        let small = StreamGeometry.captureSize(shown: CGSize(width: 480, height: 270), scale: 2, crop: full, sourcePixels: source)
        #expect(small == CGSize(width: 960, height: 540))
        // Never more than the source has.
        let big = StreamGeometry.captureSize(shown: CGSize(width: 4000, height: 2250), scale: 2, crop: full, sourcePixels: source)
        #expect(big == source)
        // Half the source shown needs twice the capture for the same sharpness.
        let cropped = StreamGeometry.captureSize(shown: CGSize(width: 480, height: 135), scale: 2, crop: lowerHalf, sourcePixels: source)
        #expect(cropped == CGSize(width: 1920, height: 1080))
    }

    @Test func aStreamOfADisplayOntoItselfNeedsAFilter() {
        var config = StreamConfig(name: "Filter", source: .display("a"), target: .display("a"))
        #expect(!config.isValid)
        config.filters.monochrome = true
        #expect(config.isValid)
        var plain = StreamConfig(name: "PiP", source: .display("a"))
        #expect(plain.isValid)
        plain.framesPerSecond = 77
        #expect(!plain.isValid)
        plain.framesPerSecond = 60
        plain.rotation = 45
        #expect(!plain.isValid)
        plain.rotation = 270
        plain.name = " "
        #expect(!plain.isValid)
    }

    @Test func configsSurviveStorage() throws {
        var config = StreamConfig(name: "Notes", source: .window(bundleID: "com.apple.Notes", title: ""), target: .display("tv"),
                                  crop: lowerHalf, rotation: 180, flipHorizontal: true, scaling: .fill, framesPerSecond: 60, clickThrough: true)
        config.filters = StreamFilters(monochrome: true, saturation: 0.5, hue: 20, blur: 3, sharpen: 0.4, lutPath: "/tmp/look.cube")
        config.hdr = true
        config.hidesPointerOnTarget = true
        let decoded = try JSONDecoder().decode(StreamConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        #expect(!config.filters.isNeutral && StreamFilters().isNeutral)
    }

    /// A rectangle dragged over a display, in AppKit's bottom-left coordinates,
    /// becomes a crop counted from the top left, kept within the display.
    @Test func aDraggedRectangleBecomesACrop() {
        let size = CGSize(width: 1000, height: 500)
        // The top right quarter.
        #expect(UnitRect(selection: CGRect(x: 500, y: 250, width: 500, height: 250), in: size) == UnitRect(x0: 0.5, y0: 0, x1: 1, y1: 0.5))
        // Dragged up and to the left, and past the edge.
        let crop = UnitRect(selection: CGRect(x: 600, y: 100, width: -500, height: 900), in: size)
        #expect(crop == UnitRect(x0: 0.1, y0: 0, x1: 0.6, y1: 0.8))
        #expect(StreamGeometry.isUsable(crop))
    }

    /// A stream saved before HDR and the hidden pointer existed reads with both off.
    @Test func olderConfigsTakeDefaultsForNewFields() throws {
        let config = StreamConfig(name: "Old", source: .display("a"), hdr: true, hidesPointerOnTarget: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object["hdr"] = nil
        object["hidesPointerOnTarget"] = nil
        let decoded = try JSONDecoder().decode(StreamConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.hdr && !decoded.hidesPointerOnTarget)
        #expect(decoded.name == "Old" && decoded.source == .display("a"))
    }
}

@Suite struct CubeLUTTests {
    @Test func aCubeFileIsRead() throws {
        var text = "# a comment\nTITLE \"Identity\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n\n"
        for blue in 0...1 { for green in 0...1 { for red in 0...1 { text += "\(red).0 \(green).0 \(blue).0\n" } } }
        let lut = try #require(CubeLUT(parsing: text))
        #expect(lut.size == 2)
        #expect(lut.values.count == 32)
        // Red changes fastest: the second point is pure red.
        #expect(Array(lut.values[4..<8]) == [1, 0, 0, 1])
        #expect(Array(lut.values[28..<32]) == [1, 1, 1, 1])
    }

    @Test func whatIsNotACubeIsRefused() {
        #expect(CubeLUT(parsing: "") == nil)
        #expect(CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n") == nil) // too few points
        #expect(CubeLUT(parsing: "LUT_1D_SIZE 4\n0 0 0\n") == nil)
        #expect(CubeLUT(parsing: "LUT_3D_SIZE 999\n") == nil)
    }
}
