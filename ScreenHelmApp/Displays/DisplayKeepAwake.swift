import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import ScreenHelmCore
import os

/// Keeps the Mac and its displays awake while a display from the user's
/// list is connected, unplugged on a low battery excepted. The power
/// assertion goes with the process, so a crash never leaves the Mac awake.
@MainActor
final class DisplayKeepAwake {
    static let shared = DisplayKeepAwake()

    /// The identity key of the display holding the Mac awake.
    private(set) var holdingFor: String?
    private var assertion: IOPMAssertionID?
    private var powerSource: CFRunLoopSource?
    private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        // Added to the main run loop, so the callback runs on the main thread.
        if powerSource == nil, let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { DisplayKeepAwake.shared.update() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        track()
    }

    /// Follows the list and the connected displays.
    private func track() {
        withObservationTracking {
            _ = settings.keepAwakeDisplays
            _ = DisplayManager.shared.displays
            update()
        } onChange: {
            Task { @MainActor in DisplayKeepAwake.shared.track() }
        }
    }

    func update() {
        let wanted = settings.keepAwakeDisplays.isEmpty ? nil : KeepAwakePolicy.display(
            connected: Set(DisplayManager.shared.displays.map(\.key)), keepingAwake: settings.keepAwakeDisplays, battery: Self.battery())
        guard wanted != holdingFor else { return }
        holdingFor = wanted
        if wanted == nil { release() } else { hold() }
    }

    private func hold() {
        guard assertion == nil else { return }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "ScreenHelm: a display is connected" as CFString, &id) == kIOReturnSuccess
        else {
            log.error("power assertion refused")
            return
        }
        assertion = id
        log.info("holding the Mac awake for a connected display")
    }

    private func release() {
        guard let assertion else { return }
        IOPMAssertionRelease(assertion)
        self.assertion = nil
        log.info("released the display's hold on sleep")
    }

    /// The internal battery; nil on a Mac without one.
    static func battery() -> BatteryLevel? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0
            else { continue }
            return BatteryLevel(percent: Double(capacity) / Double(maxCapacity) * 100,
                                onBattery: description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil
    }
}
