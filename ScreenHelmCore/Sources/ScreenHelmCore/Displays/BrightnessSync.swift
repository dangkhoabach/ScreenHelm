import Foundation

/// What the other displays' brightness follows.
public enum BrightnessSyncSource: String, Codable, Sendable, CaseIterable {
    case off
    /// The built-in display, which macOS already adjusts to the room.
    case builtIn
    /// The light sensor, read directly.
    case ambientLight
}

/// Keeping several displays equally bright.
public enum BrightnessSync {
    /// The same slider value on the target, moved by the user's offset for
    /// a monitor that looks brighter or darker at the same setting.
    public static func target(for source: Double, offset: Double) -> Double {
        min(1, max(0, source + offset))
    }

    /// The slider value at which the target gives the same light as the
    /// source, for a monitor whose range in nits is known: its backlight
    /// is taken as even between its lowest and highest.
    public static func target(forNits nits: Double, minimumNits: Double, maximumNits: Double) -> Double {
        guard maximumNits > minimumNits else { return 1 }
        return min(1, max(0, (nits - minimumNits) / (maximumNits - minimumNits)))
    }

    /// A slider value for the light in the room: a tenth in the dark, half
    /// in a lit room (about 100 lux), full by a bright window (1000 lux
    /// and up). The eye follows the logarithm of the light.
    public static func value(forLux lux: Double) -> Double {
        0.1 + 0.9 * min(1, log10(1 + max(0, lux)) / 3)
    }

    /// A sensor's readings jump; the average of the last few is followed,
    /// and only once it has moved enough to be worth a change.
    public static func smoothed(_ samples: [Double], last applied: Double?, threshold: Double = 0.03) -> Double? {
        guard !samples.isEmpty else { return nil }
        let average = samples.reduce(0, +) / Double(samples.count)
        if let applied, abs(average - applied) < threshold { return nil }
        return average
    }
}
