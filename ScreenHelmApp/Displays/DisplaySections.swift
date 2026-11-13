import ScreenHelmCore
import SwiftUI

/// What every page shows first, while it applies: safe mode, another
/// display app running, another app's colour table over ScreenHelm's.
struct DisplayNotices: View {
    private let safety = DisplaySafety.shared
    @State private var otherApp = DisplayNotices.runningDisplayApp()

    var body: some View {
        Group {
            if safety.isSafeMode || otherApp != nil || GammaController.shared.conflict {
                Section {
                    if safety.isSafeMode {
                        HStack {
                            Label(safety.safeModeFollowsCrash
                                  ? "ScreenHelm ended while applying display settings last time, so the saved ones were not applied now."
                                  : "ScreenHelm was opened with Shift held, so saved display settings were not applied.",
                                  systemImage: "shield.lefthalf.filled")
                            Spacer()
                            Button("Apply Them From Now On") { safety.leaveSafeMode() }
                        }
                    }
                    if let otherApp {
                        Label("\(otherApp) is running. Two apps changing the same display undo each other: use one at a time.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if GammaController.shared.conflict {
                        Label("Another app changed a display's colors after ScreenHelm did. ScreenHelm doesn't change them back over it.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
        }
        .onAppear { otherApp = Self.runningDisplayApp() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            otherApp = Self.runningDisplayApp()
        }
    }

    /// Another display utility that writes the same colour tables and takes the same keys.
    static func runningDisplayApp() -> String? {
        let known = ["pro.betterdisplay.BetterDisplay": "BetterDisplay", "app.monitorcontrol.MonitorControl": "MonitorControl",
                     "me.guillaumeb.MonitorControl": "MonitorControl", "fyi.lunar.Lunar": "Lunar"]
        return NSWorkspace.shared.runningApplications.lazy.compactMap { $0.bundleIdentifier.flatMap { known[$0] } }.first
    }
}

// MARK: - Shortcuts

struct DisplayShortcutsSections: View {
    var body: some View {
        if let hotKeys = StatusBarController.shared.hotKeys {
            Section {
                HotKeyRecorderView(title: "Open the menu bar panel", key: HotKeyManager.panelKey, manager: hotKeys)
                Text("None of the shortcuts has keys until you record some. The ones below act on the display the pointer is on.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Menu Bar Panel")
            }
            ForEach(DisplayAction.Section.allCases, id: \.self) { section in
                Section {
                    ForEach(DisplayAction.allCases.filter { $0.section == section }) { action in
                        HotKeyRecorderView(title: Text(verbatim: action.title), key: action.rawValue, manager: hotKeys)
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
    }
}

// MARK: - One display

struct DisplaySections: View {
    let display: DisplayInfo
    @Bindable private var viewModel = SettingsViewModel.shared
    private let manager = DisplayManager.shared
    private let brightness = BrightnessController.shared
    private let modes = ModeController.shared
    private let ddc = DDCController.shared
    @State private var name = ""
    @State private var modeSearch = ""
    @State private var showAllModes = false
    @State private var showSerial = false
    @State private var presets: (all: [DisplayPrivateAPIs.Preset], active: Int?) = ([], nil)
    @State private var profiles: [ConfigurationController.ColorProfile] = []
    @State private var customProfile: URL?
    @State private var hdr: Bool?
    @State private var canRotate = false

    private var profile: DisplayProfile { manager.profile(for: display) }

    var body: some View {
        overview
        brightnessSection
        if XDRController.shared.isAvailable(for: display) { XDRSection(display: display) }
        resolutionSection
        colorSection
        if !display.kind.isSoftwareOnly { PictureSection(display: display) }
        if !display.kind.isSoftwareOnly { ScalingSection(display: display) }
        if display.kind == .external || display.kind == .tv { DDCSection(display: display) }
        if manager.displays.count > 1 || display.kind == .builtIn { DisplayConnectionSection(display: display) }
        panelSection
        infoSection
    }

    // MARK: Menu bar panel

    private var panelSection: some View {
        Section {
            ForEach(DisplayPanelControl.allCases, id: \.self) { control in
                Toggle(control.title, isOn: Binding(
                    get: { profile.panelControls.contains(control) },
                    set: { on in
                        manager.updateProfile(of: display) { profile in
                            if on { profile.panelControls.insert(control) } else { profile.panelControls.remove(control) }
                        }
                    }
                ))
            }
        } header: {
            Text("In the Menu Bar Panel")
        } footer: {
            Text("A control the display doesn't have stays hidden.")
        }
    }

    // MARK: Overview

    private var overview: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $name, prompt: Text(verbatim: display.systemName))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { rename() }
            }
            LabeledContent("Kind") { Text(display.kind.title) }
            if let current = modes.current(of: display.id) {
                LabeledContent("Now") {
                    Text(verbatim: "\(current.resolution.label)\(current.isHiDPI ? " HiDPI" : ""), \(current.roundedRate) Hz")
                }
            }
            LabeledContent("Brightness is changed through") { Text(brightness.method(for: display).title) }
            if manager.displays.count > 1 {
                if display.isMain {
                    LabeledContent("Main display") { Image(systemName: "checkmark") }
                } else if display.mirrorOf == nil {
                    Button("Make This the Main Display") { ConfigurationController.setMain(display) }
                }
                Picker("Mirror", selection: Binding(
                    get: { display.mirrorOf },
                    set: { target in ConfigurationController.setMirror(of: display, to: target.flatMap(manager.display)) }
                )) {
                    Text("Off").tag(CGDirectDisplayID?.none)
                    ForEach(manager.displays.filter { $0.id != display.id && $0.mirrorOf == nil }) {
                        Text(verbatim: manager.name(of: $0)).tag(CGDirectDisplayID?.some($0.id))
                    }
                }
            }
        } header: {
            Text("Overview")
        }
        .onAppear { load() }
        .onChange(of: display.id) { _, _ in load() }
    }

    private func load() {
        name = profile.name ?? ""
        presets = DisplayPrivateAPIs.presets(of: display.id)
        customProfile = ConfigurationController.customProfile(of: display.id)
        hdr = DisplayPrivateAPIs.hasHDRModes(display.id) ? DisplayPrivateAPIs.prefersHDR(display.id) : nil
        canRotate = DisplayPrivateAPIs.canRotate(display.id)
        if profiles.isEmpty { profiles = ConfigurationController.installedProfiles() }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.updateProfile(of: display) { $0.name = trimmed.isEmpty || trimmed == display.systemName ? nil : trimmed }
    }

    // MARK: Brightness

    private var brightnessSection: some View {
        Section {
            BrightnessSlider(display: display)
            Picker("Change it through", selection: Binding(
                get: { profile.brightnessMethod },
                set: { method in
                    brightness.clearSoftware(for: display)
                    manager.updateProfile(of: display) { $0.brightnessMethod = method }
                }
            )) {
                ForEach(brightness.availableMethods(for: display), id: \.self) { Text($0.title).tag($0) }
            }
            if brightness.method(for: display) == .ddc {
                Toggle("Go on dimming below the monitor's lowest brightness", isOn: Binding(
                    get: { profile.combinedBrightness },
                    set: { on in manager.updateProfile(of: display) { $0.combinedBrightness = on } }
                ))
            }
            if brightness.method(for: display) != .apple {
                Toggle("Allow dimming all the way to black", isOn: Binding(
                    get: { profile.dimToBlack },
                    set: { on in manager.updateProfile(of: display) { $0.dimToBlack = on } }
                ))
                Text("Off, software dimming stops at 15%. A display is never brought back darker than that after sleep or when ScreenHelm opens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Brightness")
        }
    }

    // MARK: Resolution

    private var resolutionSection: some View {
        let all = modes.modes(of: display.id)
        let current = modes.current(of: display.id)
        return Section {
            ResolutionSlider(display: display)
            if let current {
                let rates = DisplayModes.refreshRates(for: current.resolution, in: all)
                if rates.count > 1 {
                    Picker("Refresh rate", selection: Binding(get: { current.roundedRate }, set: { modes.setRefreshRate($0, on: display) })) {
                        ForEach(rates, id: \.self) { rate in
                            Text(verbatim: rateLabel(rate, current: current, all: all)).tag(rate)
                        }
                    }
                }
                if let showsNotch = DisplayModes.showsNotch(current, in: all) {
                    Toggle("Use the area beside the camera housing", isOn: Binding(get: { showsNotch }, set: { _ in modes.toggleNotch(on: display) }))
                }
                if DisplayModes.hiDPITwin(of: current, in: all) != nil {
                    Toggle("HiDPI", isOn: Binding(get: { current.isHiDPI }, set: { _ in modes.toggleHiDPI(on: display) }))
                }
            }
            if canRotate, display.kind != .builtIn || viewModel.settings.displaysAdvanced {
                Picker("Rotation", selection: Binding(get: { display.rotation }, set: { ConfigurationController.setRotation($0, on: display) })) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text(verbatim: "\($0)°").tag($0) }
                }
            }
            if let current {
                ForEach(manager.displays.filter { $0.id != display.id && $0.mirrorOf == nil }) { other in
                    if let match = textSizeMatch(to: other, current: current, all: all), match != current.resolution {
                        Button("Make Things as Big as on \(manager.name(of: other)): \(match.label)") { modes.setResolution(match, on: display) }
                    }
                }
            }
            let list = resolutions(all)
            if !profile.favoriteModes.isEmpty || showAllModes {
                ForEach(list, id: \.self) { resolution in
                    resolutionRow(resolution, current: current, all: all)
                }
            }
            if showAllModes {
                TextField("Search", text: $modeSearch, prompt: Text("Find a resolution, such as 1920"))
            }
            Button(showAllModes ? "Show Favorites Only" : "Show All \(DisplayModes.resolutions(in: all).count) Resolutions") {
                showAllModes.toggle()
                modeSearch = ""
            }
        } header: {
            Text("Resolution")
        } footer: {
            Text("The list has every mode the display reports, including the ones System Settings leaves out. A star keeps one at the top and gives it a shortcut.")
        }
    }

    private func resolutions(_ all: [DisplayModeInfo]) -> [DisplayResolution] {
        let favorites = profile.favoriteModes
        guard showAllModes else { return favorites }
        let query = modeSearch.trimmingCharacters(in: .whitespaces)
        return DisplayModes.resolutions(in: all).filter { query.isEmpty || $0.label.replacingOccurrences(of: " ", with: "").contains(query.replacingOccurrences(of: " ", with: "")) }
    }

    private static func widthMillimeters(of display: CGDirectDisplayID) -> Double {
        Double(CGDisplayScreenSize(display).width)
    }

    /// The size here at which a point is as wide as on `other`.
    private func textSizeMatch(to other: DisplayInfo, current: DisplayModeInfo, all: [DisplayModeInfo]) -> DisplayResolution? {
        let otherWidth = Self.widthMillimeters(of: other.id)
        guard otherWidth > 0, other.bounds.width > 0 else { return nil }
        return DisplayModes.resolution(matching: Double(other.bounds.width) / otherWidth, widthMillimeters: Self.widthMillimeters(of: display.id),
                                       like: current, in: all)
    }

    private func rateLabel(_ rate: Int, current: DisplayModeInfo, all: [DisplayModeInfo]) -> String {
        let mode = DisplayModes.mode(like: current, atRate: rate, in: all)
        return mode?.isProMotion == true ? "ProMotion" : "\(rate) Hz"
    }

    private func resolutionRow(_ resolution: DisplayResolution, current: DisplayModeInfo?, all: [DisplayModeInfo]) -> some View {
        HStack {
            Button {
                modes.toggleFavorite(resolution, on: display)
            } label: {
                Image(systemName: modes.isFavorite(resolution, on: display) ? "star.fill" : "star")
                    .foregroundStyle(modes.isFavorite(resolution, on: display) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Favorite"))
            Text(verbatim: resolution.label).monospacedDigit()
            if resolution.isHiDPI {
                Text(verbatim: "HiDPI").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if all.contains(where: { $0.resolution == resolution && $0.isNative }) {
                Text("Native").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if current?.resolution == resolution {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            } else {
                Button("Use") { modes.setResolution(resolution, on: display) }
            }
        }
    }

    // MARK: Colour

    @ViewBuilder
    private var colorSection: some View {
        if !presets.all.isEmpty || hdr != nil || !display.kind.isSoftwareOnly {
            Section {
                if !presets.all.isEmpty {
                    Picker("Reference preset", selection: Binding(
                        get: { presets.active ?? -1 },
                        set: { index in
                            ConfigurationController.setPreset(index, on: display)
                            presets.active = index
                        }
                    )) {
                        ForEach(presets.all) { Text(verbatim: $0.name).tag($0.id) }
                    }
                }
                if let hdr {
                    Toggle("HDR", isOn: Binding(get: { hdr }, set: { on in
                        ConfigurationController.setHDR(on, on: display)
                        self.hdr = on
                    }))
                }
                if !display.kind.isSoftwareOnly {
                    Picker("Color profile", selection: Binding(
                        get: { customProfile },
                        set: { url in
                            if ConfigurationController.setProfile(url, on: display.id) { customProfile = url }
                        }
                    )) {
                        Text("The display's own").tag(URL?.none)
                        ForEach(profiles) { Text(verbatim: $0.name).tag(URL?.some($0.url)) }
                    }
                    if let dithering = DisplayPrivateAPIs.dithering(at: display.identity.location) {
                        Toggle("Dithering", isOn: Binding(
                            get: { !profile.ditheringOff && dithering },
                            set: { on in
                                DisplayPrivateAPIs.setDithering(on, at: display.identity.location)
                                manager.updateProfile(of: display) { $0.ditheringOff = !on }
                            }
                        ))
                        Text("The display mixes neighbouring colors over time to show shades it hasn't got. Off, gradients band a little more; some eyes find it calmer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if customProfile != nil {
                        Text("With a profile of your choice, ScreenHelm dims this display with an overlay: changing the color table as well can black the screen out on some Macs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Color")
            }
        }
    }

    // MARK: Info

    private var infoSection: some View {
        let identity = display.identity
        let info = DisplayPrivateAPIs.info(of: display.id)
        let edid = ddc.edid(of: display)
        let parsed = edid.flatMap { EDID($0) }
        return Section {
            LabeledContent("Reported name") { Text(verbatim: display.systemName) }
            LabeledContent("Maker and model") {
                Text(verbatim: "\(parsed?.manufacturer ?? String(format: "%04X", identity.vendor)) \(String(format: "%04X", identity.product))")
                    .monospaced()
            }
            if identity.year > 0 {
                LabeledContent("Made") { Text(verbatim: identity.week > 0 ? "\(identity.year), week \(identity.week)" : "\(identity.year)") }
            }
            if let width = (info["DisplayHorizontalImageSize"] as? NSNumber)?.doubleValue,
               let height = (info["DisplayVerticalImageSize"] as? NSNumber)?.doubleValue, width > 0, height > 0 {
                LabeledContent("Size") {
                    Text(verbatim: String(format: "%.1f″ (%.0f × %.0f mm)", (width * width + height * height).squareRoot() / 25.4, width, height))
                }
            }
            if let native = modes.modes(of: display.id).first(where: \.isNative) {
                LabeledContent("Panel") { Text(verbatim: "\(native.pixelWidth) × \(native.pixelHeight) px") }
            }
            if let parsed, let peak = parsed.maxLuminance {
                LabeledContent("Peak brightness it reports") { Text(verbatim: "\(Int(peak.rounded())) nits") }
            }
            LabeledContent("Serial number") {
                if showSerial {
                    Text(verbatim: identity.alphanumericSerial.isEmpty ? String(identity.serial) : identity.alphanumericSerial)
                        .monospaced().textSelection(.enabled)
                } else {
                    Button("Show") { showSerial = true }
                }
            }
            if let edid {
                Button("Export EDID…") { Self.export(edid, name: display.systemName) }
            }
        } header: {
            Text("Information")
        } footer: {
            if edid != nil {
                Text("An EDID file holds the display's serial number.")
            }
        }
    }

    private static func export(_ edid: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).edid.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? edid.write(to: url)
    }
}

/// The brightness slider with its figure: nits where they can be read, a
/// percentage otherwise.
struct BrightnessSlider: View {
    let display: DisplayInfo
    private let brightness = BrightnessController.shared

    var body: some View {
        let value = brightness.value(for: display)
        let locked = brightness.locked.contains(display.id)
        HStack(spacing: 10) {
            Image(systemName: locked ? "lock" : "sun.min").foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { brightness.set($0, for: display) }), in: 0...brightness.maximum(for: display))
                .labelsHidden()
                .tint(value > 1 ? .orange : nil)
                .disabled(locked)
            Image(systemName: "sun.max").foregroundStyle(.secondary)
            Text(verbatim: label(value)).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
        }
        .help(locked ? Text("The reference preset in use holds the brightness in place.") : Text(verbatim: ""))
    }

    private func label(_ value: Double) -> String {
        if let nits = brightness.nits(for: display) { return "\(Int(nits.rounded())) nits" }
        return "\(Int((min(1, value) * 100).rounded()))%"
    }
}

extension DisplayKind {
    var title: LocalizedStringKey {
        switch self {
        case .builtIn: "Built-in display"
        case .external: "External display"
        case .tv: "TV"
        case .airPlay: "AirPlay display"
        case .sidecar: "iPad (Sidecar)"
        case .virtual: "Virtual display"
        }
    }
}

extension DisplayPanelControl {
    var title: LocalizedStringKey {
        switch self {
        case .brightness: "Brightness"
        case .volume: "Volume"
        case .resolution: "Resolution"
        case .refreshRate: "Refresh rate"
        case .input: "Input"
        case .preset: "Reference preset"
        }
    }
}

extension BrightnessMethod {
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .apple: "The display's backlight"
        case .ddc: "The monitor's own brightness (DDC)"
        case .gamma: "The color table"
        case .overlay: "A dark overlay"
        }
    }
}
