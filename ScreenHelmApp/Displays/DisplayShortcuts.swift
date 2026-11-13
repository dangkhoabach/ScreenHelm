import AppKit
import Carbon.HIToolbox
import ScreenHelmCore
import SwiftUI

/// What a display shortcut does. None has keys until the user records
/// some, so no combination another app uses is taken.
enum DisplayAction: String, CaseIterable, Identifiable {
    case brightnessUp, brightnessDown, volumeUp, volumeDown, mute
    case largerResolution, smallerResolution, toggleHiDPI, toggleNotch
    case favorite1, favorite2, favorite3, favorite4, favorite5, favorite6, favorite7, favorite8, favorite9
    case toggleHDR, nextPreset, toggleXDR, invertColors
    case rotate0, rotate90, rotate180, rotate270, makeMain, toggleMirror, switchOff, switchAllOn, applyLayout
    case pictureInPicture, stopPictures
    case nightShift, trueTone, darkMode

    var id: Self { self }

    enum Section: CaseIterable {
        case brightness, volume, modes, picture, arrangement, pictures, system
    }

    var section: Section {
        switch self {
        case .brightnessUp, .brightnessDown: .brightness
        case .volumeUp, .volumeDown, .mute: .volume
        case .largerResolution, .smallerResolution, .toggleHiDPI, .toggleNotch,
             .favorite1, .favorite2, .favorite3, .favorite4, .favorite5, .favorite6, .favorite7, .favorite8, .favorite9: .modes
        case .toggleHDR, .nextPreset, .toggleXDR, .invertColors: .picture
        case .rotate0, .rotate90, .rotate180, .rotate270, .makeMain, .toggleMirror, .switchOff, .switchAllOn, .applyLayout: .arrangement
        case .pictureInPicture, .stopPictures: .pictures
        case .nightShift, .trueTone, .darkMode: .system
        }
    }

    var favoriteIndex: Int? {
        guard rawValue.hasPrefix("favorite"), let number = Int(rawValue.dropFirst(8)) else { return nil }
        return number - 1
    }

    var title: String {
        let bundle = AppLocale.bundle
        if let index = favoriteIndex { return String(localized: "Favorite Resolution \(index + 1)", bundle: bundle) }
        switch self {
        case .brightnessUp: return String(localized: "Increase Brightness", bundle: bundle)
        case .brightnessDown: return String(localized: "Decrease Brightness", bundle: bundle)
        case .volumeUp: return String(localized: "Increase Display Volume", bundle: bundle)
        case .volumeDown: return String(localized: "Decrease Display Volume", bundle: bundle)
        case .mute: return String(localized: "Mute or Unmute the Display", bundle: bundle)
        case .largerResolution: return String(localized: "More Space", bundle: bundle)
        case .smallerResolution: return String(localized: "Larger Text", bundle: bundle)
        case .toggleHiDPI: return String(localized: "Turn HiDPI On or Off", bundle: bundle)
        case .toggleNotch: return String(localized: "Show or Hide the Camera Housing Area", bundle: bundle)
        case .toggleHDR: return String(localized: "Turn HDR On or Off", bundle: bundle)
        case .nextPreset: return String(localized: "Next Reference Preset", bundle: bundle)
        case .toggleXDR: return String(localized: "Turn XDR Brightness On or Off", bundle: bundle)
        case .invertColors: return String(localized: "Invert Colors", bundle: bundle)
        case .switchOff: return String(localized: "Switch the Display Off", bundle: bundle)
        case .switchAllOn: return String(localized: "Switch Every Display Back On", bundle: bundle)
        case .applyLayout: return String(localized: "Put the Kept Arrangement Back", bundle: bundle)
        case .pictureInPicture: return String(localized: "Show This Display in a Floating Window", bundle: bundle)
        case .stopPictures: return String(localized: "Close Every Picture", bundle: bundle)
        case .rotate0: return String(localized: "Rotate to 0°", bundle: bundle)
        case .rotate90: return String(localized: "Rotate to 90°", bundle: bundle)
        case .rotate180: return String(localized: "Rotate to 180°", bundle: bundle)
        case .rotate270: return String(localized: "Rotate to 270°", bundle: bundle)
        case .makeMain: return String(localized: "Make This the Main Display", bundle: bundle)
        case .toggleMirror: return String(localized: "Mirror or Stop Mirroring", bundle: bundle)
        case .nightShift: return String(localized: "Turn Night Shift On or Off", bundle: bundle)
        case .trueTone: return String(localized: "Turn True Tone On or Off", bundle: bundle)
        case .darkMode: return String(localized: "Switch Between Light and Dark", bundle: bundle)
        default: return rawValue
        }
    }
}

extension DisplayAction.Section {
    var title: LocalizedStringKey {
        switch self {
        case .brightness: "Brightness"
        case .volume: "Volume"
        case .modes: "Resolution"
        case .picture: "Picture"
        case .arrangement: "Arrangement"
        case .pictures: "Picture in Picture"
        case .system: "System"
        }
    }
}

/// What the display shortcuts do, on the display the pointer is on; the
/// keys themselves are `HotKeyManager`'s.
@MainActor
enum DisplayShortcuts {
    static func title(forKey key: String) -> String {
        if key == DisplaySafety.panicKey { return String(localized: "Undo Everything on Displays", bundle: AppLocale.bundle) }
        if key == HotKeyManager.panelKey { return String(localized: "Open the menu bar panel", bundle: AppLocale.bundle) }
        return DisplayAction(rawValue: key)?.title ?? key
    }

    static func perform(key: String) {
        guard let action = DisplayAction(rawValue: key), let display = DisplayManager.shared.displayUnderPointer() else { return }
        perform(action, on: display)
    }

    static func perform(_ action: DisplayAction, on display: DisplayInfo) {
        if let index = action.favoriteIndex { return ModeController.shared.setFavorite(index, on: display) }
        switch action {
        case .brightnessUp, .brightnessDown:
            BrightnessController.shared.step(display, up: action == .brightnessUp)
            showBrightnessOSD(for: display)
        case .volumeUp: changeVolume(of: display, key: .soundUp, fine: false)
        case .volumeDown: changeVolume(of: display, key: .soundDown, fine: false)
        case .mute: changeVolume(of: display, key: .mute, fine: false)
        case .largerResolution: ModeController.shared.step(on: display, larger: true)
        case .smallerResolution: ModeController.shared.step(on: display, larger: false)
        case .toggleHiDPI: ModeController.shared.toggleHiDPI(on: display)
        case .toggleNotch: ModeController.shared.toggleNotch(on: display)
        case .toggleHDR:
            if let on = DisplayPrivateAPIs.prefersHDR(display.id) { ConfigurationController.setHDR(!on, on: display) }
        case .nextPreset:
            let presets = DisplayPrivateAPIs.presets(of: display.id)
            guard let index = presets.all.firstIndex(where: { $0.id == presets.active }), !presets.all.isEmpty else { return }
            ConfigurationController.setPreset(presets.all[(index + 1) % presets.all.count].id, on: display)
        case .toggleXDR:
            let on = XDRController.shared.isEnabled(for: display)
            XDRController.shared.setEnabled(!on, for: display)
            // Off takes the slider back to 100%; on leaves it there for the keys to go past.
            if on, BrightnessController.shared.value(for: display) > 1 { BrightnessController.shared.set(1, for: display) }
        case .invertColors:
            var picture = DisplayManager.shared.profile(for: display).picture
            picture.invert.toggle()
            BrightnessController.shared.setPicture(picture, for: display)
        case .switchOff: ConnectionController.shared.disconnect(display)
        case .switchAllOn: ConnectionController.shared.reconnectAll()
        case .applyLayout: LayoutGuard.shared.applySaved()
        case .pictureInPicture:
            // The picture of this display, made the first time and toggled after.
            let streams = StreamController.shared
            let existing = streams.configs.first { $0.source == .display(display.key) && $0.target == .floatingWindow }
            streams.toggle((existing ?? streams.add(source: .display(display.key), name: DisplayManager.shared.name(of: display))).id)
        case .stopPictures: StreamController.shared.stopAll()
        case .rotate0: rotate(display, to: 0)
        case .rotate90: rotate(display, to: 90)
        case .rotate180: rotate(display, to: 180)
        case .rotate270: rotate(display, to: 270)
        case .makeMain: ConfigurationController.setMain(display)
        case .toggleMirror:
            let main = DisplayManager.shared.displays.first(where: \.isMain)
            ConfigurationController.setMirror(of: display, to: display.mirrorOf == nil && main?.id != display.id ? main : nil)
        case .nightShift: if let on = SystemToggles.nightShift { SystemToggles.setNightShift(!on) }
        case .trueTone: if let on = SystemToggles.trueTone { SystemToggles.setTrueTone(!on) }
        case .darkMode: SystemToggles.setDarkMode(!SystemToggles.darkMode)
        default: break
        }
    }

    /// The built-in display is only turned with the risky settings shown.
    private static func rotate(_ display: DisplayInfo, to degrees: Int) {
        guard display.kind != .builtIn || SettingsViewModel.shared.settings.displaysAdvanced else { return }
        ConfigurationController.setRotation(degrees, on: display)
    }

    static func showBrightnessOSD(for display: DisplayInfo) {
        let value = BrightnessController.shared.value(for: display)
        let nits = BrightnessController.shared.nits(for: display).map { "\(Int($0.rounded())) nits" }
        let detail = nits ?? "\(Int((min(1, value) * 100).rounded()))%"
        DisplayOSD.shared.show(.brightness, value: value / BrightnessController.shared.maximum(for: display), detail: detail, on: display)
    }

    /// Volume and mute of a monitor's speakers, over DDC.
    static func changeVolume(of display: DisplayInfo, key: MediaKeyTap.Key, fine: Bool) {
        let ddc = DDCController.shared
        guard ddc.isAvailable(display) else { return }
        if key == .mute {
            let muted = ddc.value(.mute, on: display) == DDCPacket.muteOn
            ddc.set(muted ? DDCPacket.muteOff : DDCPacket.muteOn, for: .mute, on: display)
            DisplayOSD.shared.show(muted ? .volume : .muted, value: muted ? (ddc.fraction(.volume, on: display) ?? 0) : 0, on: display)
            return
        }
        let next = BrightnessCurve.step(from: ddc.fraction(.volume, on: display) ?? 0.5, up: key == .soundUp, fine: fine)
        ddc.setFraction(next, for: .volume, on: display)
        // A monitor left muted stays silent whatever its volume says.
        if ddc.value(.mute, on: display) == DDCPacket.muteOn { ddc.set(DDCPacket.muteOff, for: .mute, on: display) }
        DisplayOSD.shared.show(next == 0 ? .muted : .volume, value: next, on: display)
    }
}

/// Starts the parts that look after the displays, in the order they depend on each other.
@MainActor
enum Displays {
    private(set) static var isStarted = false

    static func start() {
        guard !isStarted else { return }
        isStarted = true
        SettingsViewModel.shared.loadIfNeeded()
        let safety = DisplaySafety.shared
        safety.beginLaunch()
        // The test runner ends a test host while it may still be settling;
        // that says nothing about the settings the next start applies.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { safety.guardLaunch() }
        DisplayManager.shared.start()
        ModeController.shared.start()
        GammaController.shared.start()
        DimOverlay.shared.start()
        DDCController.shared.start()
        BrightnessController.shared.start()
        XDRController.shared.start()
        BrightnessSyncController.shared.start()
        ConnectionController.shared.start()
        LayoutGuard.shared.start()
        VirtualScreenController.shared.start()
        StreamController.shared.start()
        AutomationServer.shared.start()
        MediaKeyTap.shared.start()
        DisplayKeepAwake.shared.start()

        safety.activityChecks.append {
            GammaController.shared.isActive || DimOverlay.shared.isActive || XDRController.shared.isActive
                || !ConnectionController.shared.disconnected.isEmpty || !VirtualScreenController.shared.connected.isEmpty
                || !StreamController.shared.running.isEmpty
        }
        safety.panicActions.append {
            StreamController.shared.stopAll()
            VirtualScreenController.shared.disconnectAll()
            ConnectionController.shared.reconnectAll()
            XDRController.shared.stopAll()
            BrightnessController.shared.resetSoftware()
            GammaController.shared.resetAll()
        }
        safety.updatePanicHotKey()
    }
}
