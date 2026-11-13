import Foundation

/// Everything ScreenHelm does to a display's picture through its colour
/// table. They are multiplied into one table, because the display has only
/// one: features writing it separately would undo each other.
public struct PictureAdjustment: Codable, Equatable, Sendable {
    /// Software dimming, 0…1; 1 leaves the picture alone.
    public var brightness: Double
    /// −1…1; 0 is unchanged.
    public var contrast: Double
    /// 0.5…2; 1 is unchanged, lower lifts the mid-tones.
    public var gamma: Double
    public var redGain: Double
    public var greenGain: Double
    public var blueGain: Double
    /// Kelvin, 2700…9300; 6500 is unchanged.
    public var temperature: Double
    public var invert: Bool
    /// Levels per channel, 2…256; 0 keeps them all.
    public var quantization: Int
    /// Above 1 on an XDR display, to push white past its usual limit.
    public var boost: Double

    public init(brightness: Double = 1, contrast: Double = 0, gamma: Double = 1, redGain: Double = 1, greenGain: Double = 1,
                blueGain: Double = 1, temperature: Double = 6500, invert: Bool = false, quantization: Int = 0, boost: Double = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.gamma = gamma
        self.redGain = redGain
        self.greenGain = greenGain
        self.blueGain = blueGain
        self.temperature = temperature
        self.invert = invert
        self.quantization = quantization
        self.boost = boost
    }

    public static let neutral = PictureAdjustment()

    /// Nothing to write: the display keeps the table ColorSync gave it.
    public var isNeutral: Bool { self == .neutral }

    /// The same picture with dimming and boost left out: what "Reset" keeps.
    public var withoutPictureChanges: PictureAdjustment {
        PictureAdjustment(brightness: brightness, boost: boost)
    }
}

public enum GammaTable {
    public struct Channels: Equatable, Sendable {
        public var red: [Float]
        public var green: [Float]
        public var blue: [Float]

        public init(red: [Float], green: [Float], blue: [Float]) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The display's own table with the adjustment applied to each entry.
    /// Values stay in 0…1 unless `boost` is above 1, the one case where the
    /// display is meant to go past white.
    public static func apply(_ adjustment: PictureAdjustment, to base: Channels) -> Channels {
        let white = temperatureGains(adjustment.temperature)
        func channel(_ values: [Float], gain: Double, white: Double) -> [Float] {
            values.map { entry in
                var value = Double(entry)
                if adjustment.invert { value = 1 - value }
                if adjustment.gamma != 1 { value = pow(max(0, value), adjustment.gamma) }
                if adjustment.contrast != 0 {
                    // Around mid-grey, so it neither brightens nor darkens overall.
                    value = (value - 0.5) * (1 + adjustment.contrast) + 0.5
                }
                if adjustment.quantization >= 2 {
                    let levels = Double(adjustment.quantization - 1)
                    value = (value * levels).rounded() / levels
                }
                value = min(1, max(0, value)) * gain * white * adjustment.brightness
                return Float(min(1, max(0, value)) * max(1, adjustment.boost))
            }
        }
        return Channels(red: channel(base.red, gain: adjustment.redGain, white: white.red),
                        green: channel(base.green, gain: adjustment.greenGain, white: white.green),
                        blue: channel(base.blue, gain: adjustment.blueGain, white: white.blue))
    }

    /// The gain per channel that turns 6500 K white into the white of
    /// another temperature, never above 1 so nothing clips: warmer takes
    /// blue away, cooler takes red away. From the usual fit to the
    /// black-body curve (Tanner Helland's), normalised to 6500 K.
    public static func temperatureGains(_ kelvin: Double) -> (red: Double, green: Double, blue: Double) {
        func rgb(_ kelvin: Double) -> (Double, Double, Double) {
            let t = min(40000, max(1000, kelvin)) / 100
            let red = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
            let green = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.07551485)
            let blue = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
            return (min(255, max(0, red)), min(255, max(0, green)), min(255, max(0, blue)))
        }
        let target = rgb(kelvin), reference = rgb(6500)
        let red = target.0 / reference.0, green = target.1 / reference.1, blue = target.2 / reference.2
        let peak = max(red, green, blue)
        return (red / peak, green / peak, blue / peak)
    }

    /// Whether a table read back from the display is the one ScreenHelm
    /// wrote. Another app writing the table shows up as a difference here.
    public static func matches(_ a: Channels, _ b: Channels, tolerance: Float = 0.004) -> Bool {
        func close(_ x: [Float], _ y: [Float]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= tolerance }
        }
        return close(a.red, b.red) && close(a.green, b.green) && close(a.blue, b.blue)
    }
}
