import ScreenHelmCore
import SwiftUI

/// The menu bar panel's displays: the controls reached every day, one
/// block per display.
struct DisplaysPanelContent: View {
    private let manager = DisplayManager.shared
    @Bindable private var viewModel = SettingsViewModel.shared
    @State private var nightShift = SystemToggles.nightShift
    @State private var trueTone = SystemToggles.trueTone

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(manager.displays) { display in
                    DisplayPanelBlock(display: display)
                    Divider()
                }
                HStack(spacing: 14) {
                    if let nightShift {
                        Toggle("Night Shift", isOn: Binding(get: { nightShift }, set: { on in
                            SystemToggles.setNightShift(on)
                            self.nightShift = on
                        }))
                    }
                    if let trueTone {
                        Toggle("True Tone", isOn: Binding(get: { trueTone }, set: { on in
                            SystemToggles.setTrueTone(on)
                            self.trueTone = on
                        }))
                    }
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .font(.caption)
                if manager.displays.count > 1 {
                    Picker("Other displays follow", selection: $viewModel.settings.displaysSyncSource) {
                        Text("Off").tag(BrightnessSyncSource.off)
                        Text("The built-in display").tag(BrightnessSyncSource.builtIn)
                        Text("The light in the room").tag(BrightnessSyncSource.ambientLight)
                    }
                    .font(.caption)
                    .controlSize(.small)
                    .fixedSize()
                }
                if !ConnectionController.shared.disconnected.isEmpty {
                    Button("Switch Every Display Back On") { ConnectionController.shared.reconnectAll() }.controlSize(.small)
                }
            }
            .padding(14)
        }
        .onAppear {
            nightShift = SystemToggles.nightShift
            trueTone = SystemToggles.trueTone
        }
    }
}

struct DisplayPanelBlock: View {
    let display: DisplayInfo
    private let manager = DisplayManager.shared
    private let modes = ModeController.shared
    private let ddc = DDCController.shared
    @Bindable private var viewModel = SettingsViewModel.shared
    /// Read once when the block appears, not on every redraw.
    @State private var canRotate = false

    private var controls: Set<DisplayPanelControl> { manager.profile(for: display).panelControls }

    /// The quick switches this display has, among those chosen for the panel.
    static func quickSwitches(for display: DisplayInfo, controls: Set<DisplayPanelControl>) -> [DisplayPanelControl] {
        let modes = ModeController.shared
        let all = modes.modes(of: display.id)
        let current = modes.current(of: display.id)
        var switches: [DisplayPanelControl] = []
        if controls.contains(.hiDPI), let current, DisplayModes.hiDPITwin(of: current, in: all) != nil { switches.append(.hiDPI) }
        if controls.contains(.notch), let current, DisplayModes.showsNotch(current, in: all) != nil { switches.append(.notch) }
        if controls.contains(.xdr), XDRController.shared.isAvailable(for: display) { switches.append(.xdr) }
        return switches
    }

    private var showsRotation: Bool { canRotate && (display.kind != .builtIn || viewModel.settings.displaysAdvanced) }
    private var canSwitchOff: Bool { ConnectionController.shared.refusal(for: display) == nil }
    private var hasMoreMenu: Bool {
        controls.contains(.more) && (showsRotation || manager.displays.count > 1 || canSwitchOff)
    }

    private var showsPicture: Bool {
        StreamController.shared.configs.contains {
            $0.source == .display(display.key) && $0.target == .floatingWindow && StreamController.shared.running.contains($0.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: display.symbolName).foregroundStyle(.secondary)
                Text(verbatim: manager.name(of: display)).font(.callout.weight(.medium)).lineLimit(1)
                if display.isMain && manager.displays.count > 1 {
                    Text("Main").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                }
                Spacer()
                Button {
                    DisplayShortcuts.perform(.pictureInPicture, on: display)
                } label: {
                    Image(systemName: "pip").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(showsPicture ? Color.accentColor : Color.secondary)
                .help(Text("Show this display in a floating window"))
                if hasMoreMenu { moreMenu }
                Button {
                    WindowPresenter.show(.display(display.key))
                } label: {
                    Image(systemName: "chevron.right").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("More settings for this display"))
            }
            if controls.contains(.brightness) {
                BrightnessSlider(display: display).font(.caption).controlSize(.small)
            }
            if controls.contains(.volume), ddc.isAvailable(display), ddc.supports(.volume, on: display) {
                HStack(spacing: 10) {
                    Image(systemName: "speaker").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { ddc.fraction(.volume, on: display) ?? 0.5 },
                                          set: { ddc.setFraction($0, for: .volume, on: display) }), in: 0...1)
                    Image(systemName: "speaker.wave.3").foregroundStyle(.secondary)
                }
                .font(.caption).controlSize(.small)
            }
            HStack(spacing: 8) {
                if controls.contains(.resolution) { resolutionMenu }
                if controls.contains(.refreshRate) { rateMenu }
                if controls.contains(.input), ddc.isAvailable(display) { inputMenu }
                if controls.contains(.preset) { presetMenu }
                Spacer()
            }
            .controlSize(.small)
            let switches = Self.quickSwitches(for: display, controls: controls)
            if !switches.isEmpty {
                HStack(spacing: 14) {
                    ForEach(switches, id: \.self) { quickSwitch($0) }
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
        .onAppear { canRotate = DisplayPrivateAPIs.canRotate(display.id) }
        .onChange(of: display.id) { _, id in canRotate = DisplayPrivateAPIs.canRotate(id) }
    }

    @ViewBuilder
    private func quickSwitch(_ control: DisplayPanelControl) -> some View {
        let current = modes.current(of: display.id)
        let all = modes.modes(of: display.id)
        switch control {
        case .hiDPI:
            Toggle("HiDPI", isOn: Binding(get: { current?.isHiDPI ?? false }, set: { _ in modes.toggleHiDPI(on: display) }))
        case .notch:
            Toggle("Notch Area", isOn: Binding(get: { current.flatMap { DisplayModes.showsNotch($0, in: all) } ?? false },
                                               set: { _ in modes.toggleNotch(on: display) }))
                .help(Text("Use the area beside the camera housing"))
        case .xdr:
            Toggle("XDR", isOn: Binding(get: { manager.profile(for: display).xdrBoost },
                                        set: { XDRController.shared.setEnabled($0, for: display) }))
                .help(Text("Let the brightness slider go past 100%"))
        default:
            EmptyView()
        }
    }

    private var moreMenu: some View {
        Menu {
            if showsRotation {
                Picker("Rotation", selection: Binding(get: { display.rotation }, set: { ConfigurationController.setRotation($0, on: display) })) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text(verbatim: "\($0)°").tag($0) }
                }
            }
            if manager.displays.count > 1 {
                if !display.isMain && display.mirrorOf == nil {
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
            if canSwitchOff {
                Divider()
                Button("Switch Off") { ConnectionController.shared.disconnect(display) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(Text("More for this display"))
    }

    @ViewBuilder
    private var resolutionMenu: some View {
        let all = modes.modes(of: display.id)
        if let current = modes.current(of: display.id) {
            let favorites = manager.profile(for: display).favoriteModes
            let list = favorites.isEmpty ? Array(DisplayModes.sliderResolutions(like: current, in: all).reversed()) : favorites
            Menu {
                ForEach(list, id: \.self) { resolution in
                    Button {
                        modes.setResolution(resolution, on: display)
                    } label: {
                        if resolution == current.resolution {
                            Label { Text(verbatim: label(resolution)) } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: label(resolution))
                        }
                    }
                }
            } label: {
                Text(verbatim: current.resolution.label)
            }
            .fixedSize()
        }
    }

    private func label(_ resolution: DisplayResolution) -> String {
        resolution.isHiDPI ? "\(resolution.label) HiDPI" : resolution.label
    }

    @ViewBuilder
    private var rateMenu: some View {
        let all = modes.modes(of: display.id)
        if let current = modes.current(of: display.id) {
            let rates = DisplayModes.refreshRates(for: current.resolution, in: all)
            if rates.count > 1 {
                Menu {
                    ForEach(rates, id: \.self) { rate in
                        Button { modes.setRefreshRate(rate, on: display) } label: { Text(verbatim: "\(rate) Hz") }
                    }
                } label: {
                    Text(verbatim: "\(current.roundedRate) Hz")
                }
                .fixedSize()
            }
        }
    }

    private var inputMenu: some View {
        let names = manager.profile(for: display).inputNames
        return Menu {
            ForEach(DDCInput.common) { input in
                Button { ddc.setInput(input, on: display) } label: { Text(verbatim: names[input.value] ?? input.standardName) }
            }
        } label: {
            Text("Input")
        }
        .fixedSize()
    }

    @ViewBuilder
    private var presetMenu: some View {
        let presets = DisplayPrivateAPIs.presets(of: display.id)
        if !presets.all.isEmpty {
            Menu {
                ForEach(presets.all) { preset in
                    Button { ConfigurationController.setPreset(preset.id, on: display) } label: { Text(verbatim: preset.name) }
                }
            } label: {
                Text("Preset")
            }
            .fixedSize()
        }
    }
}
