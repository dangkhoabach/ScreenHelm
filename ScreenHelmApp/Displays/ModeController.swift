import AppKit
import ScreenHelmCore
import Observation
import os

/// A display's modes: listing them, including the ones System Settings
/// hides, and switching between them with a way back.
@MainActor
@Observable
final class ModeController {
    static let shared = ModeController()

    /// Bumped when a mode changed, so views showing the current mode redraw.
    private(set) var revision = 0

    @ObservationIgnored private var cache: [CGDirectDisplayID: [DisplayModeInfo]] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DisplayManager.shared.onChange.append { [weak self] _ in
            self?.cache = [:]
            self?.revision += 1
        }
    }

    /// The window server's own list when it can be read, which also covers
    /// a virtual display made by this app; CoreGraphics' otherwise.
    func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo] {
        if let cached = cache[display] { return cached }
        let modes = DisplayPrivateAPIs.canListModes ? (DisplayPrivateAPIs.modes(of: display) ?? []) : Self.publicModes(of: display)
        cache[display] = modes
        return modes
    }

    func current(of display: CGDirectDisplayID) -> DisplayModeInfo? {
        _ = revision
        let modes = modes(of: display)
        if DisplayPrivateAPIs.canListModes, let number = DisplayPrivateAPIs.currentModeNumber(of: display) {
            return modes.first { $0.number == number }
        }
        guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        return modes.first { $0.number == Int(mode.ioDisplayModeID) }
    }

    private static func publicModes(of display: CGDirectDisplayID) -> [DisplayModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return ((CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []).map { mode in
            DisplayModeInfo(number: Int(mode.ioDisplayModeID), width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                            pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate, isHiDPI: mode.pixelWidth > mode.width,
                            isNative: mode.ioFlags & 0x2000000 != 0)
        }
    }

    /// Writes a mode for this login session, or for good.
    private func write(_ mode: DisplayModeInfo, to display: CGDirectDisplayID, permanently: Bool) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        var configured = DisplayPrivateAPIs.canListModes && DisplayPrivateAPIs.configure(config, display: display, modeNumber: mode.number)
        if !configured {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            if let cgMode = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode])?.first(where: { Int($0.ioDisplayModeID) == mode.number }) {
                configured = CGConfigureDisplayWithDisplayMode(config, display, cgMode, nil) == .success
            }
        }
        guard configured else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let done = CGCompleteDisplayConfiguration(config, permanently ? .permanently : .forSession) == .success
        revision += 1
        return done
    }

    /// Switches a display to `mode`. The change holds for the session only
    /// until it is kept, so a mode that shows nothing is gone after the
    /// countdown, or after a restart at the latest.
    @discardableResult
    func set(_ mode: DisplayModeInfo, on display: DisplayInfo) -> Bool {
        guard let previous = current(of: display.id), previous.number != mode.number else { return false }
        let start = DispatchTime.now().uptimeNanoseconds
        guard write(mode, to: display.id, permanently: false) else {
            log.error("mode \(mode.number) not set on \(display.id)")
            return false
        }
        log.info("mode \(mode.width)x\(mode.height) set in \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, format: .fixed(precision: 0)) ms")
        let id = display.id
        DisplaySafety.shared.confirm(
            title: "\(DisplayManager.shared.name(of: display)): \(mode.resolution.label), \(mode.roundedRate) Hz",
            signature: "mode:\(display.key):\(mode.width)x\(mode.height):\(mode.isHiDPI):\(mode.roundedRate)",
            revert: { [weak self] in _ = self?.write(previous, to: id, permanently: false) },
            onKeep: { [weak self] in _ = self?.write(mode, to: id, permanently: true) }
        )
        return true
    }

    // MARK: - What the interface asks for

    func setResolution(_ resolution: DisplayResolution, on display: DisplayInfo) {
        let modes = modes(of: display.id)
        let rate = current(of: display.id)?.refreshRate ?? 60
        if let mode = DisplayModes.mode(for: resolution, near: rate, in: modes) { set(mode, on: display) }
    }

    func setRefreshRate(_ rate: Int, on display: DisplayInfo) {
        guard let current = current(of: display.id),
              let mode = DisplayModes.mode(like: current, atRate: rate, in: modes(of: display.id)) else { return }
        set(mode, on: display)
    }

    /// Nil on a display without a camera housing.
    func showsNotch(_ display: DisplayInfo) -> Bool? {
        current(of: display.id).flatMap { DisplayModes.showsNotch($0, in: modes(of: display.id)) }
    }

    func toggleNotch(on display: DisplayInfo) {
        guard let current = current(of: display.id), let twin = DisplayModes.notchTwin(of: current, in: modes(of: display.id)) else { return }
        set(twin, on: display)
    }

    func toggleHiDPI(on display: DisplayInfo) {
        guard let current = current(of: display.id), let twin = DisplayModes.hiDPITwin(of: current, in: modes(of: display.id)) else { return }
        set(twin, on: display)
    }

    /// The next size up or down among those of the current shape.
    func step(on display: DisplayInfo, larger: Bool) {
        guard let current = current(of: display.id),
              let next = DisplayModes.neighbor(of: current, in: modes(of: display.id), larger: larger) else { return }
        set(next, on: display)
    }

    func isFavorite(_ resolution: DisplayResolution, on display: DisplayInfo) -> Bool {
        DisplayManager.shared.profile(for: display).favoriteModes.contains(resolution)
    }

    func toggleFavorite(_ resolution: DisplayResolution, on display: DisplayInfo) {
        DisplayManager.shared.updateProfile(of: display) { profile in
            if let index = profile.favoriteModes.firstIndex(of: resolution) {
                profile.favoriteModes.remove(at: index)
            } else {
                profile.favoriteModes.append(resolution)
            }
        }
    }

    /// The favourite at `index`, counted from 0 in the order they were starred.
    func setFavorite(_ index: Int, on display: DisplayInfo) {
        let favorites = DisplayManager.shared.profile(for: display).favoriteModes
        guard favorites.indices.contains(index) else { return }
        setResolution(favorites[index], on: display)
    }
}
