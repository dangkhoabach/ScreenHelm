import AppKit
import ScreenHelmCore
import os

/// Keeps the other displays as bright as the built-in one, or as the room
/// calls for. Following the built-in display costs nothing: macOS says
/// when its brightness changes. Reading the light sensor is the one thing
/// in Displays that runs on a timer, once a second, and only while chosen.
@MainActor
final class BrightnessSyncController {
    static let shared = BrightnessSyncController()

    private var timer: Timer?
    private var samples: [Double] = []
    private var applied: Double?
    private var started = false
    /// True while this controller sets brightness, so its own changes aren't followed.
    private var applying = false

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DisplayManager.shared.onChange.append { [weak self] _ in self?.sourceChanged() }
        track()
    }

    private func track() {
        withObservationTracking {
            _ = settings.displaysSyncSource
            _ = settings.displaysSyncByNits
        } onChange: {
            Task { @MainActor in BrightnessSyncController.shared.track() }
        }
        let wantsSensor = settings.displaysSyncSource == .ambientLight
        if wantsSensor, timer == nil {
            samples = []
            applied = nil
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { BrightnessSyncController.shared.readSensor() }
            }
            timer?.tolerance = 0.3
        } else if !wantsSensor {
            timer?.invalidate()
            timer = nil
        }
        sourceChanged()
    }

    var isReadingSensor: Bool { timer != nil }

    /// The displays that follow: every one but the source and those left out.
    func targets(excluding source: DisplayInfo?) -> [DisplayInfo] {
        DisplayManager.shared.displays.filter { display in
            display.id != source?.id && display.mirrorOf == nil && !DisplayManager.shared.profile(for: display).syncExcluded
                && !BrightnessController.shared.locked.contains(display.id)
        }
    }

    /// The built-in display's brightness changed, or a display connected.
    func sourceChanged() {
        guard settings.displaysSyncSource == .builtIn, !applying,
              let source = DisplayManager.shared.displays.first(where: { $0.kind == .builtIn }) else { return }
        let value = min(1, BrightnessController.shared.value(for: source))
        let nits = settings.displaysSyncByNits ? BrightnessController.shared.nits(for: source) : nil
        apply(value: value, nits: nits, to: targets(excluding: source))
    }

    private func readSensor() {
        guard let lux = DisplayPrivateAPIs.ambientLux() else { return }
        samples.append(BrightnessSync.value(forLux: lux))
        if samples.count > 5 { samples.removeFirst() }
        guard let value = BrightnessSync.smoothed(samples, last: applied) else { return }
        applied = value
        // The built-in display follows the room by itself.
        apply(value: value, nits: nil, to: targets(excluding: nil).filter { $0.kind != .builtIn })
    }

    private func apply(value: Double, nits: Double?, to displays: [DisplayInfo]) {
        applying = true
        defer { applying = false }
        for display in displays {
            let profile = DisplayManager.shared.profile(for: display)
            let target: Double
            if let nits {
                // A monitor's lowest setting is taken as a tenth of its brightest.
                let peak = Double(profile.peakNits)
                target = BrightnessSync.target(for: BrightnessSync.target(forNits: nits, minimumNits: peak * 0.1, maximumNits: peak),
                                               offset: profile.syncOffset)
            } else {
                target = BrightnessSync.target(for: value, offset: profile.syncOffset)
            }
            if abs(BrightnessController.shared.value(for: display) - target) > 0.005 {
                BrightnessController.shared.set(target, for: display)
            }
        }
    }
}
