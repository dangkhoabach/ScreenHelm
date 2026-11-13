import Foundation

/// The parts of an arrangement ScreenHelm puts back when macOS changes them
/// by itself, as it does after sleep or when a display is plugged in.
public struct DisplayProtectionSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var position: Bool
    public var resolution: Bool
    public var rotation: Bool
    public var mirroring: Bool
    public var colorProfile: Bool
    public var hdr: Bool

    public init(enabled: Bool = false, position: Bool = true, resolution: Bool = true, rotation: Bool = true, mirroring: Bool = true,
                colorProfile: Bool = false, hdr: Bool = false) {
        self.enabled = enabled
        self.position = position
        self.resolution = resolution
        self.rotation = rotation
        self.mirroring = mirroring
        self.colorProfile = colorProfile
        self.hdr = hdr
    }

    public static func decode(_ text: String) -> DisplayProtectionSettings {
        (try? JSONDecoder().decode(DisplayProtectionSettings.self, from: Data(text.utf8))) ?? DisplayProtectionSettings()
    }

    public var encoded: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

public enum DisplayProtection {
    /// How often an arrangement is put back for one change before giving
    /// up: macOS may keep undoing it, and the two must not go on forever.
    public static let maximumAttempts = 3

    /// The steps the user's choices allow.
    public static func allowed(_ operations: [DisplayLayout.Operation], by settings: DisplayProtectionSettings) -> [DisplayLayout.Operation] {
        guard settings.enabled else { return [] }
        return operations.filter { operation in
            switch operation {
            case .stopMirroring, .mirror: settings.mirroring
            case .rotate: settings.rotation
            case .setMode: settings.resolution
            case .arrange: settings.position
            case .setColorProfile: settings.colorProfile
            case .setHDR: settings.hdr
            }
        }
    }

    /// Counts the tries for one arrangement. It starts again once the
    /// displays are as they should be, or after a quiet minute.
    public struct Attempts: Equatable, Sendable {
        private var signature = ""
        private var count = 0
        private var last = Date.distantPast

        public init() {}

        /// False once this arrangement has been tried too often in a row.
        public mutating func shouldTry(_ signature: String, at now: Date) -> Bool {
            if signature != self.signature || now.timeIntervalSince(last) > 60 {
                self.signature = signature
                count = 0
            }
            last = now
            guard count < DisplayProtection.maximumAttempts else { return false }
            count += 1
            return true
        }

        public mutating func succeeded() {
            count = 0
        }

        public var gaveUp: Bool { count >= DisplayProtection.maximumAttempts }
    }
}
