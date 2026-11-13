import Foundation

/// One mode a display can be set to: a size in points, the pixels behind
/// it, and a refresh rate.
public struct DisplayModeInfo: Codable, Hashable, Sendable, Identifiable {
    /// The window server's number for the mode, which is what sets it.
    public var number: Int
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    /// Drawn at twice the points, the sharp kind.
    public var isHiDPI: Bool
    /// The panel's own pixels, one to one.
    public var isNative: Bool
    public var isVariableRate: Bool
    public var isProMotion: Bool
    public var bitsPerSample: Int

    public var id: Int { number }

    public init(number: Int, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double,
                isHiDPI: Bool, isNative: Bool = false, isVariableRate: Bool = false, isProMotion: Bool = false,
                bitsPerSample: Int = 8) {
        self.number = number
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
        self.isNative = isNative
        self.isVariableRate = isVariableRate
        self.isProMotion = isProMotion
        self.bitsPerSample = bitsPerSample
    }

    public var resolution: DisplayResolution {
        DisplayResolution(width: width, height: height, isHiDPI: isHiDPI)
    }

    /// 59.94 and 60 are the same choice to a person; the list shows one.
    public var roundedRate: Int { Int(refreshRate.rounded()) }
}

/// A size on screen without the refresh rate: one row of the resolution list.
public struct DisplayResolution: Codable, Hashable, Sendable, Comparable {
    public var width: Int
    public var height: Int
    public var isHiDPI: Bool

    public init(width: Int, height: Int, isHiDPI: Bool) {
        self.width = width
        self.height = height
        self.isHiDPI = isHiDPI
    }

    /// "1800 × 1169".
    public var label: String { "\(width) × \(height)" }

    /// Larger first, and the sharp one before the plain one of the same size.
    public static func < (a: DisplayResolution, b: DisplayResolution) -> Bool {
        if a.width != b.width { return a.width > b.width }
        if a.height != b.height { return a.height > b.height }
        return a.isHiDPI && !b.isHiDPI
    }
}

public enum DisplayModes {
    /// Every size the display offers, once each, larger first.
    public static func resolutions(in modes: [DisplayModeInfo]) -> [DisplayResolution] {
        Array(Set(modes.map(\.resolution))).sorted()
    }

    /// The refresh rates a size comes in, highest first, one per whole number.
    public static func refreshRates(for resolution: DisplayResolution, in modes: [DisplayModeInfo]) -> [Int] {
        Array(Set(modes.filter { $0.resolution == resolution }.map(\.roundedRate))).sorted(by: >)
    }

    /// The mode for a size at the rate closest to `rate`. Among modes of the
    /// same rounded rate the exact one wins (60 before 59.94), then the one
    /// with more bits per colour.
    public static func mode(for resolution: DisplayResolution, near rate: Double, in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        modes.filter { $0.resolution == resolution }.min { a, b in
            let da = abs(a.refreshRate - rate), db = abs(b.refreshRate - rate)
            if abs(da - db) > 0.001 { return da < db }
            return a.bitsPerSample > b.bitsPerSample
        }
    }

    /// The same size at another rate.
    public static func mode(like current: DisplayModeInfo, atRate rate: Int, in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        mode(for: current.resolution, near: Double(rate), in: modes.filter { $0.roundedRate == rate })
    }

    /// On a display with a camera housing, each size comes twice: one that
    /// reaches the top of the panel, around the housing, and one that stops
    /// below it. They share the width, sharpness and rate, and differ in
    /// height by the housing alone (under 6% here; other pairs of a width
    /// are different aspect ratios, much further apart).
    public static func notchTwin(of mode: DisplayModeInfo, in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        modes.filter {
            $0.width == mode.width && $0.isHiDPI == mode.isHiDPI && $0.height != mode.height
                && abs(Double($0.height - mode.height)) / Double(mode.height) < 0.06
        }
        .min { abs($0.refreshRate - mode.refreshRate) < abs($1.refreshRate - mode.refreshRate) }
    }

    /// Whether `mode` is the taller of such a pair, the one that shows the housing.
    public static func showsNotch(_ mode: DisplayModeInfo, in modes: [DisplayModeInfo]) -> Bool? {
        notchTwin(of: mode, in: modes).map { mode.height > $0.height }
    }

    /// The sizes a slider steps through: those of one sharpness and of the
    /// current shape (to a percent), smallest first, so dragging right
    /// gives more room.
    public static func sliderResolutions(like current: DisplayModeInfo, in modes: [DisplayModeInfo]) -> [DisplayResolution] {
        let ratio = Double(current.width) / Double(current.height)
        return resolutions(in: modes)
            .filter { $0.isHiDPI == current.isHiDPI && abs(Double($0.width) / Double($0.height) - ratio) / ratio < 0.01 }
            .reversed()
    }

    /// The one before or after the current size in `sliderResolutions`; nil at the ends.
    public static func neighbor(of current: DisplayModeInfo, in modes: [DisplayModeInfo], larger: Bool) -> DisplayModeInfo? {
        let steps = sliderResolutions(like: current, in: modes)
        guard let index = steps.firstIndex(of: current.resolution), steps.indices.contains(index + (larger ? 1 : -1)) else { return nil }
        return mode(for: steps[index + (larger ? 1 : -1)], near: current.refreshRate, in: modes)
    }

    /// The sharp or plain version of the current size.
    public static func hiDPITwin(of current: DisplayModeInfo, in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        mode(for: DisplayResolution(width: current.width, height: current.height, isHiDPI: !current.isHiDPI),
             near: current.refreshRate, in: modes)
    }
}
