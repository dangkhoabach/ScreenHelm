import Foundation

/// Pushing an XDR display past its usual white: the panel can show up to
/// 1600 nits for HDR, and the colour table or an overlay can ask for part
/// of that for everything on screen.
public enum XDRBoost {
    /// The brightest an Apple XDR panel goes, briefly; it holds about 1000.
    public static let panelPeakNits = 1600.0
    /// With boost on, the brightness slider runs to this instead of 1.
    public static let sliderMaximum = 2.0

    /// How much white is multiplied by for a slider value. Up to 1 the
    /// slider is the backlight alone; from 1 to `sliderMaximum` it goes on
    /// to the user's limit, or to what the display has room for now if
    /// that is less. `sdrNits` is what white shows at with the backlight
    /// at full; `headroom` is how far above it the display says it can go.
    public static func factor(slider: Double, sdrNits: Double, limitNits: Double, headroom: Double?) -> Double {
        guard slider > 1, sdrNits > 0 else { return 1 }
        var top = min(limitNits, panelPeakNits) / sdrNits
        if let headroom { top = min(top, headroom) }
        guard top > 1 else { return 1 }
        let share = min(1, (slider - 1) / (sliderMaximum - 1))
        return 1 + share * (top - 1)
    }

    /// What white shows at with a factor applied.
    public static func nits(factor: Double, sdrNits: Double) -> Double {
        min(panelPeakNits, sdrNits * max(1, factor))
    }

    public enum StopReason: Equatable, Sendable {
        case lowBattery, heat, noHeadroom
    }

    /// Why boost must be off now, if it must: it costs power and heat, and
    /// it can't work once macOS has taken the display's extra range away.
    public static func stopReason(battery: BatteryLevel?, minimumPercent: Int, heatIsSerious: Bool, headroom: Double?) -> StopReason? {
        if KeepAwakePolicy.batteryIsLow(battery, minimumPercent: minimumPercent) { return .lowBattery }
        if heatIsSerious { return .heat }
        if let headroom, headroom < 1.05 { return .noHeadroom }
        return nil
    }
}
