import ScreenHelmCore
import SwiftUI

/// What a monitor lets a Mac set over its cable: contrast, volume, input,
/// power and color gains, with the settings for monitors that need coaxing.
struct DDCSection: View {
    let display: DisplayInfo
    /// Shows every control without a monitor connected, to look at the layout.
    var assumeFound = false
    private let manager = DisplayManager.shared
    private let ddc = DDCController.shared
    @Bindable private var viewModel = SettingsViewModel.shared
    @State private var newName = ""
    @State private var newCode = ""
    @State private var newMaximum = ""
    @State private var confirmPowerOff = false
    @State private var renaming: DDCInput?
    @State private var inputName = ""

    private var profile: DisplayProfile { manager.profile(for: display) }
    private var found: Bool { assumeFound || ddc.available.contains(display.id) }

    var body: some View {
        Section {
            Label("Experimental: written from how other open-source tools talk to monitors, and not yet tried on a real one.",
                  systemImage: "flask")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Use DDC with this monitor", isOn: Binding(
                get: { profile.ddc.enabled },
                set: { on in ddc.updateSettings(of: display) { $0.enabled = on } }
            ))
            Text("Turn this off for a monitor that flickers or loses its signal when it is sent commands.")
                .font(.caption).foregroundStyle(.secondary)
            if !found {
                HStack {
                    Label("No DDC connection was found for this display. Docks, adapters and TVs often don't pass it on.",
                          systemImage: "cable.connector.slash").foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") { ddc.rediscover() }
                }
            }
        } header: {
            Text("Monitor Controls (DDC)")
        }

        if found && profile.ddc.enabled {
            Section {
                slider("Contrast", .contrast, symbol: "circle.lefthalf.filled")
                slider("Volume", .volume, symbol: "speaker.wave.2")
                Toggle("Mute", isOn: Binding(
                    get: { ddc.value(.mute, on: display) == DDCPacket.muteOn },
                    set: { ddc.set($0 ? DDCPacket.muteOn : DDCPacket.muteOff, for: .mute, on: display) }
                ))
                slider("Red", .redGain, symbol: "r.circle")
                slider("Green", .greenGain, symbol: "g.circle")
                slider("Blue", .blueGain, symbol: "b.circle")
            } header: {
                Text("Picture and Sound")
            } footer: {
                Text("A slider that does nothing means the monitor doesn't have that setting. Values are remembered here, since monitors are slow and unreliable at reporting them.")
            }

            Section {
                ForEach(DDCInput.common) { input in
                    HStack {
                        Text(verbatim: profile.inputNames[input.value] ?? input.standardName)
                        Spacer()
                        Button("Rename…") {
                            inputName = profile.inputNames[input.value] ?? ""
                            renaming = input
                        }
                        .buttonStyle(.borderless)
                        Button("Switch") { ddc.setInput(input, on: display) }
                    }
                }
                Toggle("This monitor needs LG's own input command", isOn: Binding(
                    get: { profile.ddc.lgInputCode },
                    set: { on in ddc.updateSettings(of: display) { $0.lgInputCode = on } }
                ))
            } header: {
                Text("Input")
            } footer: {
                Text("Switching to an input with nothing connected leaves the monitor without a picture until you switch back with its own buttons.")
            }
            .alert("Rename Input", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $inputName)
                Button("Save") {
                    if let input = renaming {
                        let name = inputName.trimmingCharacters(in: .whitespaces)
                        manager.updateProfile(of: display) { $0.inputNames[input.value] = name.isEmpty ? nil : name }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }

            Section {
                HStack {
                    Button("Standby") { ddc.set(DDCPacket.powerStandby, for: .power, on: display) }
                    Button("Wake") { ddc.set(DDCPacket.powerOn, for: .power, on: display) }
                    Spacer()
                    Button("Turn Off…", role: .destructive) { confirmPowerOff = true }
                }
            } header: {
                Text("Power")
            }
            .confirmationDialog("Turn this monitor off?", isPresented: $confirmPowerOff) {
                Button("Turn Off", role: .destructive) { ddc.set(DDCPacket.powerOff, for: .power, on: display) }
            } message: {
                Text("Many monitors stop listening once they are off and have to be turned on with their own button.")
            }

            if viewModel.settings.displaysAdvanced {
                Section {
                    ForEach(profile.customControls) { control in
                        LabeledContent {
                            HStack {
                                Slider(value: Binding(
                                    get: { Double(control.value) },
                                    set: { value in write(control, UInt16(value.rounded())) }
                                ), in: 0...Double(max(1, control.maximum))).labelsHidden()
                                Text(verbatim: "\(control.value)").monospacedDigit().frame(minWidth: 40, alignment: .trailing)
                                Button {
                                    manager.updateProfile(of: display) { $0.customControls.removeAll { $0.id == control.id } }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        } label: {
                            Text(verbatim: "\(control.name) (0x\(String(control.code, radix: 16, uppercase: true)))")
                        }
                    }
                    HStack {
                        TextField("Name", text: $newName, prompt: Text("Name")).labelsHidden()
                        TextField("Code", text: $newCode, prompt: Text(verbatim: "0x72")).labelsHidden().frame(width: 64)
                        TextField("Most", text: $newMaximum, prompt: Text(verbatim: "100")).labelsHidden().frame(width: 64)
                        Button("Add") { addControl() }
                            .disabled(CustomDDCControl.code(from: newCode) == nil || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Your Own Controls")
                } footer: {
                    Text("For settings ScreenHelm doesn't list, by their VCP code from the monitor's documentation. A wrong code can change something you can't easily change back; nothing is written to a code until you move its slider.")
                }
            }

            Section {
                Stepper(value: timing(\.writeDelay), in: 5...100, step: 5) {
                    LabeledContent("Wait before each command", value: "\(profile.ddc.writeDelay) ms")
                }
                Stepper(value: timing(\.writeCount), in: 1...4) {
                    LabeledContent("Send each command", value: "\(profile.ddc.writeCount)×")
                }
                Stepper(value: timing(\.readDelay), in: 10...200, step: 10) {
                    LabeledContent("Wait for an answer", value: "\(profile.ddc.readDelay) ms")
                }
                Stepper(value: timing(\.readRetries), in: 0...8) {
                    LabeledContent("Ask again up to", value: "\(profile.ddc.readRetries)×")
                }
                Toggle("Accept answers whose checksum is wrong", isOn: Binding(
                    get: { profile.ddc.ignoreReadChecksum },
                    set: { on in ddc.updateSettings(of: display) { $0.ignoreReadChecksum = on } }
                ))
            } header: {
                Text("Timing")
            } footer: {
                Text("Most monitors work with these as they are. Some need 50 ms before each command.")
            }
        }
    }

    private func slider(_ title: LocalizedStringKey, _ code: VCPCode, symbol: String) -> some View {
        LabeledContent {
            Slider(value: Binding(
                get: { ddc.fraction(code, on: display) ?? 0.5 },
                set: { ddc.setFraction($0, for: code, on: display) }
            ), in: 0...1)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func addControl() {
        guard let code = CustomDDCControl.code(from: newCode) else { return }
        let control = CustomDDCControl(name: newName.trimmingCharacters(in: .whitespaces), code: code, maximum: UInt16(newMaximum) ?? 100)
        manager.updateProfile(of: display) { $0.customControls.append(control) }
        newName = ""
        newCode = ""
        newMaximum = ""
    }

    /// Any code may be written here: the user named it, with the risky settings shown.
    private func write(_ control: CustomDDCControl, _ value: UInt16) {
        manager.updateProfile(of: display) { profile in
            if let index = profile.customControls.firstIndex(where: { $0.id == control.id }) { profile.customControls[index].value = value }
        }
        let id = display.id
        Task { await DDCService.shared.write(control.code, value: value, to: id, allowingAnyCode: true) }
    }

    private func timing(_ keyPath: WritableKeyPath<DDCSettings, Int>) -> Binding<Int> {
        Binding(get: { profile.ddc[keyPath: keyPath] }, set: { value in ddc.updateSettings(of: display) { $0[keyPath: keyPath] = value } })
    }
}
