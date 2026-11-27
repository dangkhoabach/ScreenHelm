import AppKit
import ScreenHelmCore
import Observation
import os

/// One brightness slider per display, whatever is behind it: the backlight
/// of an Apple display, a monitor's own setting over DDC, the colour
/// table, or a dark overlay.
@MainActor
@Observable
final class BrightnessController {
    static let shared = BrightnessController()

    /// The slider's value for each display, 0…1.
    private(set) var values: [CGDirectDisplayID: Double] = [:]
    /// Displays on a reference preset that holds their brightness in place.
    private(set) var locked: Set<CGDirectDisplayID> = []
    /// What the built-in panel puts out, in nits. Its framebuffer reports a
    /// new level some 20 ms after the backlight is set, so this is read a
    /// moment after each change, not when the figure is drawn.
    private(set) var panelNits: Double?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var observed: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var saveWork: [CGDirectDisplayID: DispatchWorkItem] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DisplayManager.shared.onChange.append { [weak self] woke in self?.displaysChanged(woke: woke) }
        displaysChanged(woke: false)
    }

    // MARK: - Which way

    /// The colour table has no visible effect on these Macs (a macOS bug
    /// that reports success), so they dim with the overlay.
    static let gammaHasNoEffect: Bool = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let chip = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return chip.contains("M5 Pro") || chip.contains("M5 Max")
    }()

    /// The way a display's brightness is changed, never `.automatic`.
    func method(for display: DisplayInfo) -> BrightnessMethod {
        let chosen = DisplayManager.shared.profile(for: display).brightnessMethod
        let ddc = DDCController.shared.isAvailable(display)
        switch chosen {
        case .apple where display.hasAppleBrightness: return .apple
        case .ddc where ddc: return .ddc
        case .gamma where !display.kind.isSoftwareOnly && !Self.gammaHasNoEffect: return .gamma
        case .overlay: return .overlay
        default: break
        }
        if display.kind.isSoftwareOnly { return .overlay }
        if display.hasAppleBrightness { return .apple }
        if ddc { return .ddc }
        return softwareMethod(for: display)
    }

    /// The ways a display can be set to, for the picker.
    func availableMethods(for display: DisplayInfo) -> [BrightnessMethod] {
        var methods: [BrightnessMethod] = [.automatic]
        if display.hasAppleBrightness { methods.append(.apple) }
        if DDCController.shared.isAvailable(display) { methods.append(.ddc) }
        if !display.kind.isSoftwareOnly && !Self.gammaHasNoEffect { methods.append(.gamma) }
        methods.append(.overlay)
        return methods
    }

    /// How the software part is done: the colour table, or the overlay
    /// where the table can't be used. A custom colour profile together
    /// with a changed table can black the screen out on some Macs.
    func softwareMethod(for display: DisplayInfo) -> BrightnessMethod {
        if display.kind.isSoftwareOnly || Self.gammaHasNoEffect || settings.displaysPreferOverlay { return .overlay }
        return ConfigurationController.customProfile(of: display.id) == nil ? .gamma : .overlay
    }

    /// Where the software part of `method` goes: a monitor's dims the way
    /// software does on this display, the others as chosen.
    private func softwareTarget(for display: DisplayInfo, _ method: BrightnessMethod) -> BrightnessMethod {
        method == .ddc ? softwareMethod(for: display) : method
    }

    private func usesCombined(_ display: DisplayInfo, _ method: BrightnessMethod) -> Bool {
        // An Apple backlight goes down to black by itself; a monitor's lowest is still bright.
        method == .ddc && DisplayManager.shared.profile(for: display).combinedBrightness
    }

    // MARK: - Reading and setting

    func value(for display: DisplayInfo) -> Double {
        values[display.id] ?? current(of: display)
    }

    private func current(of display: DisplayInfo) -> Double {
        let method = method(for: display)
        let profile = DisplayManager.shared.profile(for: display)
        let software = softwareTarget(for: display, method) == .overlay
            ? DimOverlay.shared.dimming(for: display.id) : GammaController.shared.dimming(for: display.id)
        switch method {
        case .apple:
            return DisplayPrivateAPIs.brightness(of: display.id) ?? 1
        case .ddc:
            let hardware = DDCController.shared.fraction(.brightness, on: display) ?? 1
            return BrightnessCurve.value(hardware: hardware, software: software, hasHardware: true,
                                         combined: profile.combinedBrightness, allowBlack: profile.dimToBlack)
        default:
            return BrightnessCurve.value(hardware: 1, software: software, hasHardware: false, combined: true, allowBlack: profile.dimToBlack)
        }
    }

    func setLocked(_ isLocked: Bool, for display: CGDirectDisplayID) {
        if isLocked { locked.insert(display) } else { locked.remove(display) }
    }

    /// The slider's upper end: 1, or more while XDR boost is on for the display.
    func maximum(for display: DisplayInfo) -> Double {
        XDRController.shared.isEnabled(for: display) ? XDRBoost.sliderMaximum : 1
    }

    /// XDR boost switched itself off: the slider comes back to 100%.
    func boostEnded() {
        for (display, value) in values where value > 1 { values[display] = 1 }
        readPanelNitsSoon()
    }

    func set(_ value: Double, for display: DisplayInfo) {
        guard !locked.contains(display.id) else { return }
        let boosted = min(maximum(for: display), max(0, value))
        // Above 1 the backlight stays at full and the rest is XDR boost.
        let value = min(1, boosted)
        let method = method(for: display)
        let profile = DisplayManager.shared.profile(for: display)
        switch method {
        case .apple:
            DisplayPrivateAPIs.setBrightness(value, of: display.id)
        case .ddc:
            let split = BrightnessCurve.split(value, hasHardware: true, combined: profile.combinedBrightness, allowBlack: profile.dimToBlack)
            DDCController.shared.setFraction(split.hardware, for: .brightness, on: display)
            applySoftware(split.software, to: display, method: softwareTarget(for: display, method))
        default:
            let split = BrightnessCurve.split(value, hasHardware: false, combined: true, allowBlack: profile.dimToBlack)
            applySoftware(split.software, to: display, method: method)
        }
        XDRController.shared.setSlider(boosted, for: display)
        // Boost refused (a low battery, a hot Mac) leaves the slider at 100%.
        values[display.id] = boosted > 1 && !XDRController.shared.isBoosting(display.id) ? 1 : boosted
        if display.kind == .builtIn {
            BrightnessSyncController.shared.sourceChanged()
            readPanelNitsSoon()
        }
        DisplaySafety.shared.updatePanicHotKey()
        // Saved once the dragging stops, not on every step of it.
        // XDR boost isn't saved: it is never on by itself after a restart.
        saveWork[display.id]?.cancel()
        let id = display.id
        let work = DispatchWorkItem {
            guard let current = DisplayManager.shared.display(id) else { return }
            DisplayManager.shared.updateProfile(of: current) { $0.brightness = value }
        }
        saveWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The slider value at which a display gives `share` of its light, as
    /// brightness sync by nits needs: a monitor's backlight is linear in
    /// light, the slider isn't where software dimming takes part of it.
    func value(forLightShare share: Double, on display: DisplayInfo) -> Double {
        let profile = DisplayManager.shared.profile(for: display)
        switch method(for: display) {
        case .apple: return share
        case .ddc:
            return BrightnessCurve.value(hardware: share, software: 1, hasHardware: true,
                                         combined: profile.combinedBrightness, allowBlack: profile.dimToBlack)
        default:
            return BrightnessCurve.value(hardware: 1, software: share, hasHardware: false, combined: true, allowBlack: profile.dimToBlack)
        }
    }

    /// One press of a brightness key or shortcut.
    func step(_ display: DisplayInfo, up: Bool, fine: Bool = false) {
        let current = value(for: display)
        // Past 100%, the same sixteen steps cover the boosted part.
        let next = current >= 1 && (up || current > 1)
            ? 1 + BrightnessCurve.step(from: current - 1, up: up, fine: fine)
            : BrightnessCurve.step(from: current, up: up, fine: fine)
        set(next, for: display)
    }

    private func applySoftware(_ factor: Double, to display: DisplayInfo, method: BrightnessMethod) {
        if method == .overlay {
            GammaController.shared.setDimming(1, for: display.id)
            DimOverlay.shared.setDimming(factor, for: display.id)
        } else {
            DimOverlay.shared.setDimming(1, for: display.id)
            GammaController.shared.setDimming(factor, for: display.id)
        }
    }

    /// The picture settings of a display, applied and remembered.
    func setPicture(_ picture: PictureAdjustment, for display: DisplayInfo) {
        DisplayManager.shared.updateProfile(of: display) { $0.picture = picture.withoutBrightnessAndBoost }
        GammaController.shared.setPicture(softwareMethod(for: display) == .gamma ? picture : .neutral, for: display.id)
        DisplaySafety.shared.updatePanicHotKey()
    }

    /// Software dimming given up for a display, as after changing its method.
    func clearSoftware(for display: DisplayInfo) {
        GammaController.shared.setDimming(1, for: display.id)
        DimOverlay.shared.setDimming(1, for: display.id)
        values[display.id] = nil
    }

    /// Everything software dims, dropped: the panic shortcut's part.
    func resetSoftware() {
        DimOverlay.shared.removeAll()
        for display in DisplayManager.shared.displays { GammaController.shared.setDimming(1, for: display.id) }
        values = [:]
    }

    /// What the built-in display puts out, when it can be read.
    func nits(for display: DisplayInfo) -> Double? {
        // While boosted the framebuffer reports the backlight's peak, not white.
        if let boosted = XDRController.shared.nits(for: display) { return boosted }
        return display.kind == .builtIn && !XDRController.shared.isActive ? panelNits : nil
    }

    /// Reads the built-in panel's nits once it has taken the new level; a
    /// changed figure goes on to the displays following it by nits and to
    /// the on-screen display, if that shows the panel's brightness.
    private func readPanelNitsSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let nits = DisplayPrivateAPIs.builtInNits()
            guard nits != panelNits else { return }
            panelNits = nits
            guard let builtIn = DisplayManager.shared.displays.first(where: { $0.kind == .builtIn }) else { return }
            BrightnessSyncController.shared.sourceChanged()
            if DisplayOSD.shared.brightnessDisplay == builtIn.id { DisplayShortcuts.showBrightnessOSD(for: builtIn) }
        }
    }

    // MARK: - Displays coming and going

    private func displaysChanged(woke: Bool) {
        let displays = DisplayManager.shared.displays
        if woke { for display in displays { liftAfterSleep(display) } }
        let ids = Set(displays.map(\.id))
        for gone in observed.subtracting(ids) {
            DisplayPrivateAPIs.stopObservingBrightness(of: gone, observer: Unmanaged.passUnretained(self).toOpaque())
            observed.remove(gone)
        }
        values = values.filter { ids.contains($0.key) }
        locked = locked.intersection(ids)
        for display in displays where !observed.contains(display.id) {
            observed.insert(display.id)
            if display.kind == .builtIn { readPanelNitsSoon() }
            if display.hasAppleBrightness {
                observe(display.id)
                // Asking for the presets is slow the first time; not in the way of launch.
                let id = display.id
                DispatchQueue.main.async { [weak self] in
                    let presets = DisplayPrivateAPIs.presets(of: id)
                    self?.setLocked(presets.all.first { $0.id == presets.active }?.isFixedBrightness == true, for: id)
                }
            }
            restore(display)
        }
    }

    /// macOS says when an Apple display's brightness changed, by the keys,
    /// the sensor or System Settings; the slider follows.
    private func observe(_ display: CGDirectDisplayID) {
        let registered = DisplayPrivateAPIs.observeBrightness(of: display, observer: Unmanaged.passUnretained(self).toOpaque()) { _, _, _, _, _ in
            DispatchQueue.main.async { BrightnessController.shared.appleBrightnessChanged() }
        }
        if !registered { log.info("no brightness notifications for display \(display)") }
    }

    private func appleBrightnessChanged() {
        readPanelNitsSoon()
        for display in DisplayManager.shared.displays where method(for: display) == .apple {
            guard let value = DisplayPrivateAPIs.brightness(of: display.id) else { continue }
            let shown = values[display.id] ?? -1
            // While boosted the backlight sits at full; the slider is above it.
            if shown > 1, value > 0.999 { continue }
            if abs(shown - value) > 0.001 {
                values[display.id] = value
                if shown > 1 { XDRController.shared.stop(display.id) }
                if display.kind == .builtIn { BrightnessSyncController.shared.sourceChanged() }
            }
        }
    }

    /// Software dimming below the floor, as "dim to black" allows by hand,
    /// isn't what a display wakes up to.
    private func liftAfterSleep(_ display: DisplayInfo) {
        let method = method(for: display)
        guard method != .apple else { return }
        let target = softwareTarget(for: display, method)
        let software = target == .overlay ? DimOverlay.shared.dimming(for: display.id) : GammaController.shared.dimming(for: display.id)
        guard software < BrightnessCurve.softwareFloor else { return }
        applySoftware(BrightnessCurve.softwareFloor, to: display, method: target)
        values[display.id] = nil
    }

    /// A display that connects gets its software dimming back, if the user
    /// wants settings remembered. The backlight and the monitor's own
    /// brightness are left as they are: they kept their value themselves.
    private func restore(_ display: DisplayInfo) {
        guard settings.displaysRemember, !DisplaySafety.shared.isSafeMode else { return }
        let profile = DisplayManager.shared.profile(for: display)
        // Dithering comes back on with every connection; off is put back.
        if profile.ditheringOff { DisplayPrivateAPIs.setDithering(false, at: display.identity.location) }
        if !profile.picture.isNeutral, softwareMethod(for: display) == .gamma {
            GammaController.shared.setPicture(profile.picture, for: display.id)
            DisplaySafety.shared.updatePanicHotKey()
        }
        guard let saved = profile.brightness else { return }
        let method = method(for: display)
        guard method != .apple else { return }
        let combined = usesCombined(display, method)
        let split = BrightnessCurve.restorable(BrightnessCurve.split(saved, hasHardware: method == .ddc, combined: combined,
                                                                     allowBlack: profile.dimToBlack))
        guard split.software < 0.999 else { return }
        applySoftware(split.software, to: display, method: softwareTarget(for: display, method))
        DisplaySafety.shared.updatePanicHotKey()
    }
}
