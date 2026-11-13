import Foundation
import GRDB

/// What ScreenHelm remembers about one display, found again by its
/// `DisplayIdentity` key.
public struct DisplayProfile: Codable, Equatable, Sendable {
    /// The user's name for it; nil shows the display's own.
    public var name: String?
    public var brightnessMethod: BrightnessMethod
    /// The backlight and software dimming on one slider.
    public var combinedBrightness: Bool
    /// Software dimming may go all the way to black.
    public var dimToBlack: Bool
    /// The slider's last value, 0…1 (above 1 with XDR boost); nil until the user moves it.
    public var brightness: Double?
    public var picture: PictureAdjustment
    public var favoriteModes: [DisplayResolution]
    /// What the menu bar panel shows for this display.
    public var panelControls: Set<DisplayPanelControl>
    public var ddc: DDCSettings
    /// The user's names for the monitor's inputs, by DDC value.
    public var inputNames: [UInt16: String]
    /// The last values written over DDC, since reading them back is slow and unreliable.
    public var ddcValues: [UInt8: UInt16]
    public var xdrBoost: Bool
    /// The brightest XDR boost goes, in nits.
    public var xdrMaxNits: Int
    /// Added to the brightness this display gets when it follows another.
    public var syncOffset: Double
    /// The most light this monitor gives, in nits, for matching by nits.
    public var peakNits: Int
    /// Left out of brightness syncing.
    public var syncExcluded: Bool
    /// The display's own dithering is switched off while ScreenHelm runs.
    public var ditheringOff: Bool
    /// Monitor settings of the user's own making, by VCP code.
    public var customControls: [CustomDDCControl]

    public init(name: String? = nil, brightnessMethod: BrightnessMethod = .automatic, combinedBrightness: Bool = true,
                dimToBlack: Bool = false, brightness: Double? = nil, picture: PictureAdjustment = .neutral,
                favoriteModes: [DisplayResolution] = [], panelControls: Set<DisplayPanelControl> = DisplayPanelControl.defaults,
                ddc: DDCSettings = DDCSettings(), inputNames: [UInt16: String] = [:], ddcValues: [UInt8: UInt16] = [:],
                xdrBoost: Bool = false, xdrMaxNits: Int = 1200, syncOffset: Double = 0, peakNits: Int = 300, syncExcluded: Bool = false,
                ditheringOff: Bool = false, customControls: [CustomDDCControl] = []) {
        self.name = name
        self.brightnessMethod = brightnessMethod
        self.combinedBrightness = combinedBrightness
        self.dimToBlack = dimToBlack
        self.brightness = brightness
        self.picture = picture
        self.favoriteModes = favoriteModes
        self.panelControls = panelControls
        self.ddc = ddc
        self.inputNames = inputNames
        self.ddcValues = ddcValues
        self.xdrBoost = xdrBoost
        self.xdrMaxNits = xdrMaxNits
        self.syncOffset = syncOffset
        self.peakNits = peakNits
        self.syncExcluded = syncExcluded
        self.ditheringOff = ditheringOff
        self.customControls = customControls
    }

    /// Fields added by later versions take their defaults when an older
    /// profile is read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplayProfile()
        name = try c.decodeIfPresent(String.self, forKey: .name)
        brightnessMethod = try c.decodeIfPresent(BrightnessMethod.self, forKey: .brightnessMethod) ?? d.brightnessMethod
        combinedBrightness = try c.decodeIfPresent(Bool.self, forKey: .combinedBrightness) ?? d.combinedBrightness
        dimToBlack = try c.decodeIfPresent(Bool.self, forKey: .dimToBlack) ?? d.dimToBlack
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
        picture = try c.decodeIfPresent(PictureAdjustment.self, forKey: .picture) ?? d.picture
        favoriteModes = try c.decodeIfPresent([DisplayResolution].self, forKey: .favoriteModes) ?? d.favoriteModes
        panelControls = try c.decodeIfPresent(Set<DisplayPanelControl>.self, forKey: .panelControls) ?? d.panelControls
        ddc = try c.decodeIfPresent(DDCSettings.self, forKey: .ddc) ?? d.ddc
        inputNames = try c.decodeIfPresent([UInt16: String].self, forKey: .inputNames) ?? d.inputNames
        ddcValues = try c.decodeIfPresent([UInt8: UInt16].self, forKey: .ddcValues) ?? d.ddcValues
        xdrBoost = try c.decodeIfPresent(Bool.self, forKey: .xdrBoost) ?? d.xdrBoost
        xdrMaxNits = try c.decodeIfPresent(Int.self, forKey: .xdrMaxNits) ?? d.xdrMaxNits
        syncOffset = try c.decodeIfPresent(Double.self, forKey: .syncOffset) ?? d.syncOffset
        peakNits = try c.decodeIfPresent(Int.self, forKey: .peakNits) ?? d.peakNits
        syncExcluded = try c.decodeIfPresent(Bool.self, forKey: .syncExcluded) ?? d.syncExcluded
        ditheringOff = try c.decodeIfPresent(Bool.self, forKey: .ditheringOff) ?? d.ditheringOff
        customControls = try c.decodeIfPresent([CustomDDCControl].self, forKey: .customControls) ?? d.customControls
    }
}

/// A monitor setting ScreenHelm doesn't know by name: its VCP code and the
/// largest value it takes.
public struct CustomDDCControl: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var code: UInt8
    public var maximum: UInt16
    /// The value last written.
    public var value: UInt16

    public init(id: UUID = UUID(), name: String, code: UInt8, maximum: UInt16 = 100, value: UInt16 = 0) {
        self.id = id
        self.name = name
        self.code = code
        self.maximum = maximum
        self.value = value
    }

    /// "0x72" or "114".
    public static func code(from text: String) -> UInt8? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("0x") ? UInt8(trimmed.dropFirst(2), radix: 16) : UInt8(trimmed)
    }
}

/// The controls a display can have in the menu bar panel.
public enum DisplayPanelControl: String, Codable, Sendable, CaseIterable {
    case brightness, volume, resolution, refreshRate, input, preset

    public static let defaults: Set<DisplayPanelControl> = [.brightness, .volume, .resolution]
}

/// How one monitor is talked to over DDC; the defaults suit most.
public struct DDCSettings: Codable, Equatable, Sendable {
    /// Off for a monitor that flickers or drops its signal when DDC is sent.
    public var enabled: Bool
    /// Milliseconds before each write, and between a request and its reply.
    public var writeDelay: Int
    public var readDelay: Int
    /// A write is sent this many times; monitors miss some.
    public var writeCount: Int
    public var readRetries: Int
    /// Takes a reply whose checksum is wrong, for monitors that compute it differently.
    public var ignoreReadChecksum: Bool
    /// Uses LG's own code to switch inputs.
    public var lgInputCode: Bool

    public init(enabled: Bool = true, writeDelay: Int = 10, readDelay: Int = 50, writeCount: Int = 2, readRetries: Int = 4,
                ignoreReadChecksum: Bool = false, lgInputCode: Bool = false) {
        self.enabled = enabled
        self.writeDelay = writeDelay
        self.readDelay = readDelay
        self.writeCount = writeCount
        self.readRetries = readRetries
        self.ignoreReadChecksum = ignoreReadChecksum
        self.lgInputCode = lgInputCode
    }
}

/// A change that outlives ScreenHelm, written down before it is made so it
/// can be undone after a crash.
public struct DisplayJournalEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A display switched off without unplugging it; `detail` is its display ID.
        case disconnected
        /// A file put in /Library/Displays; `detail` is its path, `backup` what was there.
        case overrideFile
        /// A value written to a monitor over DDC; `detail` is "code:previous".
        case ddcValue
    }

    public var id: Int64?
    public var kind: Kind
    /// The display's identity key.
    public var display: String
    public var detail: String
    public var backup: Data?
    public var date: Date

    public init(id: Int64? = nil, kind: Kind, display: String, detail: String, backup: Data? = nil, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.display = display
        self.detail = detail
        self.backup = backup
        self.date = date
    }
}

/// The Displays tables: one row per display, layout, virtual screen or
/// stream, each a JSON document under its key.
public struct DisplayStore: Sendable {
    public enum Table: String, Sendable {
        case profile = "display_profile"
        case layout = "display_layout"
        case virtualScreen = "virtual_screen"
        case stream = "stream_config"
    }

    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func load<T: Decodable>(_ type: T.Type, from table: Table) throws -> [String: T] {
        let rows = try dbQueue.read { db in try Row.fetchAll(db, sql: "SELECT key, json FROM \(table.rawValue)") }
        var result: [String: T] = [:]
        for row in rows {
            let key: String = row["key"], json: String = row["json"]
            // A row a later version wrote in a shape this one can't read is skipped, not fatal.
            if let value = try? JSONDecoder().decode(T.self, from: Data(json.utf8)) { result[key] = value }
        }
        return result
    }

    public func save<T: Encodable>(_ value: T, key: String, in table: Table) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO \(table.rawValue) (key, json) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET json = excluded.json
                """, arguments: [key, json])
        }
    }

    public func delete(key: String, from table: Table) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM \(table.rawValue) WHERE key = ?", arguments: [key]) }
    }

    // MARK: Journal

    @discardableResult
    public func record(_ entry: DisplayJournalEntry) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO display_journal (kind, display, detail, backup, date) VALUES (?, ?, ?, ?, ?)",
                           arguments: [entry.kind.rawValue, entry.display, entry.detail, entry.backup, entry.date.timeIntervalSince1970])
            return db.lastInsertedRowID
        }
    }

    public func journal(_ kind: DisplayJournalEntry.Kind? = nil) throws -> [DisplayJournalEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, kind, display, detail, backup, date FROM display_journal ORDER BY id")
            return rows.compactMap { row in
                guard let entryKind = DisplayJournalEntry.Kind(rawValue: row["kind"]), kind == nil || kind == entryKind else { return nil }
                return DisplayJournalEntry(id: row["id"], kind: entryKind, display: row["display"], detail: row["detail"],
                                           backup: row["backup"], date: Date(timeIntervalSince1970: row["date"]))
            }
        }
    }

    public func clearJournal(id: Int64) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM display_journal WHERE id = ?", arguments: [id]) }
    }
}
