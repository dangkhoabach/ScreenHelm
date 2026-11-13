import AppKit
import ScreenHelmCore
import Observation
import os

/// The virtual screens the user made: kept in the database, made into
/// displays while connected, and gone with ScreenHelm.
@MainActor
@Observable
final class VirtualScreenController {
    static let shared = VirtualScreenController()

    private(set) var screens: [VirtualScreen] = []
    /// The display each connected screen is.
    private(set) var connected: [UUID: CGDirectDisplayID] = [:]

    @ObservationIgnored private var objects: [UUID: NSObject] = [:]
    /// Screens macOS kept after their object was released: a virtual
    /// display whose mode was ever changed lasts until the app ends. They
    /// are switched off instead, and back on rather than made twice.
    @ObservationIgnored private var lingering: [UUID: CGDirectDisplayID] = [:]
    @ObservationIgnored private var headless: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }
    private var store: DisplayStore? { AppDatabase.shared.map { DisplayStore(dbQueue: $0.dbQueue) } }

    private init() {}

    var isAvailable: Bool { DisplayPrivateAPIs.canMakeVirtualDisplays }

    func start() {
        guard !started else { return }
        started = true
        screens = ((try? store?.load(VirtualScreen.self, from: .virtualScreen)) ?? [:]).values.sorted { $0.serial < $1.serial }
        DisplayManager.shared.onChange.append { [weak self] _ in self?.checkHeadless() }
        guard !DisplaySafety.shared.isSafeMode else { return }
        for screen in screens where screen.connectAtLaunch { connect(screen.id) }
        checkHeadless()
    }

    // MARK: - The list

    @discardableResult
    func add(name: String, pixelWidth: Int, pixelHeight: Int, matchedDisplay: String? = nil, connect: Bool = true) -> VirtualScreen {
        let screen = VirtualScreen(name: name, serial: VirtualScreen.nextSerial(after: screens), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                   matchedDisplay: matchedDisplay)
        screens.append(screen)
        save(screen)
        if connect { self.connect(screen.id) }
        return screen
    }

    /// Only a valid screen is kept. One that is connected is made again
    /// when what changed is part of the display itself.
    func update(_ screen: VirtualScreen) {
        guard screen.isValid, let index = screens.firstIndex(where: { $0.id == screen.id }) else { return }
        let old = screens[index]
        screens[index] = screen
        save(screen)
        var before = old, after = screen
        before.connectAtLaunch = true
        after.connectAtLaunch = true
        guard before != after else { return }
        // A changed screen is a new display to macOS: under a serial of its
        // own, it doesn't collide with the old one on its way out, and
        // doesn't inherit the old one's remembered mode.
        let wasConnected = connected[screen.id] != nil
        disconnect(screen.id, forReplacement: true)
        lingering[screen.id] = nil
        screens[index].serial = VirtualScreen.nextSerial(after: screens)
        save(screens[index])
        if wasConnected { connect(screen.id) }
    }

    func delete(_ id: UUID) {
        disconnect(id)
        screens.removeAll { $0.id == id }
        try? store?.delete(key: id.uuidString, from: .virtualScreen)
    }

    private func save(_ screen: VirtualScreen) {
        do { try store?.save(screen, key: screen.id.uuidString, in: .virtualScreen) } catch {
            log.error("virtual screen not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func screen(for display: CGDirectDisplayID) -> VirtualScreen? {
        connected.first { $0.value == display }.flatMap { entry in screens.first { $0.id == entry.key } }
    }

    // MARK: - Connecting

    @discardableResult
    func connect(_ id: UUID) -> Bool {
        guard connected[id] == nil, let screen = screens.first(where: { $0.id == id }), isAvailable else { return false }
        if let display = lingering[id] {
            guard Self.setEnabled(true, display) else { return false }
            lingering[id] = nil
            connected[id] = display
            return true
        }
        let modes = screen.modes.map { DisplayPrivateAPIs.VirtualMode(width: $0.width, height: $0.height, refreshRate: Double($0.refreshRate)) }
        // About 110 pixels to the inch, a desktop monitor's.
        let size = CGSize(width: Double(screen.pixelWidth) / (screen.hiDPI ? 2 : 1) * 0.23, height: Double(screen.pixelHeight) / (screen.hiDPI ? 2 : 1) * 0.23)
        guard let made = DisplayPrivateAPIs.makeVirtualDisplay(name: screen.name, serial: screen.serial,
                                                               maxPixels: (screen.pixelWidth, screen.pixelHeight), sizeInMillimeters: size,
                                                               modes: modes, hiDPI: screen.hiDPI, hdr: screen.hdr) else {
            log.error("virtual screen not made")
            return false
        }
        objects[id] = made.object
        connected[id] = made.id
        DisplaySafety.shared.updatePanicHotKey()
        log.info("virtual screen connected as display \(made.id)")
        return true
    }

    /// `forReplacement` is for a screen about to be made again in another shape.
    func disconnect(_ id: UUID, forReplacement: Bool = false) {
        guard let display = connected.removeValue(forKey: id) else { return }
        objects[id] = nil
        // Released, the display normally goes. If macOS keeps it, it is
        // switched off instead, and remembered to be switched back on
        // rather than made a second time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, DisplayManager.onlineDisplays().contains(display), Self.setEnabled(false, display) else { return }
            if !forReplacement, connected[id] == nil { lingering[id] = display }
        }
        DisplaySafety.shared.updatePanicHotKey()
    }

    func setConnected(_ on: Bool, _ id: UUID) {
        if on { connect(id) } else { disconnect(id) }
        if let index = screens.firstIndex(where: { $0.id == id }), screens[index].connectAtLaunch != on {
            screens[index].connectAtLaunch = on
            save(screens[index])
        }
    }

    /// The panic shortcut's part: every virtual screen gone, to come back at the next launch.
    func disconnectAll() {
        for id in connected.keys { disconnect(id) }
    }

    private static func setEnabled(_ enabled: Bool, _ display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard DisplayPrivateAPIs.configure(config, display: display, enabled: enabled) else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    // MARK: - No monitor

    /// With the setting on and no real display connected, one virtual
    /// screen stands in, and goes again when a real display is back.
    private func checkHeadless() {
        let real = DisplayManager.shared.displays.contains { $0.kind != .virtual }
        if settings.displaysHeadlessScreen, !real, headless == nil, connected.isEmpty {
            let screen = screens.first ?? add(name: "ScreenHelm Screen", pixelWidth: 3840, pixelHeight: 2160, connect: false)
            if connect(screen.id) { headless = screen.id }
        } else if real, let id = headless {
            headless = nil
            disconnect(id)
        }
    }
}
