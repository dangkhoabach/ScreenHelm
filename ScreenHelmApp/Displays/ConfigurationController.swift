import AppKit
@preconcurrency import ColorSync
import ScreenHelmCore
import os

/// The parts of a display's setup that aren't its mode: rotation, which
/// display is the main one, mirroring, HDR, reference presets and the
/// colour profile.
@MainActor
enum ConfigurationController {
    private static let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    // MARK: - Rotation

    /// Rotation is asked of System Settings' own display object, the only
    /// way that works on Apple silicon, and takes effect a moment later.
    static func setRotation(_ degrees: Int, on display: DisplayInfo) {
        let previous = display.rotation
        guard degrees != previous, DisplayPrivateAPIs.setRotation(degrees, of: display.id) else { return }
        let id = display.id
        DisplaySafety.shared.confirm(
            title: "\(DisplayManager.shared.name(of: display)): \(degrees)°",
            signature: "rotation:\(display.key):\(degrees)",
            revert: { DisplayPrivateAPIs.setRotation(previous, of: id) }
        )
    }

    // MARK: - Arrangement

    /// Makes `display` the main one: the menu bar and new windows go there.
    /// The main display is the one at the origin, so every display moves
    /// by the same amount.
    static func setMain(_ display: DisplayInfo) {
        guard !display.isMain else { return }
        let all = DisplayManager.shared.displays
        let previousMain = all.first(where: \.isMain)
        func move(originOf main: DisplayInfo) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            for other in all where other.mirrorOf == nil {
                CGConfigureDisplayOrigin(config, other.id, Int32(other.bounds.minX - main.bounds.minX), Int32(other.bounds.minY - main.bounds.minY))
            }
            CGCompleteDisplayConfiguration(config, .permanently)
        }
        move(originOf: display)
        DisplaySafety.shared.confirm(
            title: String(localized: "\(DisplayManager.shared.name(of: display)) is the main display", bundle: AppLocale.bundle),
            signature: "main:\(display.key):\(all.map(\.key).sorted().joined(separator: ","))",
            revert: { if let previousMain { move(originOf: previousMain) } }
        )
    }

    /// Shows `master` on `display` as well, or stops with nil.
    static func setMirror(of display: DisplayInfo, to master: DisplayInfo?) {
        let previous = display.mirrorOf
        func mirror(_ target: CGDirectDisplayID?) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            CGConfigureDisplayMirrorOfDisplay(config, display.id, target ?? kCGNullDirectDisplay)
            CGCompleteDisplayConfiguration(config, .permanently)
        }
        guard previous != master?.id else { return }
        mirror(master?.id)
        DisplaySafety.shared.confirm(
            title: master.map { String(localized: "\(DisplayManager.shared.name(of: display)) mirrors \(DisplayManager.shared.name(of: $0))", bundle: AppLocale.bundle) }
                ?? String(localized: "\(DisplayManager.shared.name(of: display)) no longer mirrors", bundle: AppLocale.bundle),
            signature: "mirror:\(display.key):\(master?.key ?? "none")",
            revert: { mirror(previous) }
        )
    }

    // MARK: - HDR and presets

    static func setHDR(_ on: Bool, on display: DisplayInfo) {
        guard DisplayPrivateAPIs.hasHDRModes(display.id), DisplayPrivateAPIs.prefersHDR(display.id) != on,
              DisplayPrivateAPIs.setPrefersHDR(on, for: display.id) else { return }
        let id = display.id
        DisplaySafety.shared.confirm(
            title: "\(DisplayManager.shared.name(of: display)): HDR \(on ? "on" : "off")",
            signature: "hdr:\(display.key):\(on)",
            revert: { DisplayPrivateAPIs.setPrefersHDR(!on, for: id) }
        )
    }

    /// The brightness each display had when it last left a preset that lets it change.
    private static var brightnessBeforeFixedPreset: [CGDirectDisplayID: Double] = [:]

    /// Chooses a reference preset of an Apple XDR display. What macOS sets
    /// the brightness to afterwards isn't what it was: a fixed preset reads
    /// as full, and coming back from one gives whatever was last asked for
    /// meanwhile. So the brightness is noted when a preset that lets it
    /// change is left, and set again once such a preset is back.
    static func setPreset(_ index: Int, on display: DisplayInfo, settle: TimeInterval = 1.5) {
        let presets = DisplayPrivateAPIs.presets(of: display.id)
        guard let target = presets.all.first(where: { $0.id == index }), index != presets.active else { return }
        if presets.all.first(where: { $0.id == presets.active })?.isFixedBrightness == false,
           let brightness = DisplayPrivateAPIs.brightness(of: display.id) {
            brightnessBeforeFixedPreset[display.id] = brightness
        }
        guard DisplayPrivateAPIs.setActivePreset(index, of: display.id) else { return }
        BrightnessController.shared.setLocked(target.isFixedBrightness, for: display.id)
        guard !target.isFixedBrightness, let brightness = brightnessBeforeFixedPreset[display.id] else { return }
        let id = display.id
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            DisplayPrivateAPIs.setBrightness(brightness, of: id)
        }
    }

    // MARK: - Colour profile

    struct ColorProfile: Identifiable, Hashable {
        var url: URL
        var name: String
        var id: URL { url }
    }

    /// The display profiles installed on this Mac, by name.
    static func installedProfiles() -> [ColorProfile] {
        var profiles: [ColorProfile] = []
        withUnsafeMutablePointer(to: &profiles) { pointer in
            ColorSyncIterateInstalledProfiles({ info, context in
                guard let info = info as? [String: Any], let context,
                      (info[kColorSyncProfileClass.takeUnretainedValue() as String] as? String) == (kColorSyncSigDisplayClass.takeUnretainedValue() as String),
                      let url = info[kColorSyncProfileURL.takeUnretainedValue() as String] as? URL,
                      let name = info[kColorSyncProfileDescription.takeUnretainedValue() as String] as? String
                else { return true }
                context.assumingMemoryBound(to: [ColorProfile].self).pointee.append(ColorProfile(url: url, name: name))
                return true
            }, nil, pointer, nil)
        }
        return profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func deviceInfo(of display: CGDirectDisplayID) -> [String: Any]? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any]
    }

    /// The profile the user chose for a display, nil while it uses its own.
    static func customProfile(of display: CGDirectDisplayID) -> URL? {
        let custom = deviceInfo(of: display)?[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any]
        return custom?["1"] as? URL
    }

    /// Nil goes back to the display's own profile.
    @discardableResult
    static func setProfile(_ url: URL?, on display: CGDirectDisplayID) -> Bool {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return false }
        let key = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String
        let info: [String: Any] = [key: url ?? (kCFNull as Any)]
        return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, info as CFDictionary)
    }
}

/// System-wide switches that sit with the display controls.
@MainActor
enum SystemToggles {
    static var nightShift: Bool? { DisplayPrivateAPIs.nightShiftIsOn }
    static func setNightShift(_ on: Bool) { DisplayPrivateAPIs.setNightShift(on) }

    static var trueTone: Bool? { DisplayPrivateAPIs.trueToneIsOn }
    static func setTrueTone(_ on: Bool) { DisplayPrivateAPIs.setTrueTone(on) }

    static var darkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Through System Events, which macOS asks the user to allow the first time.
    static func setDarkMode(_ on: Bool) {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }
}
