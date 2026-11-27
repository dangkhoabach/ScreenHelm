import AppKit
import ScreenHelmCore
import GRDB
import IOKit

/// The display settings as one file, to carry to another Mac or keep as a backup.
@MainActor
enum DisplaySettingsArchive {
    private struct Archive: Codable {
        var format = "screenhelm-displays"
        var version = 1
        var settings: [String: String]
        var profiles: [String: DisplayProfile]
        var layouts: [String: DisplayLayout]
        var virtualScreens: [String: VirtualScreen]
        var streams: [String: StreamConfig]
    }

    /// The `app_settings` keys that belong to Displays.
    private static let keyPrefixes = ["displays_", "display_", "keep_awake_displays"]
    /// Never taken from a file: letting commands in from outside, and the
    /// risky settings, are turned on by the user on this Mac only.
    private static let keptOnThisMac: Set = ["displays_automation", "displays_http_enabled", "displays_http_port", "displays_advanced"]
    private static var database: AppDatabase? { AppDatabase.shared }

    static func export() throws -> Data {
        guard let database else { throw CocoaError(.fileNoSuchFile) }
        let store = DisplayStore(dbQueue: database.dbQueue)
        let settings = try database.dbQueue.read { db -> [String: String] in
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM app_settings") {
                let key: String = row["key"]
                if keyPrefixes.contains(where: key.hasPrefix) { result[key] = row["value"] }
            }
            return result
        }
        let archive = Archive(settings: settings, profiles: try store.load(DisplayProfile.self, from: .profile),
                              layouts: try store.load(DisplayLayout.self, from: .layout),
                              virtualScreens: try store.load(VirtualScreen.self, from: .virtualScreen),
                              streams: try store.load(StreamConfig.self, from: .stream))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    /// Takes in an export, over what is there. Settings show at once; the
    /// rest is read when ScreenHelm next starts.
    static func `import`(_ data: Data) -> Bool {
        guard let database, let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.format == "screenhelm-displays" else { return false }
        let store = DisplayStore(dbQueue: database.dbQueue)
        do {
            try database.dbQueue.write { db in
                for (key, value) in archive.settings where keyPrefixes.contains(where: key.hasPrefix) && !keptOnThisMac.contains(key) {
                    try AppSettingsStore.set(db, key: key, value: value)
                }
            }
            for (key, value) in archive.profiles { try store.save(value, key: key, in: .profile) }
            for (key, value) in archive.layouts { try store.save(value, key: key, in: .layout) }
            for (key, value) in archive.virtualScreens { try store.save(value, key: key, in: .virtualScreen) }
            for (key, value) in archive.streams where value.isValid { try store.save(value, key: key, in: .stream) }
        } catch {
            return false
        }
        if let loaded = try? SettingsRepository(dbQueue: database.dbQueue).load() { SettingsViewModel.shared.settings = loaded }
        // Until the restart, a change to a display saves its profile: it starts from the imported one.
        DisplayManager.shared.reloadProfiles()
        return true
    }
}

/// A plain-text account of the displays and of what ScreenHelm could and
/// couldn't reach on this Mac, to send along when something doesn't work.
/// Serial numbers are left out.
@MainActor
enum DisplayDiagnostics {
    static func report() -> String {
        var lines: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        lines.append("ScreenHelm \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(OverrideInstaller.chip)")
        lines.append("Calls found: modes \(DisplayPrivateAPIs.canListModes), switch off \(DisplayPrivateAPIs.canDisconnect), DDC \(DisplayPrivateAPIs.canUseDDC), "
            + "virtual displays \(DisplayPrivateAPIs.canMakeVirtualDisplays), night shift \(DisplayPrivateAPIs.nightShiftIsOn != nil), "
            + "true tone \(DisplayPrivateAPIs.trueToneIsOn != nil), light sensor \(DisplayPrivateAPIs.ambientLux() != nil)")
        lines.append("Colour table has no effect on this chip: \(BrightnessController.gammaHasNoEffect)")
        lines.append("DDC ports found: \(DDCDiscovery.externalPorts().count)")
        lines.append("")
        for display in DisplayManager.shared.displays {
            let modes = ModeController.shared.modes(of: display.id)
            let current = ModeController.shared.current(of: display.id)
            lines.append("== \(display.systemName) (\(display.kind.rawValue)\(display.isMain ? ", main" : ""))")
            lines.append("   vendor \(String(format: "%04x", display.identity.vendor)) product \(String(format: "%04x", display.identity.product))"
                + " made \(display.identity.year) week \(display.identity.week)")
            lines.append("   bounds \(Int(display.bounds.minX)),\(Int(display.bounds.minY)) \(Int(display.bounds.width))x\(Int(display.bounds.height))"
                + " rotation \(display.rotation) mirrors \(display.mirrorOf.map(String.init) ?? "nothing")")
            if let current {
                lines.append("   mode \(current.width)x\(current.height) \(current.isHiDPI ? "HiDPI" : "plain") \(current.refreshRate) Hz,"
                    + " \(current.bitsPerSample) bits, \(modes.count) modes in all, \(DisplayModes.resolutions(in: modes).count) sizes")
            }
            if let native = modes.first(where: \.isNative) { lines.append("   panel \(native.pixelWidth)x\(native.pixelHeight)") }
            lines.append("   brightness through \(BrightnessController.shared.method(for: display).rawValue), value \(BrightnessController.shared.value(for: display))"
                + ", DDC \(DDCController.shared.available.contains(display.id) ? "found" : "not found")")
            let presets = DisplayPrivateAPIs.presets(of: display.id)
            if !presets.all.isEmpty { lines.append("   presets \(presets.all.count), active \(presets.active.map(String.init) ?? "?")") }
            lines.append("   HDR modes \(DisplayPrivateAPIs.hasHDRModes(display.id)), can rotate \(DisplayPrivateAPIs.canRotate(display.id))")
            if let edid = DDCController.shared.edid(of: display).flatMap({ EDID($0) }) {
                lines.append("   EDID \(edid.manufacturer) \(String(format: "%04x", edid.productCode)) v\(edid.version), native "
                    + "\(edid.nativeWidth ?? 0)x\(edid.nativeHeight ?? 0), HDR10 \(edid.supportsHDR10), peak \(edid.maxLuminance.map { "\(Int($0)) nits" } ?? "?")")
            }
            for line in connection(of: display) { lines.append("   " + line) }
            lines.append("")
        }
        let off = ConnectionController.shared.disconnected
        if !off.isEmpty { lines.append("Switched off by ScreenHelm: \(off.map(\.name).joined(separator: ", "))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the framebuffer's registry entry says about the link: the
    /// transport, and the timing and colour of the signal in use.
    private static func connection(of display: DisplayInfo) -> [String] {
        guard !display.identity.location.isEmpty else { return [] }
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, display.identity.location)
        guard entry != 0 else { return [] }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        var lines: [String] = []
        if let transport = property("Transport") as? [String: Any] {
            lines.append("link " + transport.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        if let attributes = property("DisplayAttributes") as? [String: Any] {
            if let product = attributes["ProductAttributes"] as? [String: Any] {
                let shown = product.filter { !$0.key.localizedCaseInsensitiveContains("serial") }
                lines.append("product " + shown.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
            if let native = attributes["NativeFormatHorizontalPixels"], let height = attributes["NativeFormatVerticalPixels"] {
                lines.append("native format \(native)x\(height)")
            }
            for key in ["SupportsHDRMode", "SupportsBT2020cYCC", "SupportsVariableRefreshRate", "MaxVerticalRate", "MinVerticalRate"] {
                if let value = attributes[key] { lines.append("\(key) \(value)") }
            }
        }
        return lines
    }
}
