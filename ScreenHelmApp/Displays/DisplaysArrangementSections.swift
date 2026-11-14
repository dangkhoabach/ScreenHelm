import ScreenHelmCore
import SwiftUI
import UniformTypeIdentifiers

/// The Arrangement tab: the displays to drag into place, what is kept when
/// macOS rearranges them, brightness syncing, and what happens when
/// displays come and go.
struct ArrangementSections: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    private let manager = DisplayManager.shared
    private let layout = LayoutGuard.shared
    private let connection = ConnectionController.shared
    @State private var sidecar: [(name: String, connected: Bool)] = []

    private var settings: AppSettings { viewModel.settings }

    var body: some View {
        Section {
            ArrangementView()
            Text("Drag a display to where it stands on your desk. The one with the white strip is the main display.")
                .font(.caption).foregroundStyle(.secondary)
            let twins = identicalPair
            if let twins {
                Button("Swap \(manager.name(of: twins.0)) and \(manager.name(of: twins.1))") { layout.swap(twins.0, twins.1) }
            }
        } header: {
            Text("Arrangement")
        }

        Section {
            Toggle("Put the arrangement back when macOS changes it", isOn: $viewModel.settings.displaysProtection.enabled)
            Text("After sleep, or when a display is plugged in, macOS sometimes moves displays around or picks another resolution. ScreenHelm keeps one arrangement for each set of displays and returns to it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if layout.savedForCurrentDisplays != nil {
                    Label("An arrangement is kept for these displays.", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                } else {
                    Label("Nothing is kept for these displays yet.", systemImage: "seal").foregroundStyle(.secondary)
                }
                Spacer()
                if layout.savedForCurrentDisplays != nil {
                    Button("Forget") { layout.forgetCurrent() }
                    Button("Put It Back Now") { layout.applySaved() }
                }
                Button("Keep the Current One") { layout.saveCurrent() }
            }
            if layout.gaveUp {
                Label("macOS undid the arrangement three times in a row, so ScreenHelm stopped putting it back. Keep the current one to start again.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Group {
                Toggle("Position and main display", isOn: $viewModel.settings.displaysProtection.position)
                Toggle("Resolution and refresh rate", isOn: $viewModel.settings.displaysProtection.resolution)
                Toggle("Rotation", isOn: $viewModel.settings.displaysProtection.rotation)
                Toggle("Mirroring", isOn: $viewModel.settings.displaysProtection.mirroring)
                Toggle("Color profile", isOn: $viewModel.settings.displaysProtection.colorProfile)
                Toggle("HDR", isOn: $viewModel.settings.displaysProtection.hdr)
            }
            .disabled(!settings.displaysProtection.enabled)
        } header: {
            Text("Protection")
        } footer: {
            Text("A change you make in System Settings counts as macOS's and is undone too: after one, choose Keep the Current One.")
        }

        Section {
            Picker("Other displays follow", selection: $viewModel.settings.displaysSyncSource) {
                Text("Off").tag(BrightnessSyncSource.off)
                Text("The built-in display").tag(BrightnessSyncSource.builtIn)
                Text("The light in the room").tag(BrightnessSyncSource.ambientLight)
            }
            if settings.displaysSyncSource == .builtIn {
                Toggle("Match the light they give, in nits", isOn: $viewModel.settings.displaysSyncByNits)
                Text("Needs each monitor's brightest value, set under that display. Off, they are set to the same percentage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.displaysSyncSource == .ambientLight {
                Text("The Mac's light sensor is read once a second while this is on. The built-in display follows the room by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.displaysSyncSource != .off {
                ForEach(manager.displays.filter { $0.kind != .builtIn }) { display in
                    SyncRow(display: display)
                }
            }
        } header: {
            Text("Brightness Sync")
        }

        Section {
            Toggle("Turn Night Shift and True Tone off while a display shows HDR", isOn: $viewModel.settings.displaysPauseColorsInHDR)
            Text("Both tint the screen, which changes how HDR pictures look. The ones that were on come back when no display shows HDR, and when ScreenHelm quits.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("System Colors")
        }

        Section {
            if !connection.disconnected.isEmpty {
                ForEach(connection.disconnected) { entry in
                    HStack {
                        Label { Text(verbatim: entry.name) } icon: { Image(systemName: "display.trianglebadge.exclamationmark") }
                        Text("switched off").foregroundStyle(.secondary)
                        Spacer()
                        Button("Switch On") { connection.reconnect(entry.id) }
                    }
                }
            }
            Toggle("Switch a display off again after the Mac wakes", isOn: $viewModel.settings.displaysDisconnectAgainAfterWake)
            Text("macOS switches every display back on when it wakes.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.displaysAdvanced {
                Toggle("Switch the built-in display off while another is connected", isOn: $viewModel.settings.displaysAutoDisconnectBuiltIn)
            }
            ForEach(manager.displays.filter { $0.kind != .builtIn && $0.kind != .virtual }) { display in
                Toggle("Keep the Mac awake while \(manager.name(of: display)) is connected", isOn: Binding(
                    get: { settings.keepAwakeDisplays.contains(display.key) },
                    set: { on in
                        viewModel.settings.keepAwakeDisplays.removeAll { $0 == display.key }
                        if on { viewModel.settings.keepAwakeDisplays.append(display.key) }
                    }
                ))
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("A display is switched off from its own page. Everything ScreenHelm switched off comes back when ScreenHelm quits.")
        }

        EventActionsSection()

        if !sidecar.isEmpty {
            Section {
                Label("Experimental: not yet tried with an iPad.", systemImage: "flask").font(.callout).foregroundStyle(.secondary)
                ForEach(sidecar, id: \.name) { device in
                    HStack {
                        Label { Text(verbatim: device.name) } icon: { Image(systemName: "ipad.landscape") }
                        Spacer()
                        Button(device.connected ? "Disconnect" : "Connect") {
                            DisplayPrivateAPIs.setSidecar(device.name, connected: !device.connected)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sidecar = DisplayPrivateAPIs.sidecarDevices() }
                        }
                    }
                }
            } header: {
                Text("Sidecar")
            }
        }
    }

    /// Two connected displays of the same maker and model.
    private var identicalPair: (DisplayInfo, DisplayInfo)? {
        let displays = manager.displays.filter { $0.mirrorOf == nil }
        for (index, first) in displays.enumerated() {
            if let second = displays[(index + 1)...].first(where: {
                $0.identity.vendor == first.identity.vendor && $0.identity.product == first.identity.product
            }) { return (first, second) }
        }
        return nil
    }
}

private struct SyncRow: View {
    let display: DisplayInfo
    @Bindable private var viewModel = SettingsViewModel.shared
    private let manager = DisplayManager.shared

    private var profile: DisplayProfile { manager.profile(for: display) }

    var body: some View {
        Toggle(isOn: Binding(get: { !profile.syncExcluded }, set: { on in manager.updateProfile(of: display) { $0.syncExcluded = !on } })) {
            Text(verbatim: manager.name(of: display))
        }
        if !profile.syncExcluded {
            LabeledContent {
                HStack {
                    Slider(value: Binding(get: { profile.syncOffset }, set: { value in manager.updateProfile(of: display) { $0.syncOffset = value } }),
                           in: -0.5...0.5).labelsHidden()
                    Text(verbatim: String(format: "%+.0f%%", profile.syncOffset * 100)).monospacedDigit().frame(minWidth: 48, alignment: .trailing)
                }
            } label: {
                Text("Brighter or darker than the source")
            }
            if viewModel.settings.displaysSyncByNits {
                Stepper(value: Binding(get: { profile.peakNits }, set: { nits in manager.updateProfile(of: display) { $0.peakNits = nits } }),
                        in: 100...2000, step: 50) {
                    LabeledContent("Its brightest", value: "\(profile.peakNits) nits")
                }
            }
        }
    }
}

/// What to run when a display connects or goes, or the displays sleep or wake.
private struct EventActionsSection: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    private let manager = DisplayManager.shared

    var body: some View {
        Section {
            ForEach($viewModel.settings.displayEventActions) { $action in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("When", selection: $action.trigger) {
                            Text("A display connects").tag(DisplayEventAction.Trigger.connected)
                            Text("A display disconnects").tag(DisplayEventAction.Trigger.disconnected)
                            Text("The displays sleep").tag(DisplayEventAction.Trigger.sleep)
                            Text("The displays wake").tag(DisplayEventAction.Trigger.wake)
                        }
                        .labelsHidden()
                        if action.trigger == .connected || action.trigger == .disconnected {
                            Picker("Display", selection: $action.display) {
                                Text("Any display").tag("")
                                ForEach(manager.displays) { Text(verbatim: manager.name(of: $0)).tag($0.key) }
                                if !action.display.isEmpty, manager.display(key: action.display) == nil {
                                    Text("A display not connected now").tag(action.display)
                                }
                            }
                            .labelsHidden()
                        }
                        Spacer()
                        Button {
                            viewModel.settings.displayEventActions.removeAll { $0.id == action.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Picker("Do", selection: $action.kind) {
                            Text("Run the Shortcut").tag(DisplayEventAction.Kind.shortcut)
                            Text("Open").tag(DisplayEventAction.Kind.open)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if action.kind == .shortcut {
                            TextField("Shortcut name", text: $action.target, prompt: Text("The Shortcut's name"))
                                .labelsHidden()
                        } else {
                            Text(verbatim: action.target.isEmpty ? "" : (action.target as NSString).lastPathComponent).lineLimit(1)
                            Spacer()
                            Button("Choose…") { choose(for: action.id) }
                        }
                    }
                }
            }
            Button("Add an Action") {
                viewModel.settings.displayEventActions.append(DisplayEventAction(trigger: .connected, kind: .shortcut, target: ""))
            }
        } header: {
            Text("When Displays Change")
        } footer: {
            Text("Runs a Shortcut from the Shortcuts app, or opens an app or a file. Nothing else can be started from here.")
        }
    }

    private func choose(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let index = viewModel.settings.displayEventActions.firstIndex(where: { $0.id == id }) else { return }
        viewModel.settings.displayEventActions[index].target = url.path
    }
}

/// On a display's own tab: switching it off.
struct DisplayConnectionSection: View {
    let display: DisplayInfo
    private let connection = ConnectionController.shared

    var body: some View {
        Section {
            if let refusal = connection.refusal(for: display) {
                Label(refusal, systemImage: "info.circle").foregroundStyle(.secondary)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switch this display off")
                        Text("macOS stops using it, as if its cable were pulled. Switch it back on from the Arrangement page; it also returns after sleep and when ScreenHelm quits.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Switch Off") { connection.disconnect(display) }
                }
                if display.kind == .external || display.kind == .tv {
                    Label("Experimental: not yet tried on a real monitor.", systemImage: "flask").font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Connection")
        }
    }
}
