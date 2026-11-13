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
                    if manager.displays.count > 1 {
                        Toggle("Same brightness", isOn: Binding(
                            get: { viewModel.settings.displaysSyncSource != .off },
                            set: { viewModel.settings.displaysSyncSource = $0 ? .builtIn : .off }
                        ))
                    }
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .font(.caption)
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

private struct DisplayPanelBlock: View {
    let display: DisplayInfo
    private let manager = DisplayManager.shared
    private let modes = ModeController.shared
    private let ddc = DDCController.shared

    private var controls: Set<DisplayPanelControl> { manager.profile(for: display).panelControls }

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
        }
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
