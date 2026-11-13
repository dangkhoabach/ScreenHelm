import ScreenHelmCore
import SwiftUI

/// XDR boost for an Apple XDR display: on or off, how bright it may go,
/// and when it turns itself off.
struct XDRSection: View {
    let display: DisplayInfo
    @Bindable private var viewModel = SettingsViewModel.shared
    private let manager = DisplayManager.shared
    private let xdr = XDRController.shared

    private var profile: DisplayProfile { manager.profile(for: display) }

    var body: some View {
        Section {
            Toggle("Let the brightness slider go past 100%", isOn: Binding(get: { profile.xdrBoost }, set: { xdr.setEnabled($0, for: display) }))
            Text("This display can show HDR highlights much brighter than its usual white. With this on, the slider's second half uses that range for everything, which helps in sunlight. HDR video loses its highlights meanwhile, and the battery drains faster.")
                .font(.caption).foregroundStyle(.secondary)
            if profile.xdrBoost {
                Stepper(value: Binding(get: { profile.xdrMaxNits }, set: { nits in manager.updateProfile(of: display) { $0.xdrMaxNits = nits } }),
                        in: 700...1600, step: 100) {
                    LabeledContent("Brightest", value: "\(profile.xdrMaxNits) nits")
                }
                Text("The panel holds about 1000 nits over the whole screen and reaches 1600 only for a short while.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $viewModel.settings.displaysXDRBatteryMinimum, in: 0...80, step: 5) {
                    LabeledContent("Turn off on battery at") {
                        viewModel.settings.displaysXDRBatteryMinimum == 0 ? Text("Never") : Text(verbatim: "\(viewModel.settings.displaysXDRBatteryMinimum)%")
                    }
                }
                Toggle("Turn Night Shift off meanwhile", isOn: $viewModel.settings.displaysXDRPauseNightShift)
                if let reason = xdr.stopReason {
                    Label(reason.message, systemImage: "bolt.slash").foregroundStyle(.orange)
                }
            }
        } header: {
            Text("XDR Brightness")
        }
    }
}

extension XDRBoost.StopReason {
    var message: LocalizedStringKey {
        switch self {
        case .lowBattery: "Turned off because the battery is low."
        case .heat: "Turned off because the Mac is running hot."
        case .noHeadroom: "Turned off because macOS took the display's extra range away."
        }
    }
}

/// Changes to the picture made in the display's color table.
struct PictureSection: View {
    let display: DisplayInfo
    private let manager = DisplayManager.shared
    private let brightness = BrightnessController.shared

    private var picture: PictureAdjustment { manager.profile(for: display).picture }

    var body: some View {
        Section {
            if brightness.softwareMethod(for: display) == .overlay {
                Label("These use the color table, which isn't used for this display. See Safety below, and the display's color profile.",
                      systemImage: "info.circle").foregroundStyle(.secondary)
            } else {
                slider("Contrast", \.contrast, -0.6...0.6, neutral: 0) { String(format: "%+.0f%%", $0 * 100) }
                slider("Gamma", \.gamma, 0.5...2, neutral: 1) { String(format: "%.2f", $0) }
                slider("Color temperature", \.temperature, 2700...9300, neutral: 6500) { "\(Int(($0 / 100).rounded()) * 100) K" }
                slider("Red", \.redGain, 0.3...1, neutral: 1) { "\(Int(($0 * 100).rounded()))%" }
                slider("Green", \.greenGain, 0.3...1, neutral: 1) { "\(Int(($0 * 100).rounded()))%" }
                slider("Blue", \.blueGain, 0.3...1, neutral: 1) { "\(Int(($0 * 100).rounded()))%" }
                Toggle("Invert colors", isOn: Binding(get: { picture.invert }, set: { on in change { $0.invert = on } }))
                Picker("Color steps", selection: Binding(get: { picture.quantization }, set: { steps in change { $0.quantization = steps } })) {
                    Text("All").tag(0)
                    ForEach([64, 32, 16, 8, 4, 2], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                Button("Reset to Default") { change { $0 = $0.withoutPictureChanges } }
                    .disabled(picture.withoutBrightnessAndBoost.isNeutral)
            }
        } header: {
            Text("Picture")
        } footer: {
            Text("Applied by ScreenHelm while it runs, and dropped by the shortcut under Safety. Screenshots don't show them.")
        }
    }

    private func change(_ edit: (inout PictureAdjustment) -> Void) {
        var updated = picture
        edit(&updated)
        brightness.setPicture(updated, for: display)
    }

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<PictureAdjustment, Double>, _ range: ClosedRange<Double>,
                        neutral: Double, format: @escaping (Double) -> String) -> some View {
        LabeledContent {
            HStack {
                Slider(value: Binding(get: { picture[keyPath: keyPath] }, set: { value in change { $0[keyPath: keyPath] = value } }), in: range)
                    .labelsHidden()
                Text(verbatim: format(picture[keyPath: keyPath])).monospacedDigit().frame(minWidth: 58, alignment: .trailing)
                    .foregroundStyle(picture[keyPath: keyPath] == neutral ? .secondary : .primary)
            }
        } label: {
            Text(title)
        }
    }
}
