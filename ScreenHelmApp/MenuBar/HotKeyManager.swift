import AppKit
import Carbon.HIToolbox
import Observation

/// A key combination: Carbon key code + Carbon modifier mask, the same as in
/// the sibling apps.
struct HotKey: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// From an `NSEvent` in the recorder. `nil` when the press has no
    /// ⌘/⌥/⌃ — a bare letter must never become a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    /// "⌃⌥D" for Settings.
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(keyCode)] { return name }
        // Letters/digits/punctuation: ask the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let layout = unsafeBitCast(CFDataGetBytePtr(unsafeBitCast(layoutData, to: CFData.self)), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    // MARK: Persistence

    /// "hotkey.<key>.keyCode" and ".modifiers"; nothing stored is no shortcut.
    static func load(_ key: String, from defaults: UserDefaults) -> HotKey? {
        guard let code = defaults.object(forKey: "hotkey.\(key).keyCode") as? UInt32,
              let mods = defaults.object(forKey: "hotkey.\(key).modifiers") as? UInt32
        else { return nil }
        return HotKey(keyCode: code, carbonModifiers: mods)
    }

    static func save(_ hotKey: HotKey?, _ key: String, to defaults: UserDefaults) {
        if let hotKey {
            defaults.set(hotKey.keyCode, forKey: "hotkey.\(key).keyCode")
            defaults.set(hotKey.carbonModifiers, forKey: "hotkey.\(key).modifiers")
        } else {
            defaults.removeObject(forKey: "hotkey.\(key).keyCode")
            defaults.removeObject(forKey: "hotkey.\(key).modifiers")
        }
    }
}

/// Registers the global shortcuts with Carbon's `RegisterEventHotKey` — no
/// Accessibility permission needed, and they fire whichever app is in
/// front. Each shortcut has a key: `panelKey` for the menu bar panel, a
/// `DisplayAction`'s raw value for the others. None has keys until the user
/// records some, so ScreenHelm takes no combination another app may use.
@MainActor
@Observable
final class HotKeyManager {
    /// Opens or closes the menu bar panel from anywhere.
    static let panelKey = "togglePanel"
    /// "SCHM": ScreenHelm's signature on every registration, the panic
    /// shortcut's included.
    static let signature = OSType(0x5343_484D)

    private(set) var hotKeys: [String: HotKey] = [:]
    /// Carbon refused these combinations: another app holds them.
    private(set) var failed: [String: HotKey] = [:]
    private let defaults: UserDefaults
    private let onPress: (String) -> Void
    @ObservationIgnored private var keys: [String] = []
    @ObservationIgnored private var registrations: [String: (hotKey: HotKey, ref: EventHotKeyRef)] = [:]
    /// Carbon IDs from 1, clear of the panic shortcut's 900; a key keeps
    /// its ID for the session.
    @ObservationIgnored private var carbonIDs: [String: UInt32] = [:]
    @ObservationIgnored private var nextCarbonID: UInt32 = 1
    @ObservationIgnored private var handlerInstalled = false

    /// Carbon calls a C function; it can't capture, so it finds us here.
    nonisolated(unsafe) private static var current: HotKeyManager?

    init(defaults: UserDefaults = .standard, onPress: @escaping (String) -> Void) {
        self.defaults = defaults
        self.onPress = onPress
    }

    /// Loads and registers `keys`' shortcuts.
    func start(keys: [String]) {
        Self.current = self
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let carbonID = id.id
                Task { @MainActor in
                    if carbonID == DisplaySafety.panicCarbonID {
                        DisplaySafety.shared.panic()
                    } else if let manager = HotKeyManager.current,
                              let key = manager.carbonIDs.first(where: { $0.value == carbonID })?.key {
                        manager.onPress(key)
                    }
                }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        self.keys = keys
        var loaded: [String: HotKey] = [:]
        for key in keys {
            if let hotKey = HotKey.load(key, from: defaults) { loaded[key] = hotKey }
        }
        hotKeys = loaded
        syncRegistrations()
    }

    func hotKey(_ key: String) -> HotKey? {
        hotKeys[key]
    }

    func failed(_ key: String) -> Bool {
        failed[key] != nil
    }

    /// Nil removes the shortcut.
    func update(_ key: String, to newValue: HotKey?) {
        HotKey.save(newValue, key, to: defaults)
        guard keys.contains(key) else { return }
        hotKeys[key] = newValue
        syncRegistrations()
    }

    /// Which ScreenHelm shortcut already uses `hotKey`, so a second one can't.
    func owner(of hotKey: HotKey) -> String? {
        if hotKey == DisplaySafety.panicHotKey { return DisplaySafety.panicKey }
        return hotKeys.first { $0.value == hotKey }?.key
    }

    /// Carbon's registrations made to match `hotKeys`: changed ones again,
    /// a combination another app refused not retried until it changes.
    private func syncRegistrations() {
        for (key, registration) in registrations where hotKeys[key] != registration.hotKey {
            UnregisterEventHotKey(registration.ref)
            registrations[key] = nil
        }
        var failed = self.failed.filter { hotKeys[$0.key] == $0.value }
        for (key, hotKey) in hotKeys where registrations[key] == nil && failed[key] == nil {
            let carbonID = carbonIDs[key] ?? {
                defer { nextCarbonID += 1 }
                carbonIDs[key] = nextCarbonID
                return nextCarbonID
            }()
            var ref: EventHotKeyRef?
            let eventID = EventHotKeyID(signature: Self.signature, id: carbonID)
            if RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, eventID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                registrations[key] = (hotKey, ref)
            } else {
                failed[key] = hotKey
            }
        }
        if failed != self.failed { self.failed = failed }
    }
}
