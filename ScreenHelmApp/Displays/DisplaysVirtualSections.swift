import ScreenHelmCore
import SwiftUI

/// The Virtual Screens tab: the screens made, each to connect, change or
/// delete, and new ones from a template or in the shape of a real display.
struct VirtualScreensSections: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    private let controller = VirtualScreenController.shared
    private let manager = DisplayManager.shared

    var body: some View {
        Section {
            if !controller.isAvailable {
                Label("This version of macOS doesn't offer the call this needs.", systemImage: "info.circle").foregroundStyle(.secondary)
            } else {
                Text("A virtual screen is a display with nothing plugged in: somewhere to mirror to, to share in a call, or to show in a picture-in-picture window. It lasts while ScreenHelm runs. Protected video doesn't play on one.")
                    .font(.caption).foregroundStyle(.secondary)
                Menu("New Virtual Screen") {
                    ForEach(VirtualScreen.templates) { template in
                        Button {
                            controller.add(name: String(localized: "Virtual Screen \(controller.screens.count + 1)", bundle: AppLocale.bundle),
                                           pixelWidth: template.pixelWidth, pixelHeight: template.pixelHeight)
                        } label: {
                            Text(verbatim: template.id)
                        }
                    }
                    let real = manager.displays.filter { $0.kind != .virtual }
                    if !real.isEmpty {
                        Divider()
                        ForEach(real) { display in
                            Button("In the Shape of \(manager.name(of: display))") { addMatching(display) }
                        }
                    }
                }
                .fixedSize()
                Toggle("Make one when no display is connected", isOn: $viewModel.settings.displaysHeadlessScreen)
                Text("For a Mac used without a monitor: screen sharing then has a desktop of a proper size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Virtual Screens")
        }

        ForEach(controller.screens) { screen in
            VirtualScreenSection(screen: screen)
        }
    }

    private func addMatching(_ display: DisplayInfo) {
        guard let native = ModeController.shared.modes(of: display.id).first(where: \.isNative) else { return }
        let size = VirtualScreen.matching(width: native.pixelWidth, height: native.pixelHeight, longSide: 3840)
        controller.add(name: String(localized: "Like \(manager.name(of: display))", bundle: AppLocale.bundle),
                       pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight, matchedDisplay: display.key)
    }
}

private struct VirtualScreenSection: View {
    let screen: VirtualScreen
    private let controller = VirtualScreenController.shared
    @State private var name = ""
    @State private var width = ""
    @State private var height = ""
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Toggle("Connected", isOn: Binding(get: { controller.connected[screen.id] != nil }, set: { controller.setConnected($0, screen.id) }))
            LabeledContent("Name") {
                TextField("Name", text: $name).labelsHidden().multilineTextAlignment(.trailing)
                    .onSubmit { change { $0.name = name } }
            }
            LabeledContent("Size in pixels") {
                HStack(spacing: 4) {
                    TextField("Width", text: $width).labelsHidden().frame(width: 64).multilineTextAlignment(.trailing).onSubmit { applySize() }
                    Text(verbatim: "×")
                    TextField("Height", text: $height).labelsHidden().frame(width: 64).multilineTextAlignment(.trailing).onSubmit { applySize() }
                }
            }
            Toggle("HiDPI", isOn: Binding(get: { screen.hiDPI }, set: { on in change { $0.hiDPI = on } }))
            LabeledContent("Refresh rates") {
                HStack(spacing: 6) {
                    ForEach([60, 120, 144, 240], id: \.self) { rate in
                        Toggle(isOn: Binding(
                            get: { screen.refreshRates.contains(rate) },
                            set: { on in
                                change { screen in
                                    screen.refreshRates.removeAll { $0 == rate }
                                    if on { screen.refreshRates.append(rate) }
                                    if screen.refreshRates.isEmpty { screen.refreshRates = [60] }
                                }
                            }
                        )) {
                            Text(verbatim: "\(rate)")
                        }
                        .toggleStyle(.button)
                    }
                }
            }
            Toggle("HDR", isOn: Binding(get: { screen.hdr }, set: { on in change { $0.hdr = on } }))
            if screen.hdr {
                Label("Experimental: macOS is told the screen is HDR, with no way here to check that it took it.", systemImage: "flask")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if let display = controller.connected[screen.id] {
                    Text("Connected as display \(String(display)). Its resolution and place are set like any other display's.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
        } header: {
            Text(verbatim: screen.name)
        }
        .onAppear { load() }
        .onChange(of: screen) { _, _ in load() }
        .confirmationDialog("Delete this virtual screen?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { controller.delete(screen.id) }
        }
    }

    private func load() {
        name = screen.name
        width = String(screen.pixelWidth)
        height = String(screen.pixelHeight)
    }

    private func change(_ edit: (inout VirtualScreen) -> Void) {
        var updated = screen
        edit(&updated)
        controller.update(updated)
        load()
    }

    private func applySize() {
        guard let width = Int(width), let height = Int(height) else { return load() }
        change {
            $0.pixelWidth = width
            $0.pixelHeight = height
        }
    }
}

/// On a real display's tab: more sharp resolutions through a system file.
struct ScalingSection: View {
    let display: DisplayInfo
    @State private var status = OverrideInstaller.Status(installed: false, byScreenHelm: false, sizes: [])
    @State private var extraText = ""
    @State private var message: LocalizedStringKey?

    private var extra: [ScaledResolutions.Size] {
        extraText.split(whereSeparator: { ",; \n".contains($0) }).compactMap { part in
            let numbers = part.lowercased().split(whereSeparator: { "x×".contains($0) }).compactMap { Int($0) }
            return numbers.count == 2 && numbers[0] >= 320 && numbers[1] >= 200 ? ScaledResolutions.Size(width: numbers[0], height: numbers[1]) : nil
        }
    }

    var body: some View {
        let sizes = OverrideInstaller.sizes(for: display, extra: extra)
        Section {
            Text("macOS offers a handful of sharp resolutions for a display. ScreenHelm can add many more in between, in the display's own shape, for a finer choice between larger text and more space. They are added to a system file for this model of display, so they stay after ScreenHelm is gone, until removed here.")
                .font(.caption).foregroundStyle(.secondary)
            Label("Experimental: the file follows Apple's own for this Mac's display, but installing it has not been tried yet.", systemImage: "flask")
                .font(.callout).foregroundStyle(.secondary)
            if let first = sizes.first, let last = sizes.last {
                // As text, so the numbers aren't given thousands separators.
                let smallest = "\(first.width) × \(first.height)", largest = "\(last.width) × \(last.height)"
                LabeledContent("To add") { Text("\(sizes.count) sizes, from \(smallest) to \(largest)") }
            }
            LabeledContent("Also add") {
                TextField("Sizes", text: $extraText, prompt: Text(verbatim: "1600x1000, 2048x1280")).labelsHidden().multilineTextAlignment(.trailing)
            }
            HStack {
                if status.byScreenHelm {
                    Label("Installed: \(status.sizes.count) sizes in the file.", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                } else if status.installed {
                    Label("Another tool's file is installed for this display. ScreenHelm adds to it and can put it back.", systemImage: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if status.byScreenHelm {
                    Button("Remove…") {
                        message = OverrideInstaller.remove(for: display) ? "Removed. The resolutions go after a restart." : "Nothing was changed."
                        status = OverrideInstaller.status(for: display)
                    }
                }
                Button(status.byScreenHelm ? "Install Again…" : "Install…") {
                    message = OverrideInstaller.install(sizes, for: display)
                        ? (display.kind == .builtIn ? "Installed. Restart the Mac to see the new resolutions."
                                                    : "Installed. Unplug the display and plug it back in, or restart the Mac, to see the new resolutions.")
                        : "Nothing was installed."
                    status = OverrideInstaller.status(for: display)
                }
                .disabled(sizes.isEmpty)
            }
            if let message { Text(message).font(.callout) }
        } header: {
            Text("More Resolutions")
        } footer: {
            Text("macOS asks for an administrator's password each time. The file applies to every display of this model and every user of this Mac. A resolution can't be larger than the panel itself.")
        }
        .onAppear { status = OverrideInstaller.status(for: display) }
        .onChange(of: display.id) { _, _ in status = OverrideInstaller.status(for: display) }
    }
}

/// A slider through the sizes of the display's current shape.
struct ResolutionSlider: View {
    let display: DisplayInfo
    private let modes = ModeController.shared
    @State private var position: Double?

    var body: some View {
        let all = modes.modes(of: display.id)
        if let current = modes.current(of: display.id) {
            let steps = DisplayModes.sliderResolutions(like: current, in: all)
            if steps.count > 2, let index = steps.firstIndex(of: current.resolution) {
                let shown = position ?? Double(index)
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { shown }, set: { position = $0 }), in: 0...Double(steps.count - 1), step: 1) { editing in
                        // Applied when the slider is let go: every stop on the way would blank the screen.
                        guard !editing, let position else { return }
                        self.position = nil
                        let target = steps[min(steps.count - 1, max(0, Int(position.rounded())))]
                        if target != current.resolution { modes.setResolution(target, on: display) }
                    }
                    .labelsHidden()
                    Image(systemName: "rectangle.expand.vertical").foregroundStyle(.secondary)
                    Text(verbatim: steps[min(steps.count - 1, max(0, Int(shown.rounded())))].label).monospacedDigit()
                        .frame(minWidth: 96, alignment: .trailing)
                }
            }
        }
    }
}
