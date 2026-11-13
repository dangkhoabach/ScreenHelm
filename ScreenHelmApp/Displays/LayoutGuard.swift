import AppKit
import ScreenHelmCore
import Observation
import os

/// Remembers how each set of displays was arranged and puts it back when
/// macOS changes it by itself, as it likes to after sleep or when a
/// display is plugged in.
@MainActor
@Observable
final class LayoutGuard {
    static let shared = LayoutGuard()

    /// The saved arrangements, by the displays they are for.
    private(set) var layouts: [String: DisplayLayout] = [:]
    /// macOS kept undoing the arrangement, so ScreenHelm stopped putting it back.
    private(set) var gaveUp = false

    @ObservationIgnored private var attempts = DisplayProtection.Attempts()
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }
    private var store: DisplayStore? { AppDatabase.shared.map { DisplayStore(dbQueue: $0.dbQueue) } }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        layouts = (try? store?.load(DisplayLayout.self, from: .layout)) ?? [:]
        DisplayManager.shared.onChange.append { [weak self] _ in self?.check() }
    }

    /// The displays as they are, in the form layouts are compared in.
    func current() -> [DisplayLayout.Placed] {
        let manager = DisplayManager.shared
        return manager.displays.map { display in
            let mode = ModeController.shared.current(of: display.id)
            return DisplayLayout.Placed(
                key: display.key, frame: display.bounds, isMain: display.isMain, rotation: display.rotation,
                mirrorOf: display.mirrorOf.flatMap { manager.display($0)?.key },
                resolution: mode?.resolution, refreshRate: mode?.roundedRate,
                colorProfile: ConfigurationController.customProfile(of: display.id)?.path,
                hdr: DisplayPrivateAPIs.hasHDRModes(display.id) ? DisplayPrivateAPIs.prefersHDR(display.id) : nil
            )
        }
    }

    var currentSignature: String { DisplayLayout.signature(of: DisplayManager.shared.displays.map(\.key)) }
    var savedForCurrentDisplays: DisplayLayout? { layouts[currentSignature] }

    /// Takes the arrangement as it is now as the one to keep.
    func saveCurrent() {
        let layout = DisplayLayout.capture(current())
        guard !layout.items.isEmpty else { return }
        layouts[layout.signature] = layout
        try? store?.save(layout, key: layout.signature, in: .layout)
        attempts.succeeded()
        gaveUp = false
        log.info("layout saved for \(layout.items.count) displays")
    }

    func forgetCurrent() {
        let signature = currentSignature
        layouts[signature] = nil
        try? store?.delete(key: signature, from: .layout)
    }

    /// Puts the saved arrangement back now, whatever protection is set to.
    func applySaved() {
        guard let layout = savedForCurrentDisplays else { return }
        perform(layout.operations(from: current()))
    }

    /// After displays changed: if what is there differs from what was
    /// saved, in a way the user chose to protect, it is put back. A change
    /// still waiting to be kept or undone is left alone.
    private func check() {
        guard settings.displaysProtection.enabled, !DisplaySafety.shared.isSafeMode, !DisplaySafety.shared.hasPendingChange,
              let layout = savedForCurrentDisplays else { return }
        let operations = DisplayProtection.allowed(layout.operations(from: current()), by: settings.displaysProtection)
        guard !operations.isEmpty else {
            attempts.succeeded()
            if gaveUp { gaveUp = false }
            return
        }
        guard attempts.shouldTry(layout.signature, at: Date()) else {
            if !gaveUp {
                gaveUp = true
                log.notice("layout protection stopped: macOS keeps changing it")
            }
            return
        }
        log.info("layout differs: \(operations.count) steps to put it back")
        perform(operations)
    }

    private func perform(_ operations: [DisplayLayout.Operation]) {
        let manager = DisplayManager.shared
        func id(_ key: String) -> CGDirectDisplayID? { manager.display(key: key)?.id }
        // Mirrors, modes and places go in one configuration, in the order given.
        var config: CGDisplayConfigRef?
        var configured = false
        for operation in operations {
            switch operation {
            case .stopMirroring(let key):
                guard let display = id(key) else { continue }
                var single: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&single) == .success else { continue }
                CGConfigureDisplayMirrorOfDisplay(single, display, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(single, .permanently)
            case .rotate(let key, let degrees):
                if let display = id(key) { DisplayPrivateAPIs.setRotation(degrees, of: display) }
            case .setMode(let key, let resolution, let rate):
                guard let display = id(key) else { continue }
                let modes = ModeController.shared.modes(of: display)
                let wantedRate = rate.map(Double.init) ?? ModeController.shared.current(of: display)?.refreshRate ?? 60
                guard let mode = DisplayModes.mode(for: resolution, near: wantedRate, in: modes) else { continue }
                if config == nil { CGBeginDisplayConfiguration(&config) }
                if DisplayPrivateAPIs.configure(config, display: display, modeNumber: mode.number) { configured = true }
            case .mirror(let key, let master):
                guard let display = id(key), let masterID = id(master) else { continue }
                if config == nil { CGBeginDisplayConfiguration(&config) }
                CGConfigureDisplayMirrorOfDisplay(config, display, masterID)
                configured = true
            case .arrange(let origins):
                if config == nil { CGBeginDisplayConfiguration(&config) }
                for (key, origin) in origins {
                    guard let display = id(key) else { continue }
                    CGConfigureDisplayOrigin(config, display, Int32(origin.x), Int32(origin.y))
                    configured = true
                }
            case .setColorProfile(let key, let path):
                if let display = id(key) { ConfigurationController.setProfile(path.map { URL(fileURLWithPath: $0) }, on: display) }
            case .setHDR(let key, let on):
                if let display = id(key) { DisplayPrivateAPIs.setPrefersHDR(on, for: display) }
            }
        }
        if let config {
            if configured { CGCompleteDisplayConfiguration(config, .permanently) } else { CGCancelDisplayConfiguration(config) }
        }
    }

    // MARK: - Arranging by hand

    /// Moves the displays to new places, the main one at the origin, and
    /// keeps the result as the arrangement for this set of displays.
    func arrange(_ origins: [CGDirectDisplayID: CGPoint]) {
        let previous = Dictionary(uniqueKeysWithValues: DisplayManager.shared.displays.map { ($0.id, $0.bounds.origin) })
        func move(_ places: [CGDirectDisplayID: CGPoint]) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            for (display, origin) in places { CGConfigureDisplayOrigin(config, display, Int32(origin.x), Int32(origin.y)) }
            CGCompleteDisplayConfiguration(config, .permanently)
        }
        move(origins)
        DisplaySafety.shared.confirm(
            title: String(localized: "The displays were rearranged", bundle: AppLocale.bundle),
            signature: "arrange:\(currentSignature):\(origins.sorted { $0.key < $1.key }.map { "\($0.key):\(Int($0.value.x)),\(Int($0.value.y))" }.joined(separator: ";"))",
            revert: { move(previous) },
            onKeep: { [weak self] in
                // After macOS has settled where everything went.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    DisplayManager.shared.refresh()
                    if self?.savedForCurrentDisplays != nil { self?.saveCurrent() }
                }
            }
        )
    }

    /// Two displays change places, for a pair of the same model that macOS mixed up.
    func swap(_ first: DisplayInfo, _ second: DisplayInfo) {
        arrange([first.id: second.bounds.origin, second.id: first.bounds.origin])
    }
}
