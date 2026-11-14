import CoreGraphics
import Foundation

/// Tells a resolution someone changed from one ScreenHelm set while
/// following it, so that following never sets off more following.
public struct ResolutionWatch: Sendable {
    /// How long a size ScreenHelm set waits to show up before it is forgotten.
    public static let expectationLifetime: TimeInterval = 10

    private var known: [String: CGSize] = [:]
    private var expected: [String: (size: CGSize, at: Date)] = [:]

    public init() {}

    /// A size ScreenHelm is about to give a display, not to be followed.
    public mutating func expect(_ size: CGSize, on key: String, at now: Date) {
        expected[key] = (size, now)
    }

    /// The display whose size changed by itself since the last look, when
    /// exactly one did: several at once is macOS rearranging, not a choice.
    /// A display that has just connected is not a change.
    public mutating func source(in sizes: [String: CGSize], at now: Date) -> String? {
        defer { known = sizes }
        expected = expected.filter { now.timeIntervalSince($0.value.at) < Self.expectationLifetime }
        var changed: [String] = []
        for (key, size) in sizes {
            guard let before = known[key], before != size else { continue }
            if let wanted = expected[key], wanted.size == size {
                expected[key] = nil
                continue
            }
            changed.append(key)
        }
        return changed.count == 1 ? changed[0] : nil
    }
}
