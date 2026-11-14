import CoreGraphics
import Foundation

/// How a set of displays was arranged, kept as rules ("B is to the right
/// of A, a third of the way down") rather than coordinates: the rules
/// still say the right thing after a display's resolution has changed.
public struct DisplayLayout: Codable, Equatable, Sendable {
    public enum Edge: String, Codable, Sendable {
        case left, right, above, below
    }

    /// Where a display sits against another one.
    public struct Anchor: Codable, Equatable, Sendable {
        /// The identity key of the display it touches.
        public var to: String
        public var edge: Edge
        /// How far along that edge its own start is, as a fraction of the
        /// other display's side; negative or above 1 when it sticks out.
        public var offset: Double

        public init(to: String, edge: Edge, offset: Double) {
            self.to = to
            self.edge = edge
            self.offset = offset
        }
    }

    public struct Item: Codable, Equatable, Sendable {
        public var key: String
        /// Nil for the main display, which everything else hangs from.
        public var anchor: Anchor?
        public var rotation: Int
        /// The key of the display this one shows a copy of.
        public var mirrorOf: String?
        public var resolution: DisplayResolution?
        public var refreshRate: Int?
        /// The path of a colour profile the user chose.
        public var colorProfile: String?
        public var hdr: Bool?

        public init(key: String, anchor: Anchor? = nil, rotation: Int = 0, mirrorOf: String? = nil, resolution: DisplayResolution? = nil,
                    refreshRate: Int? = nil, colorProfile: String? = nil, hdr: Bool? = nil) {
            self.key = key
            self.anchor = anchor
            self.rotation = rotation
            self.mirrorOf = mirrorOf
            self.resolution = resolution
            self.refreshRate = refreshRate
            self.colorProfile = colorProfile
            self.hdr = hdr
        }
    }

    /// A display as it is now.
    public struct Placed: Equatable, Sendable {
        public var key: String
        /// In CoreGraphics' global coordinates: the main display at the origin, y down.
        public var frame: CGRect
        public var isMain: Bool
        public var rotation: Int
        public var mirrorOf: String?
        public var resolution: DisplayResolution?
        public var refreshRate: Int?
        public var colorProfile: String?
        public var hdr: Bool?

        public init(key: String, frame: CGRect, isMain: Bool, rotation: Int = 0, mirrorOf: String? = nil, resolution: DisplayResolution? = nil,
                    refreshRate: Int? = nil, colorProfile: String? = nil, hdr: Bool? = nil) {
            self.key = key
            self.frame = frame
            self.isMain = isMain
            self.rotation = rotation
            self.mirrorOf = mirrorOf
            self.resolution = resolution
            self.refreshRate = refreshRate
            self.colorProfile = colorProfile
            self.hdr = hdr
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// What tells one set of displays from another: a layout belongs to
    /// the displays it was saved with.
    public static func signature(of keys: [String]) -> String {
        keys.sorted().joined(separator: "|")
    }

    public var signature: String { Self.signature(of: items.map(\.key)) }

    public var mainKey: String? { items.first { $0.anchor == nil && $0.mirrorOf == nil }?.key }

    // MARK: Capture

    /// The rules that describe an arrangement. Each display is anchored to
    /// one it touches that is already placed, starting from the main one.
    public static func capture(_ displays: [Placed]) -> DisplayLayout {
        guard let main = displays.first(where: \.isMain) ?? displays.first else { return DisplayLayout(items: []) }
        var items = [Item(key: main.key, rotation: main.rotation, resolution: main.resolution, refreshRate: main.refreshRate,
                          colorProfile: main.colorProfile, hdr: main.hdr)]
        var placed = [main]
        var waiting = displays.filter { $0.key != main.key && $0.mirrorOf == nil }
        while !waiting.isEmpty {
            // A display that touches one already placed; any, if the arrangement has a gap.
            let index = waiting.firstIndex { candidate in placed.contains { Self.anchor(of: candidate.frame, to: $0.frame, key: $0.key, touching: true) != nil } } ?? 0
            let display = waiting.remove(at: index)
            let anchor = placed.lazy.compactMap { Self.anchor(of: display.frame, to: $0.frame, key: $0.key, touching: true) }.first
                ?? Self.anchor(of: display.frame, to: main.frame, key: main.key, touching: false)
            items.append(Item(key: display.key, anchor: anchor, rotation: display.rotation, resolution: display.resolution,
                              refreshRate: display.refreshRate, colorProfile: display.colorProfile, hdr: display.hdr))
            placed.append(display)
        }
        for mirror in displays where mirror.mirrorOf != nil {
            items.append(Item(key: mirror.key, rotation: mirror.rotation, mirrorOf: mirror.mirrorOf))
        }
        return DisplayLayout(items: items)
    }

    /// The edge of `other` that `frame` sits on. With `touching` false the
    /// nearest edge is taken, for a display that touches nothing.
    private static func anchor(of frame: CGRect, to other: CGRect, key: String, touching: Bool) -> Anchor? {
        let overlapsVertically = frame.minY < other.maxY && frame.maxY > other.minY
        let overlapsHorizontally = frame.minX < other.maxX && frame.maxX > other.minX
        func vertical(_ edge: Edge) -> Anchor { Anchor(to: key, edge: edge, offset: (frame.minY - other.minY) / other.height) }
        func horizontal(_ edge: Edge) -> Anchor { Anchor(to: key, edge: edge, offset: (frame.minX - other.minX) / other.width) }
        if abs(frame.minX - other.maxX) < 1, overlapsVertically { return vertical(.right) }
        if abs(frame.maxX - other.minX) < 1, overlapsVertically { return vertical(.left) }
        if abs(frame.minY - other.maxY) < 1, overlapsHorizontally { return horizontal(.below) }
        if abs(frame.maxY - other.minY) < 1, overlapsHorizontally { return horizontal(.above) }
        guard !touching else { return nil }
        let horizontalGap = max(other.minX - frame.maxX, frame.minX - other.maxX)
        let verticalGap = max(other.minY - frame.maxY, frame.minY - other.maxY)
        if horizontalGap >= verticalGap { return vertical(frame.midX >= other.midX ? .right : .left) }
        return horizontal(frame.midY >= other.midY ? .below : .above)
    }

    // MARK: Resolve

    /// Where each display goes for the sizes they have now, the main one
    /// at the origin. A display whose anchor isn't connected is left out.
    public func origins(for sizes: [String: CGSize]) -> [String: CGPoint] {
        guard let main = mainKey, sizes[main] != nil else { return [:] }
        var origins = [main: CGPoint.zero]
        var remaining = items.filter { $0.anchor != nil && $0.mirrorOf == nil && sizes[$0.key] != nil }
        var progressed = true
        while progressed, !remaining.isEmpty {
            progressed = false
            for item in remaining {
                guard let anchor = item.anchor, let base = origins[anchor.to], let baseSize = sizes[anchor.to], let size = sizes[item.key] else { continue }
                let origin: CGPoint
                switch anchor.edge {
                case .right: origin = CGPoint(x: base.x + baseSize.width, y: base.y + anchor.offset * baseSize.height)
                case .left: origin = CGPoint(x: base.x - size.width, y: base.y + anchor.offset * baseSize.height)
                case .below: origin = CGPoint(x: base.x + anchor.offset * baseSize.width, y: base.y + baseSize.height)
                case .above: origin = CGPoint(x: base.x + anchor.offset * baseSize.width, y: base.y - size.height)
                }
                origins[item.key] = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
                remaining.removeAll { $0.key == item.key }
                progressed = true
            }
        }
        return origins
    }

    // MARK: Compare

    /// One step of putting an arrangement back.
    public enum Operation: Equatable, Sendable {
        case stopMirroring(String)
        case rotate(String, degrees: Int)
        case setMode(String, DisplayResolution, refreshRate: Int?)
        case mirror(String, of: String)
        /// Every display's place at once: they only make sense together.
        case arrange([String: CGPoint])
        case setColorProfile(String, path: String?)
        case setHDR(String, Bool)
    }

    /// What has to change to get from `current` to this layout, in the
    /// order that works: mirrors undone and displays turned first, since
    /// both change the sizes the places depend on; then modes, mirrors and
    /// places. Empty when the displays aren't the ones this layout is for.
    public func operations(from current: [Placed]) -> [Operation] {
        guard Self.signature(of: current.map(\.key)) == signature else { return [] }
        let now = Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })
        var operations: [Operation] = []
        for item in items {
            guard let display = now[item.key] else { continue }
            if display.mirrorOf != nil, display.mirrorOf != item.mirrorOf { operations.append(.stopMirroring(item.key)) }
        }
        for item in items where item.mirrorOf == nil {
            if let display = now[item.key], display.rotation != item.rotation { operations.append(.rotate(item.key, degrees: item.rotation)) }
        }
        for item in items where item.mirrorOf == nil {
            guard let display = now[item.key], let resolution = item.resolution else { continue }
            if display.resolution != resolution || (item.refreshRate != nil && display.refreshRate != item.refreshRate) {
                operations.append(.setMode(item.key, resolution, refreshRate: item.refreshRate))
            }
        }
        for item in items {
            if let master = item.mirrorOf, now[item.key]?.mirrorOf != master { operations.append(.mirror(item.key, of: master)) }
        }
        // Places are worked out for the sizes the displays will have.
        var sizes: [String: CGSize] = [:]
        for item in items where item.mirrorOf == nil {
            guard let display = now[item.key] else { continue }
            var size = item.resolution.map { CGSize(width: $0.width, height: $0.height) } ?? display.frame.size
            let turnsNow = display.rotation % 180 != 0, turnsThen = item.rotation % 180 != 0
            if item.resolution == nil, turnsNow != turnsThen { size = CGSize(width: size.height, height: size.width) }
            sizes[item.key] = size
        }
        let wanted = origins(for: sizes)
        let moved = wanted.contains { key, origin in
            guard let display = now[key] else { return false }
            return abs(display.frame.minX - origin.x) > 1 || abs(display.frame.minY - origin.y) > 1
        }
        if moved || !operations.isEmpty, !wanted.isEmpty { operations.append(.arrange(wanted)) }
        for item in items {
            guard let display = now[item.key] else { continue }
            if display.colorProfile != item.colorProfile { operations.append(.setColorProfile(item.key, path: item.colorProfile)) }
            if let hdr = item.hdr, display.hdr != nil, display.hdr != hdr { operations.append(.setHDR(item.key, hdr)) }
        }
        return operations
    }
}
