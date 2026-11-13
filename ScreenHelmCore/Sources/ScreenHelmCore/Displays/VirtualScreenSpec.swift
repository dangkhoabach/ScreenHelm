import Foundation

/// A display that exists only in software: something to mirror to, to
/// share, to stream, or to give a Mac with no monitor a desktop.
public struct VirtualScreen: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// What macOS tells virtual displays apart by, and remembers their
    /// last mode under; each screen keeps its own for good.
    public var serial: UInt32
    /// The largest size it can be set to, in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Offers sharp modes at half the pixels in points.
    public var hiDPI: Bool
    public var refreshRates: [Int]
    public var hdr: Bool
    /// Made again each time ScreenHelm starts.
    public var connectAtLaunch: Bool
    /// The identity key of a real display whose shape this screen was made to match.
    public var matchedDisplay: String?

    public init(id: UUID = UUID(), name: String, serial: UInt32, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool = true,
                refreshRates: [Int] = [60], hdr: Bool = false, connectAtLaunch: Bool = true, matchedDisplay: String? = nil) {
        self.id = id
        self.name = name
        self.serial = serial
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hiDPI = hiDPI
        self.refreshRates = refreshRates
        self.hdr = hdr
        self.connectAtLaunch = connectAtLaunch
        self.matchedDisplay = matchedDisplay
    }

    public struct Mode: Equatable, Hashable, Sendable {
        /// In points for a HiDPI screen, in pixels otherwise.
        public var width: Int
        public var height: Int
        public var refreshRate: Int
    }

    public static let minimumSide = 480
    public static let maximumSide = 16384
    /// macOS lists about this many modes for a screen with sharp ones before it starts dropping some.
    public static let maximumModes = 100
    public static let allowedRefreshRates = [24, 30, 50, 60, 75, 90, 100, 120, 144, 165, 240]

    /// Named, of a size macOS takes, and at rates it offers.
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (Self.minimumSide...Self.maximumSide).contains(pixelWidth) && (Self.minimumSide...Self.maximumSide).contains(pixelHeight)
            && !refreshRates.isEmpty && refreshRates.allSatisfy(Self.allowedRefreshRates.contains)
    }

    /// The sizes the screen offers: its full size and steps down from it
    /// in the same shape, each at every refresh rate. A HiDPI screen's
    /// are in points, half its pixels at most.
    public var modes: [Mode] {
        let fullWidth = hiDPI ? pixelWidth / 2 : pixelWidth, fullHeight = hiDPI ? pixelHeight / 2 : pixelHeight
        let rates = refreshRates.sorted(by: >)
        var sizes: [(Int, Int)] = []
        for share in [1.0, 0.9, 0.8, 0.75, 2.0 / 3, 0.6, 0.5, 0.4, 1.0 / 3, 0.25] {
            // Even numbers: odd sizes make blurry or refused modes.
            let width = Int((Double(fullWidth) * share / 2).rounded()) * 2, height = Int((Double(fullHeight) * share / 2).rounded()) * 2
            guard width >= 320, height >= 200, !sizes.contains(where: { $0 == (width, height) }) else { continue }
            sizes.append((width, height))
        }
        let all = sizes.flatMap { size in rates.map { Mode(width: size.0, height: size.1, refreshRate: $0) } }
        return Array(all.prefix(Self.maximumModes))
    }

    /// A serial none of the others has; macOS ignores a second screen with a serial already in use.
    public static func nextSerial(after existing: [VirtualScreen]) -> UInt32 {
        (existing.map(\.serial).max() ?? 0x1000) + 1
    }

    public struct Template: Identifiable, Sendable {
        public var id: String
        public var pixelWidth: Int
        public var pixelHeight: Int
    }

    /// Common shapes to start from; `id` is how each is listed.
    public static let templates: [Template] = [
        Template(id: "16:9 · 1920 × 1080 HiDPI", pixelWidth: 3840, pixelHeight: 2160),
        Template(id: "16:9 · 2560 × 1440 HiDPI", pixelWidth: 5120, pixelHeight: 2880),
        Template(id: "16:10 · 1920 × 1200 HiDPI", pixelWidth: 3840, pixelHeight: 2400),
        Template(id: "21:9 · 2560 × 1080 HiDPI", pixelWidth: 5120, pixelHeight: 2160),
        Template(id: "32:9 · 3840 × 1080 HiDPI", pixelWidth: 7680, pixelHeight: 2160),
        Template(id: "4:3 · 1366 × 1024 HiDPI", pixelWidth: 2732, pixelHeight: 2048),
        Template(id: "9:16 · 1080 × 1920 HiDPI", pixelWidth: 2160, pixelHeight: 3840),
    ]

    /// A screen of `longSide` pixels in the shape of a real display, to
    /// mirror that display without bars.
    public static func matching(width: Int, height: Int, longSide: Int) -> (pixelWidth: Int, pixelHeight: Int) {
        guard width > 0, height > 0 else { return (longSide, longSide) }
        let scale = Double(longSide) / Double(max(width, height))
        return (Int((Double(width) * scale / 2).rounded()) * 2, Int((Double(height) * scale / 2).rounded()) * 2)
    }
}
