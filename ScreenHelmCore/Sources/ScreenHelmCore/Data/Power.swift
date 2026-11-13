import Foundation

/// The internal battery, when the Mac has one.
public struct BatteryLevel: Equatable, Sendable {
    public var percent: Double
    /// Unplugged; charging and full-on-power both count as plugged in.
    public var onBattery: Bool

    public init(percent: Double, onBattery: Bool) {
        self.percent = percent
        self.onBattery = onBattery
    }
}

public enum KeepAwakePolicy {
    /// Unplugged at or below this, a connected display no longer keeps the Mac awake.
    public static let batteryMinimumPercent = 20

    /// Unplugged at or below the limit; a limit of 0 never is.
    public static func batteryIsLow(_ battery: BatteryLevel?, minimumPercent: Int) -> Bool {
        guard minimumPercent > 0, let battery, battery.onBattery else { return false }
        return battery.percent <= Double(minimumPercent)
    }

    /// The first connected display of the user's list, by identity key; nil
    /// lets the Mac sleep, as does a low battery.
    public static func display(connected: Set<String>, keepingAwake: [String], battery: BatteryLevel?,
                               minimumPercent: Int = batteryMinimumPercent) -> String? {
        guard !batteryIsLow(battery, minimumPercent: minimumPercent) else { return nil }
        return keepingAwake.first(where: connected.contains)
    }
}
