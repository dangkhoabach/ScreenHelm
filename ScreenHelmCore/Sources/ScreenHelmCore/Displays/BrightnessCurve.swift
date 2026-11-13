import Foundation

/// How a display's brightness is changed.
public enum BrightnessMethod: String, Codable, Sendable, CaseIterable {
    /// ScreenHelm picks, by the kind of display and what answers.
    case automatic
    /// The backlight of an Apple display.
    case apple
    /// The monitor's own brightness, over DDC.
    case ddc
    /// The colour table: darker pixels, the backlight untouched.
    case gamma
    /// A black window over the screen.
    case overlay
}

/// One slider that runs the backlight first and, below what the backlight
/// can do, goes on darkening in software.
public enum BrightnessCurve {
    /// Software dimming never goes under this on its own: a screen darker
    /// than 15% is hard to read, and one at zero can't be fixed by looking at it.
    public static let softwareFloor = 0.15
    /// The share of the slider, at its low end, given to software dimming
    /// when a display has both.
    public static let softwareShare = 0.2

    public struct Split: Equatable, Sendable {
        /// 0…1 for the backlight or the monitor.
        public var hardware: Double
        /// 0…1 for the colour table or overlay; 1 leaves the picture alone.
        public var software: Double
    }

    /// Where a slider value lands on each. With no hardware control the
    /// whole slider is software; with no software part it is all hardware.
    public static func split(_ value: Double, hasHardware: Bool, combined: Bool, allowBlack: Bool) -> Split {
        let value = min(1, max(0, value))
        let floor = allowBlack ? 0 : softwareFloor
        guard hasHardware else { return Split(hardware: 1, software: floor + (1 - floor) * value) }
        guard combined else { return Split(hardware: value, software: 1) }
        if value >= softwareShare {
            return Split(hardware: (value - softwareShare) / (1 - softwareShare), software: 1)
        }
        return Split(hardware: 0, software: floor + (1 - floor) * (value / softwareShare))
    }

    /// The slider value that `split` turns into these, to show a display's
    /// state after it was changed elsewhere.
    public static func value(hardware: Double, software: Double, hasHardware: Bool, combined: Bool, allowBlack: Bool) -> Double {
        let floor = allowBlack ? 0 : softwareFloor
        let softwarePart = floor >= 1 ? 1 : min(1, max(0, (software - floor) / (1 - floor)))
        guard hasHardware else { return softwarePart }
        guard combined else { return min(1, max(0, hardware)) }
        if software < 0.999 { return softwarePart * softwareShare }
        return softwareShare + min(1, max(0, hardware)) * (1 - softwareShare)
    }

    /// One press of a brightness key: a sixteenth of the range, or a
    /// sixty-fourth with ⇧⌥ held, landing on the grid as macOS does.
    public static func step(from value: Double, up: Bool, fine: Bool) -> Double {
        let steps = fine ? 64.0 : 16.0
        let position = value * steps
        let next = up ? (position + 0.0001).rounded(.down) + 1 : (position - 0.0001).rounded(.up) - 1
        return min(1, max(0, next / steps))
    }

    /// What is put back without the user present, after sleep or at
    /// launch: software dimming never returns darker than the floor, even
    /// when "dim to black" let the user go there by hand.
    public static func restorable(_ split: Split) -> Split {
        Split(hardware: split.hardware, software: max(split.software, softwareFloor))
    }

    /// The filled segments of the on-screen display, out of `total`.
    public static func chiclets(_ value: Double, total: Int = 16) -> Int {
        Int((min(1, max(0, value)) * Double(total)).rounded())
    }
}
