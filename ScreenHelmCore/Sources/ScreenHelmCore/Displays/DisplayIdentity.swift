import Foundation

/// What a display is, which decides how its brightness is controlled by default.
public enum DisplayKind: String, Codable, Sendable, CaseIterable {
    /// `virtual` is any display with no hardware of its own behind it,
    /// which is also how a DisplayLink dock's screens appear.
    case builtIn, external, tv, airPlay, sidecar, virtual

    /// Displays macOS draws to through software, with no backlight or DDC
    /// to reach: only an overlay dims them.
    public var isSoftwareOnly: Bool {
        switch self {
        case .airPlay, .sidecar, .virtual: true
        case .builtIn, .external, .tv: false
        }
    }
}

/// What tells one display from another across restarts. The display ID
/// macOS hands out changes after a restart, and its UUID is swapped between
/// two identical monitors, so ScreenHelm keeps its own key built from what
/// the display says about itself.
public struct DisplayIdentity: Codable, Hashable, Sendable {
    public var vendor: UInt32
    public var product: UInt32
    public var serial: UInt32
    /// The serial as text, when the display has one; many have only this.
    public var alphanumericSerial: String
    public var week: Int
    public var year: Int
    /// The port, as the registry path of the framebuffer.
    public var location: String

    public init(vendor: UInt32, product: UInt32, serial: UInt32, alphanumericSerial: String = "",
                week: Int = 0, year: Int = 0, location: String = "") {
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.alphanumericSerial = alphanumericSerial
        self.week = week
        self.year = year
        self.location = location
    }

    private var modelKey: String {
        String(format: "%04x-%04x-%08x", vendor, product, serial)
    }

    private var datedKey: String {
        "\(modelKey)-\(alphanumericSerial)-\(week)-\(year)"
    }

    /// One key per display, in the same order. A display is told by vendor,
    /// model and serial; two that match there also use the text serial and
    /// the manufacture date; two that still match use the port they are on.
    /// The port comes last because it is the only part that changes when a
    /// cable moves.
    public static func keys(for displays: [DisplayIdentity]) -> [String] {
        let modelCounts = Dictionary(grouping: displays, by: \.modelKey).mapValues(\.count)
        let datedCounts = Dictionary(grouping: displays, by: \.datedKey).mapValues(\.count)
        return displays.map { display in
            if modelCounts[display.modelKey] == 1 { return display.modelKey }
            if datedCounts[display.datedKey] == 1 { return display.datedKey }
            return "\(display.datedKey)@\(display.location)"
        }
    }

    /// The key a display has when no other like it is connected.
    public var key: String { modelKey }

    /// The profile to use for `key` among the stored ones: its own, or the
    /// model's when the display was last seen alone and now has a twin.
    public static func storedKey(for key: String, in stored: Set<String>) -> String? {
        if stored.contains(key) { return key }
        let model = String(key.prefix(18))
        return stored.contains(model) ? model : nil
    }
}
