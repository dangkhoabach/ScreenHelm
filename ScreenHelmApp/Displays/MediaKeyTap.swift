import AppKit
import CoreAudio
import ScreenHelmCore
import os

/// Lets the keyboard's brightness and volume keys reach displays macOS
/// doesn't control with them.
///
/// The keys arrive as system-defined events, which only an event tap sees
/// before macOS acts on them. The tap exists only while the setting is on
/// and there is a display to control, and it swallows only the presses
/// ScreenHelm handles: everything else goes on to macOS untouched.
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()

    /// Key codes of the system-defined "aux control button" events.
    enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var started = false
    private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DisplayManager.shared.onChange.append { [weak self] _ in self?.update() }
        track()
    }

    /// Follows the setting, the permission and the displays.
    private func track() {
        withObservationTracking {
            _ = settings.displaysKeysEnabled
            _ = Permissions.shared.accessibility
            _ = DDCController.shared.available
            update()
        } onChange: {
            Task { @MainActor in MediaKeyTap.shared.track() }
        }
    }

    var isInstalled: Bool { tap != nil }

    /// A display whose brightness isn't macOS's to change with the keys.
    private var hasDisplayToControl: Bool {
        DisplayManager.shared.displays.contains { BrightnessController.shared.method(for: $0) != .apple }
    }

    private func update() {
        let wanted = settings.displaysKeysEnabled && Permissions.shared.accessibility && hasDisplayToControl
        if wanted, tap == nil { install() } else if !wanted, tap != nil { remove() }
    }

    private func install() {
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: mediaKeyTapCallback, userInfo: nil) else {
            log.error("media key tap not created")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        self.source = source
        log.info("media key tap installed")
    }

    private func remove() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        log.info("media key tap removed")
    }

    /// Turns the tap back on after macOS switched it off for being slow.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// True when ScreenHelm took the press, key-up included, so macOS sees neither half.
    func pressed(_ key: Key, isDown: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        let fine = flags.contains(.shift) && flags.contains(.option)
        switch key {
        case .brightnessUp, .brightnessDown:
            let displays = brightnessTargets(control: flags.contains(.control))
            guard !displays.isEmpty else { return false }
            if isDown {
                for display in displays {
                    BrightnessController.shared.step(display, up: key == .brightnessUp, fine: fine)
                    DisplayShortcuts.showBrightnessOSD(for: display)
                }
            }
            return true
        case .soundUp, .soundDown, .mute:
            guard let display = volumeTarget() else { return false }
            if isDown { DisplayShortcuts.changeVolume(of: display, key: key, fine: fine) }
            return true
        }
    }

    /// The displays a brightness key changes. Those macOS controls itself
    /// are left to it: for them the press isn't taken.
    func brightnessTargets(control: Bool) -> [DisplayInfo] {
        let manager = DisplayManager.shared
        let own = manager.displays.filter { $0.mirrorOf == nil && BrightnessController.shared.method(for: $0) != .apple }
        var chosen: [DisplayInfo]
        switch settings.displaysKeyTarget {
        case .pointer: chosen = manager.displayUnderPointer().map { [$0] } ?? []
        case .focusedWindow: chosen = Self.displayOfFrontWindow().map { [$0] } ?? manager.displayUnderPointer().map { [$0] } ?? []
        case .all: return own
        // The display picked, or the one under the pointer while it isn't connected.
        case .fixed: chosen = (manager.display(key: settings.displaysKeyFixedDisplay) ?? manager.displayUnderPointer()).map { [$0] } ?? []
        }
        // ⌃ with the key sends it to the other display, as macOS does for Apple's.
        if control, let first = chosen.first, !own.contains(where: { $0.id == first.id }) { return Array(own.prefix(1)) }
        return chosen.filter { display in own.contains { $0.id == display.id } }
    }

    private static func displayOfFrontWindow() -> DisplayInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication, let window = AX.visibleWindows(of: app.processIdentifier).first,
              let frame = AX.frame(of: window) else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return DisplayManager.shared.displays.first { $0.mirrorOf == nil && $0.bounds.contains(center) }
    }

    /// The display whose speakers are playing, when its volume is set over
    /// DDC: sound that goes out over HDMI or DisplayPort has no volume of
    /// its own in macOS. Matched by name, the only thing the two share.
    func volumeTarget() -> DisplayInfo? {
        guard let name = Self.defaultOutputName() else { return nil }
        return DisplayManager.shared.displays.first {
            DDCController.shared.isAvailable($0) && DDCController.shared.supports(.volume, on: $0)
                && ($0.systemName == name || name.contains($0.systemName) || $0.systemName.contains(name))
        }
    }

    private static func defaultOutputName() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        // Only outputs carried by the display cable.
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// Runs on the main run loop, where the tap's source was added. The key
/// is read from the event here, since the event itself can't cross into
/// the main actor.
private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeyTap.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    // Subtype 8 is the "aux control button" kind: the media keys.
    guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data = nsEvent.data1
    let flags = nsEvent.modifierFlags
    guard let key = MediaKeyTap.Key(rawValue: (data & 0xFFFF0000) >> 16) else { return Unmanaged.passUnretained(event) }
    let isDown = ((data & 0xFF00) >> 8) == 0xA
    let handled = MainActor.assumeIsolated { MediaKeyTap.shared.pressed(key, isDown: isDown, flags: flags) }
    return handled ? nil : Unmanaged.passUnretained(event)
}
