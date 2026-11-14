import Foundation
import GRDB

/// ScreenHelm's settings in `app_settings`, one row per setting.
public struct AppSettings: Equatable, Sendable {
    /// The keyboard's brightness and volume keys also control displays
    /// macOS doesn't. Off by default: it takes those keys through an event tap.
    public var displaysKeysEnabled: Bool
    public var displaysKeyTarget: DisplayKeyTarget
    /// The identity key of the display the keys always control, for `.fixed`.
    public var displaysKeyFixedDisplay: String
    /// ScreenHelm's own on-screen display when it changes brightness or volume.
    public var displaysOSD: Bool
    /// A display that connects gets back what was set for it.
    public var displaysRemember: Bool
    /// Shows the settings that can leave a display unusable.
    public var displaysAdvanced: Bool
    /// Dims with an overlay instead of the colour table, for Macs where the table has no effect.
    public var displaysPreferOverlay: Bool
    /// Unplugged at or below this percentage, XDR boost turns off. 0 never does.
    public var displaysXDRBatteryMinimum: Int
    /// Night Shift is switched off while XDR boost is on: both change the colour table.
    public var displaysXDRPauseNightShift: Bool
    /// Night Shift and True Tone are switched off while a display shows HDR, and back on after.
    public var displaysPauseColorsInHDR: Bool
    public var displaysSyncSource: BrightnessSyncSource
    /// Displays are matched by the light they give, not by their slider.
    public var displaysSyncByNits: Bool
    public var displaysProtection: DisplayProtectionSettings
    /// The built-in display is switched off while another display is connected.
    public var displaysAutoDisconnectBuiltIn: Bool
    /// A display ScreenHelm switched off is switched off again after the Mac wakes.
    public var displaysDisconnectAgainAfterWake: Bool
    /// Identity keys of displays that keep the Mac awake while connected.
    public var keepAwakeDisplays: [String]
    public var displayEventActions: [DisplayEventAction]
    /// A virtual screen is made while no real display is connected, so a
    /// Mac without a monitor has a desktop to share.
    public var displaysHeadlessScreen: Bool
    /// Display commands are taken from the command line and from
    /// `screenhelm://display/…` links. Off by default: a link can come from anywhere.
    public var displaysAutomation: Bool
    /// The same commands over HTTP, on this Mac only, with a token.
    public var displaysHTTPEnabled: Bool
    public var displaysHTTPPort: Int
    public var displayGroups: [DisplayGroup]

    public static let defaults = AppSettings(
        displaysKeysEnabled: false,
        displaysKeyTarget: .pointer,
        displaysKeyFixedDisplay: "",
        displaysOSD: true,
        displaysRemember: true,
        displaysAdvanced: false,
        displaysPreferOverlay: false,
        displaysXDRBatteryMinimum: 20,
        displaysXDRPauseNightShift: false,
        displaysPauseColorsInHDR: false,
        displaysSyncSource: .off,
        displaysSyncByNits: false,
        displaysProtection: DisplayProtectionSettings(),
        displaysAutoDisconnectBuiltIn: false,
        displaysDisconnectAgainAfterWake: false,
        keepAwakeDisplays: [],
        displayEventActions: [],
        displaysHeadlessScreen: false,
        displaysAutomation: false,
        displaysHTTPEnabled: false,
        displaysHTTPPort: 55777,
        displayGroups: []
    )
}

public struct SettingsRepository: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func load() throws -> AppSettings {
        try dbQueue.read { db in
            let d = AppSettings.defaults
            func int(_ key: String, _ fallback: Int) throws -> Int {
                Int(try AppSettingsStore.get(db, key: key, default: String(fallback))) ?? fallback
            }
            return AppSettings(
                displaysKeysEnabled: try AppSettingsStore.get(db, key: "displays_keys_enabled", default: "0") == "1",
                displaysKeyTarget: DisplayKeyTarget(rawValue: try AppSettingsStore.get(db, key: "displays_key_target", default: d.displaysKeyTarget.rawValue)) ?? d.displaysKeyTarget,
                displaysKeyFixedDisplay: try AppSettingsStore.get(db, key: "displays_key_fixed_display", default: ""),
                displaysOSD: try AppSettingsStore.get(db, key: "displays_osd", default: "1") == "1",
                displaysRemember: try AppSettingsStore.get(db, key: "displays_remember", default: "1") == "1",
                displaysAdvanced: try AppSettingsStore.get(db, key: "displays_advanced", default: "0") == "1",
                displaysPreferOverlay: try AppSettingsStore.get(db, key: "displays_prefer_overlay", default: "0") == "1",
                displaysXDRBatteryMinimum: try int("displays_xdr_battery_minimum", d.displaysXDRBatteryMinimum),
                displaysXDRPauseNightShift: try AppSettingsStore.get(db, key: "displays_xdr_pause_night_shift", default: "0") == "1",
                displaysPauseColorsInHDR: try AppSettingsStore.get(db, key: "displays_pause_colors_in_hdr", default: "0") == "1",
                displaysSyncSource: BrightnessSyncSource(rawValue: try AppSettingsStore.get(db, key: "displays_sync_source", default: d.displaysSyncSource.rawValue)) ?? d.displaysSyncSource,
                displaysSyncByNits: try AppSettingsStore.get(db, key: "displays_sync_by_nits", default: "0") == "1",
                displaysProtection: DisplayProtectionSettings.decode(try AppSettingsStore.get(db, key: "displays_protection", default: "")),
                displaysAutoDisconnectBuiltIn: try AppSettingsStore.get(db, key: "displays_auto_disconnect_built_in", default: "0") == "1",
                displaysDisconnectAgainAfterWake: try AppSettingsStore.get(db, key: "displays_disconnect_again_after_wake", default: "0") == "1",
                keepAwakeDisplays: try AppSettingsStore.get(db, key: "keep_awake_displays", default: "")
                    .split(separator: "\n").map(String.init),
                displayEventActions: DisplayEventAction.decode(try AppSettingsStore.get(db, key: "display_event_actions", default: "[]")),
                displaysHeadlessScreen: try AppSettingsStore.get(db, key: "displays_headless_screen", default: "0") == "1",
                displaysAutomation: try AppSettingsStore.get(db, key: "displays_automation", default: "0") == "1",
                displaysHTTPEnabled: try AppSettingsStore.get(db, key: "displays_http_enabled", default: "0") == "1",
                displaysHTTPPort: try int("displays_http_port", d.displaysHTTPPort),
                displayGroups: DisplayGroup.decode(try AppSettingsStore.get(db, key: "display_groups", default: "[]"))
            )
        }
    }

    public func update(_ settings: AppSettings) throws {
        try dbQueue.write { db in
            try AppSettingsStore.set(db, key: "displays_keys_enabled", value: settings.displaysKeysEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_key_target", value: settings.displaysKeyTarget.rawValue)
            try AppSettingsStore.set(db, key: "displays_key_fixed_display", value: settings.displaysKeyFixedDisplay)
            try AppSettingsStore.set(db, key: "displays_osd", value: settings.displaysOSD ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_remember", value: settings.displaysRemember ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_advanced", value: settings.displaysAdvanced ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_prefer_overlay", value: settings.displaysPreferOverlay ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_xdr_battery_minimum", value: String(settings.displaysXDRBatteryMinimum))
            try AppSettingsStore.set(db, key: "displays_xdr_pause_night_shift", value: settings.displaysXDRPauseNightShift ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_pause_colors_in_hdr", value: settings.displaysPauseColorsInHDR ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_sync_source", value: settings.displaysSyncSource.rawValue)
            try AppSettingsStore.set(db, key: "displays_sync_by_nits", value: settings.displaysSyncByNits ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_protection", value: settings.displaysProtection.encoded)
            try AppSettingsStore.set(db, key: "displays_auto_disconnect_built_in", value: settings.displaysAutoDisconnectBuiltIn ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_disconnect_again_after_wake", value: settings.displaysDisconnectAgainAfterWake ? "1" : "0")
            try AppSettingsStore.set(db, key: "keep_awake_displays", value: settings.keepAwakeDisplays.joined(separator: "\n"))
            try AppSettingsStore.set(db, key: "display_event_actions", value: DisplayEventAction.encode(settings.displayEventActions))
            try AppSettingsStore.set(db, key: "displays_headless_screen", value: settings.displaysHeadlessScreen ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_automation", value: settings.displaysAutomation ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_http_enabled", value: settings.displaysHTTPEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "displays_http_port", value: String(settings.displaysHTTPPort))
            try AppSettingsStore.set(db, key: "display_groups", value: DisplayGroup.encode(settings.displayGroups))
        }
    }
}

/// Which display the keyboard's brightness keys control.
public enum DisplayKeyTarget: String, Sendable, CaseIterable {
    /// The one the pointer is on.
    case pointer
    /// The one with the window in front.
    case focusedWindow
    case all
    /// Always the same one, chosen by the user.
    case fixed
}
