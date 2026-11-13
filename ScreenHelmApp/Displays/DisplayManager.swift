import AppKit
import ScreenHelmCore
import IOKit
import Observation
import os

/// A connected display as the window and the panel show it.
struct DisplayInfo: Identifiable, Equatable {
    var id: CGDirectDisplayID
    /// ScreenHelm's own key for it, the same after a restart; see `DisplayIdentity`.
    var key: String
    var identity: DisplayIdentity
    var kind: DisplayKind
    /// The display's own name, before any the user gave it.
    var systemName: String
    var isMain: Bool
    /// In the global coordinates CoreGraphics uses, origin at the main display's top left.
    var bounds: CGRect
    var rotation: Int
    /// The display this one shows a copy of.
    var mirrorOf: CGDirectDisplayID?
    var hasAppleBrightness: Bool

    var symbolName: String {
        switch kind {
        case .builtIn: "laptopcomputer"
        case .external: "display"
        case .tv: "tv"
        case .airPlay: "airplayvideo"
        case .sidecar: "ipad.landscape"
        case .virtual: "rectangle.dashed"
        }
    }
}

/// The displays that are connected, kept current from macOS's own
/// notifications, and what ScreenHelm remembers about each. Nothing here
/// polls: a display changing is always announced.
@MainActor
@Observable
final class DisplayManager {
    static let shared = DisplayManager()

    private(set) var displays: [DisplayInfo] = []
    private(set) var profiles: [String: DisplayProfile] = [:]

    /// Called after the list was rebuilt because displays changed; `woke`
    /// when the Mac has just woken, which resets what software had applied.
    @ObservationIgnored var onChange: [(_ woke: Bool) -> Void] = []

    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingRefresh: DispatchWorkItem?
    @ObservationIgnored private var wokeSinceRefresh = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var store: DisplayStore? { AppDatabase.shared.map { DisplayStore(dbQueue: $0.dbQueue) } }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        profiles = (try? store?.load(DisplayProfile.self, from: .profile)) ?? [:]
        refresh()
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // The "begin" half of each change says nothing yet.
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayManager.shared.scheduleRefresh(after: 0.2) }
        }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Displays come back one after another for a moment after waking.
                DisplayManager.shared.wokeSinceRefresh = true
                DisplayManager.shared.scheduleRefresh(after: 1.5)
            }
        }
    }

    /// One rebuild for a burst of notifications: macOS sends several for a
    /// single cable plugged in.
    private func scheduleRefresh(after delay: TimeInterval) {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let woke = wokeSinceRefresh
            wokeSinceRefresh = false
            refresh()
            for listener in onChange { listener(woke) }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func refresh() {
        DisplayPrivateAPIs.displaysChanged()
        let ids = Self.onlineDisplays()
        let main = CGMainDisplayID()
        let details = ids.map { Self.describe($0) }
        let keys = DisplayIdentity.keys(for: details.map(\.identity))
        let updated = zip(ids, zip(details, keys)).map { id, pair in
            let (detail, key) = pair
            let mirror = CGDisplayMirrorsDisplay(id)
            return DisplayInfo(id: id, key: key, identity: detail.identity, kind: detail.kind, systemName: detail.name, isMain: id == main,
                               bounds: CGDisplayBounds(id), rotation: Int(CGDisplayRotation(id).rounded()),
                               mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror,
                               hasAppleBrightness: DisplayPrivateAPIs.hasAppleBrightness(id))
        }
        if updated != displays {
            displays = updated
            log.info("displays: \(updated.map { "\($0.id) \($0.kind.rawValue)" }.joined(separator: ", "), privacy: .public)")
        }
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func describe(_ id: CGDirectDisplayID) -> (identity: DisplayIdentity, kind: DisplayKind, name: String) {
        let info = DisplayPrivateAPIs.info(of: id)
        func flag(_ key: String) -> Bool { (info[key] as? NSNumber)?.boolValue ?? false }
        let location = info["IODisplayLocation"] as? String ?? ""
        let identity = DisplayIdentity(
            vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
            alphanumericSerial: alphanumericSerial(at: location),
            week: (info["DisplayWeekManufacture"] as? NSNumber)?.intValue ?? 0,
            year: (info["DisplayYearManufacture"] as? NSNumber)?.intValue ?? 0,
            location: location
        )
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        let names = info["DisplayProductName"] as? [String: String]
        let name = screen?.localizedName ?? names?["en_US"] ?? names?.values.first ?? "Display \(id)"

        let kind: DisplayKind
        if CGDisplayIsBuiltin(id) != 0 {
            kind = .builtIn
        } else if flag("kCGDisplayIsAirPlay") || DisplayPrivateAPIs.panelFlag("isAirPlayDisplay", of: id) {
            kind = .airPlay
        } else if DisplayPrivateAPIs.panelFlag("isSidecarDisplay", of: id) {
            kind = .sidecar
        } else if flag("kCGDisplayIsVirtualDevice") {
            kind = .virtual
        } else {
            kind = DisplayPrivateAPIs.panelFlag("isTV", of: id) ? .tv : .external
        }
        return (identity, kind, name)
    }

    /// The serial as text, which the framebuffer's registry entry has for
    /// displays whose numeric serial is zero or shared.
    private static func alphanumericSerial(at location: String) -> String {
        guard !location.isEmpty else { return "" }
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, location)
        guard entry != 0 else { return "" }
        defer { IOObjectRelease(entry) }
        let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        return (attributes?["ProductAttributes"] as? [String: Any])?["AlphanumericSerialNumber"] as? String ?? ""
    }

    // MARK: - Lookups

    func display(_ id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    func display(key: String) -> DisplayInfo? {
        displays.first { $0.key == key }
    }

    /// The display the pointer is on.
    func displayUnderPointer() -> DisplayInfo? {
        guard let location = CGEvent(source: nil)?.location else { return displays.first(where: \.isMain) }
        return displays.first { $0.mirrorOf == nil && $0.bounds.contains(location) } ?? displays.first(where: \.isMain)
    }

    /// The name shown everywhere: the user's, or the display's own.
    func name(of display: DisplayInfo) -> String {
        profile(for: display).name ?? display.systemName
    }

    // MARK: - Profiles

    func profile(for display: DisplayInfo) -> DisplayProfile {
        DisplayIdentity.storedKey(for: display.key, in: Set(profiles.keys)).flatMap { profiles[$0] } ?? DisplayProfile()
    }

    /// Changes what is remembered for a display and saves it.
    func updateProfile(of display: DisplayInfo, _ change: (inout DisplayProfile) -> Void) {
        var profile = profile(for: display)
        change(&profile)
        guard profiles[display.key] != profile else { return }
        profiles[display.key] = profile
        do { try store?.save(profile, key: display.key, in: .profile) } catch {
            log.error("profile not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
