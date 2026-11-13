import ScreenHelmCore
import SwiftUI

/// The Settings page: the app itself, the switches that apply to every
/// display, and the safety net. Every change applies at once.
struct SettingsSections: View {
    @AppStorage(ThemePreference.key) private var themeRaw = ThemePreference.system.rawValue
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue
    @State private var loginItemEnabled = LoginItemManager.shared.isEnabled
    @State private var isShowingLicenses = false
    @State private var loginItemNeedsApproval = LoginItemManager.shared.requiresApproval
    @State private var loginItemError: String?
    /// Mirrors Sparkle's own preference for display only; `onAppear` reads it
    /// again because Sparkle's prompt can change it after the view was built.
    @State private var automaticUpdateChecks = AppUpdater.automaticallyChecksForUpdates
    @Bindable private var viewModel = SettingsViewModel.shared
    private let manager = DisplayManager.shared
    private let permissions = Permissions.shared
    private var settings: AppSettings { viewModel.settings }

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: $themeRaw) {
                ForEach(ThemePreference.allCases) { theme in
                    Text(theme.label).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Picker("Language", selection: Binding(
                get: { AppLocale(rawValue: languageRaw) ?? .systemDefault },
                set: { languageRaw = $0.rawValue }
            )) {
                Text(verbatim: "VI").tag(AppLocale.vi)
                Text(verbatim: "EN").tag(AppLocale.en)
            }
            .pickerStyle(.segmented)
        }
        .onAppear {
            automaticUpdateChecks = AppUpdater.automaticallyChecksForUpdates
            permissions.refresh()
        }
        .onChange(of: themeRaw) { _, _ in ThemePreference.apply() }

        Section("General") {
            Toggle("Launch at Login", isOn: Binding(get: { loginItemEnabled }, set: { setLoginItem($0) }))
            if loginItemNeedsApproval {
                Label("Waiting for your approval in System Settings › General › Login Items. Until then ScreenHelm won't start at login.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
            Text("Right-click the menu bar icon for a short menu. Esc closes the panel.")
                .font(.caption).foregroundStyle(.secondary)
        }

        displaysSection
        safetySection

        Section {
            permissionRow(
                "Accessibility",
                detail: "For the keyboard's brightness and volume keys, and to find the display of the window in front.",
                granted: permissions.accessibility,
                request: permissions.requestAccessibility
            )
            permissionRow(
                "Screen Recording",
                detail: "For picture in picture only. Nothing is recorded or saved.",
                granted: permissions.screenRecording,
                request: permissions.requestScreenRecording
            )
        } header: {
            Text("Permissions")
        } footer: {
            Text("Everything else works without them. After you allow one in System Settings, macOS may ask to quit and reopen ScreenHelm.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { automaticUpdateChecks },
                set: {
                    automaticUpdateChecks = $0
                    AppUpdater.automaticallyChecksForUpdates = $0
                }
            ))
            Text("Checks updates.dangkhoabach.vn once a day. Turning this off means updates only happen when you ask for them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Check Now") { AppUpdater.checkForUpdates() }
            }
        }

        thirdPartySection
    }

    /// The switches that apply to every display.
    private var displaysSection: some View {
        Section {
            Toggle("Keyboard brightness and volume keys control other displays", isOn: $viewModel.settings.displaysKeysEnabled)
            Text("macOS only lets these keys change the built-in display and Apple's own monitors. With this on they also change the display you are working on. Presses meant for a display macOS controls itself are left to macOS.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.displaysKeysEnabled && !permissions.accessibility {
                HStack {
                    Label("This needs the Accessibility permission.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Allow…") { permissions.requestAccessibility() }
                }
            }
            if settings.displaysKeysEnabled {
                Picker("The keys change", selection: $viewModel.settings.displaysKeyTarget) {
                    Text("The display the pointer is on").tag(DisplayKeyTarget.pointer)
                    Text("The display with the window in front").tag(DisplayKeyTarget.focusedWindow)
                    Text("Every display").tag(DisplayKeyTarget.all)
                    Text("One display").tag(DisplayKeyTarget.fixed)
                }
                if settings.displaysKeyTarget == .fixed {
                    Picker("Display", selection: $viewModel.settings.displaysKeyFixedDisplay) {
                        ForEach(manager.displays) { Text(verbatim: manager.name(of: $0)).tag($0.key) }
                    }
                }
            }
            Toggle("Show brightness and volume changes on screen", isOn: $viewModel.settings.displaysOSD)
            Toggle("Remember settings for each display", isOn: $viewModel.settings.displaysRemember)
            Text("A display gets its dimming and picture settings back when it is connected again.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Displays")
        }
    }

    private var safetySection: some View {
        Section {
            Toggle("Dim with an overlay instead of the color table", isOn: $viewModel.settings.displaysPreferOverlay)
            Text("For a Mac where software dimming has no visible effect. An overlay also shows in screenshots and recordings.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show settings that can leave a display unusable", isOn: $viewModel.settings.displaysAdvanced)
            Text("Rotating the built-in display, for one. Each change still has to be kept within 15 seconds or it is undone.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent {
                Text(verbatim: DisplaySafety.panicHotKey.displayString).monospaced()
            } label: {
                Text("Undo everything ScreenHelm applied to displays")
                Text("Works while something is applied: dimming, picture changes, a setting waiting to be kept. What a monitor stored itself stays.")
            }
        } header: {
            Text("Safety")
        }
    }

    /// The licenses of what ScreenHelm is built with, which ask for their
    /// notices to travel with the app. Shown as written, in English.
    private var thirdPartySection: some View {
        Section("Third-Party Software") {
            LabeledContent("GRDB.swift", value: "MIT")
            LabeledContent("Sparkle", value: "MIT")
            HStack {
                Spacer()
                Button("Show Licenses…") { isShowingLicenses = true }
            }
        }
        .sheet(isPresented: $isShowingLicenses) {
            VStack(spacing: 0) {
                ScrollView {
                    Text(verbatim: Self.thirdPartyNotices)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { isShowingLicenses = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 620, height: 480)
        }
    }

    private static let thirdPartyNotices: String = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    private func permissionRow(
        _ title: LocalizedStringKey, detail: LocalizedStringKey, granted: Bool, request: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: request)
            }
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                loginItemNeedsApproval = try LoginItemManager.shared.enable()
            } else {
                try LoginItemManager.shared.disable()
                loginItemNeedsApproval = false
            }
            loginItemEnabled = LoginItemManager.shared.isEnabled
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            loginItemEnabled = LoginItemManager.shared.isEnabled
        }
    }
}
