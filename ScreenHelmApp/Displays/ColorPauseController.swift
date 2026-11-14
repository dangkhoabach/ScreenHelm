import AppKit
import ScreenHelmCore

/// Switches Night Shift and True Tone off while a display shows HDR, when
/// the user asks for it, and back on when none does or when ScreenHelm quits.
@MainActor
final class ColorPauseController {
    static let shared = ColorPauseController()

    private var pause = ColorPause()
    private var started = false
    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // Turning HDR on or off reconfigures the display.
        DisplayManager.shared.onChange.append { [weak self] _ in self?.update() }
        track()
    }

    private func track() {
        withObservationTracking {
            _ = settings.displaysPauseColorsInHDR
            update()
        } onChange: {
            Task { @MainActor in ColorPauseController.shared.track() }
        }
    }

    func update() {
        let hdrShown = settings.displaysPauseColorsInHDR
            && DisplayManager.shared.displays.contains { DisplayPrivateAPIs.hasHDRModes($0.id) && DisplayPrivateAPIs.prefersHDR($0.id) == true }
        apply(pause.update(hdrShown: hdrShown, nightShiftOn: SystemToggles.nightShift == true, trueToneOn: SystemToggles.trueTone == true))
    }

    /// What was switched off goes back on.
    func restore() {
        apply(pause.update(hdrShown: false, nightShiftOn: false, trueToneOn: false))
    }

    private func apply(_ change: (nightShift: Bool?, trueTone: Bool?)) {
        if let on = change.nightShift { SystemToggles.setNightShift(on) }
        if let on = change.trueTone { SystemToggles.setTrueTone(on) }
    }
}
