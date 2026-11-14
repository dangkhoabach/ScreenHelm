import CoreGraphics
import Foundation

/// What is done to a streamed picture before it is shown.
public struct StreamFilters: Codable, Equatable, Sendable {
    public var monochrome: Bool
    public var invert: Bool
    /// 0…2; 1 is unchanged.
    public var saturation: Double
    /// Degrees, −180…180.
    public var hue: Double
    /// Radius in points, 0…30.
    public var blur: Double
    /// 0…2.
    public var sharpen: Double
    /// The path of a .cube file to grade the picture with.
    public var lutPath: String?

    public init(monochrome: Bool = false, invert: Bool = false, saturation: Double = 1, hue: Double = 0, blur: Double = 0,
                sharpen: Double = 0, lutPath: String? = nil) {
        self.monochrome = monochrome
        self.invert = invert
        self.saturation = saturation
        self.hue = hue
        self.blur = blur
        self.sharpen = sharpen
        self.lutPath = lutPath
    }

    public var isNeutral: Bool { self == StreamFilters() }
}

/// A live copy of a display or a window, shown in a floating window or
/// across another display.
public struct StreamConfig: Codable, Equatable, Identifiable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        /// A display, by its identity key.
        case display(String)
        /// The first window of an app with this title; an empty title is any of its windows.
        case window(bundleID: String, title: String)
    }

    public enum Target: Codable, Hashable, Sendable {
        /// A window that floats over everything: picture in picture.
        case floatingWindow
        /// The whole of another display.
        case display(String)
    }

    public enum Scaling: String, Codable, Sendable, CaseIterable {
        /// All of the picture, with bars if the shapes differ.
        case fit
        /// No bars; the picture's edges are cut.
        case fill
        /// No bars and nothing cut; the picture is distorted.
        case stretch
    }

    public var id: UUID
    public var name: String
    public var source: Source
    public var target: Target
    /// The part of the source shown, in fractions of it, from the top left.
    public var crop: UnitRect
    /// 0, 90, 180 or 270, clockwise.
    public var rotation: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var scaling: Scaling
    public var framesPerSecond: Int
    public var showsCursor: Bool
    /// Clicks go through the picture to what is under it.
    public var clickThrough: Bool
    public var filters: StreamFilters
    /// Captured with its HDR range, on macOS 15 and later.
    public var hdr: Bool
    /// Shown across a display: the pointer is hidden while it is over that display.
    public var hidesPointerOnTarget: Bool

    public init(id: UUID = UUID(), name: String, source: Source, target: Target = .floatingWindow,
                crop: UnitRect = UnitRect(x0: 0, y0: 0, x1: 1, y1: 1), rotation: Int = 0, flipHorizontal: Bool = false,
                flipVertical: Bool = false, scaling: Scaling = .fit, framesPerSecond: Int = 30, showsCursor: Bool = true,
                clickThrough: Bool = false, filters: StreamFilters = StreamFilters(), hdr: Bool = false, hidesPointerOnTarget: Bool = false) {
        self.id = id
        self.name = name
        self.source = source
        self.target = target
        self.crop = crop
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.scaling = scaling
        self.framesPerSecond = framesPerSecond
        self.showsCursor = showsCursor
        self.clickThrough = clickThrough
        self.filters = filters
        self.hdr = hdr
        self.hidesPointerOnTarget = hidesPointerOnTarget
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, target, crop, rotation, flipHorizontal, flipVertical, scaling, framesPerSecond, showsCursor, clickThrough, filters
        case hdr, hidesPointerOnTarget
    }

    /// A stream saved before a setting existed reads with that setting's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(Source.self, forKey: .source)
        target = try c.decode(Target.self, forKey: .target)
        crop = try c.decode(UnitRect.self, forKey: .crop)
        rotation = try c.decode(Int.self, forKey: .rotation)
        flipHorizontal = try c.decode(Bool.self, forKey: .flipHorizontal)
        flipVertical = try c.decode(Bool.self, forKey: .flipVertical)
        scaling = try c.decode(Scaling.self, forKey: .scaling)
        framesPerSecond = try c.decode(Int.self, forKey: .framesPerSecond)
        showsCursor = try c.decode(Bool.self, forKey: .showsCursor)
        clickThrough = try c.decode(Bool.self, forKey: .clickThrough)
        filters = try c.decode(StreamFilters.self, forKey: .filters)
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? false
        hidesPointerOnTarget = try c.decodeIfPresent(Bool.self, forKey: .hidesPointerOnTarget) ?? false
    }

    public static let allowedFrameRates = [5, 10, 15, 24, 30, 60, 120]

    /// A display can't be streamed onto itself full screen: the picture would feed on itself.
    public var isValid: Bool {
        if case .display(let source) = source, case .display(let target) = target, source == target, filters.isNeutral { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && StreamGeometry.isUsable(crop)
            && [0, 90, 180, 270].contains(rotation) && Self.allowedFrameRates.contains(framesPerSecond)
    }
}

public enum StreamGeometry {
    /// A crop that leaves something to show.
    public static func isUsable(_ crop: UnitRect) -> Bool {
        crop.x0 >= 0 && crop.y0 >= 0 && crop.x1 <= 1 && crop.y1 <= 1 && crop.x1 - crop.x0 >= 0.02 && crop.y1 - crop.y0 >= 0.02
    }

    /// The crop as a layer's `contentsRect`, which counts from the bottom left.
    public static func contentsRect(for crop: UnitRect) -> CGRect {
        CGRect(x: crop.x0, y: 1 - crop.y1, width: crop.x1 - crop.x0, height: crop.y1 - crop.y0)
    }

    /// Width over height of what is shown, after cropping and turning.
    public static func aspect(sourceSize: CGSize, crop: UnitRect, rotation: Int) -> Double {
        let width = sourceSize.width * (crop.x1 - crop.x0), height = sourceSize.height * (crop.y1 - crop.y0)
        guard width > 0, height > 0 else { return 1 }
        return rotation % 180 == 0 ? width / height : height / width
    }

    /// Where a picture of a given shape goes inside a container.
    public static func frame(aspect: Double, in container: CGSize, scaling: StreamConfig.Scaling) -> CGRect {
        guard aspect > 0, container.width > 0, container.height > 0 else { return CGRect(origin: .zero, size: container) }
        let containerAspect = container.width / container.height
        var size = container
        switch scaling {
        case .stretch:
            break
        case .fit:
            if aspect > containerAspect { size.height = container.width / aspect } else { size.width = container.height * aspect }
        case .fill:
            if aspect > containerAspect { size.width = container.height * aspect } else { size.height = container.width / aspect }
        }
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The turn and the flips as one transform about the picture's center.
    /// The angle is clockwise on screen, where y goes up.
    public static func transform(rotation: Int, flipHorizontal: Bool, flipVertical: Bool) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: -Double(rotation) * .pi / 180)
            .scaledBy(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
    }

    /// The pixels to capture for a picture shown at `size` points: no more
    /// than the screen can show, and no more than the source has.
    public static func captureSize(shown size: CGSize, scale: Double, crop: UnitRect, sourcePixels: CGSize) -> CGSize {
        let share = max(0.02, min(crop.x1 - crop.x0, crop.y1 - crop.y0))
        // The capture is of the whole source; the crop is cut from it afterwards.
        let wanted = max(size.width, size.height) * scale / share
        let longest = max(sourcePixels.width, sourcePixels.height)
        let factor = min(1, wanted / max(1, longest))
        return CGSize(width: max(2, (sourcePixels.width * factor).rounded()), height: max(2, (sourcePixels.height * factor).rounded()))
    }
}

/// A colour lookup table in the .cube format film and photo tools write.
public struct CubeLUT: Equatable, Sendable {
    /// Points along each side of the cube.
    public var size: Int
    /// Red, green, blue and alpha for each point, red changing fastest.
    public var values: [Float]

    /// Nil when the text isn't a 3D .cube file or doesn't hold the points it says it does.
    public init?(parsing text: String) {
        var size = 0
        var values: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if parts[0] == "LUT_3D_SIZE", parts.count == 2, let parsed = Int(parts[1]) {
                size = parsed
            } else if parts[0] == "LUT_1D_SIZE" {
                return nil
            } else if parts.count == 3, let red = Float(parts[0]), let green = Float(parts[1]), let blue = Float(parts[2]) {
                values.append(contentsOf: [red, green, blue, 1])
            }
        }
        guard (2...64).contains(size), values.count == size * size * size * 4 else { return nil }
        self.size = size
        self.values = values
    }
}
