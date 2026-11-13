import ScreenHelmCore
import SwiftUI
import UniformTypeIdentifiers

/// The Automation page: display commands from outside ScreenHelm, the
/// groups they can address, and moving the settings to another Mac.
struct AutomationSections: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    private let manager = DisplayManager.shared
    @State private var token = ""
    @State private var showToken = false
    @State private var message: LocalizedStringKey?

    private var settings: AppSettings { viewModel.settings }

    var body: some View {
        Section {
            Text("The Shortcuts app has ScreenHelm's display actions under “ScreenHelm”: brightness, resolution, switching settings on and off, inputs, and more. They need nothing turned on here.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Take display commands from the command line and from links", isOn: $viewModel.settings.displaysAutomation)
            if settings.displaysAutomation {
                example("/Applications/ScreenHelm.app/Contents/MacOS/ScreenHelm display set display=main brightness=60%")
                example("open \"screenhelm://display/toggle?display=main&hdr\"")
                Text("Commands: get, set, toggle, perform. A display is chosen with display=main, pointer, builtin or all, with name=…, or with group=….")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Take them over HTTP on this Mac", isOn: $viewModel.settings.displaysHTTPEnabled)
            if settings.displaysHTTPEnabled {
                Stepper(value: $viewModel.settings.displaysHTTPPort, in: 1024...65535) {
                    LabeledContent("Port", value: String(settings.displaysHTTPPort))
                }
                LabeledContent("Token") {
                    HStack {
                        Text(verbatim: showToken ? token : String(repeating: "•", count: 16)).monospaced().lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        }
                        Button("New") { token = AutomationToken.renew() }
                    }
                }
                example("curl -H \"Authorization: Bearer <token>\" \"http://127.0.0.1:\(settings.displaysHTTPPort)/display/get\"")
                Text("Only programs on this Mac can reach it, and each request needs the token. The token is kept in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("A link can come from a web page or a document, which is why links are off until you turn them on. A change that could leave a display unusable still asks to be kept.")
        }
        .onAppear { if settings.displaysHTTPEnabled { token = AutomationToken.current() } }
        .onChange(of: settings.displaysHTTPEnabled) { _, on in if on { token = AutomationToken.current() } }

        Section {
            ForEach($viewModel.settings.displayGroups) { $group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $group.name).labelsHidden()
                        Button {
                            viewModel.settings.displayGroups.removeAll { $0.id == group.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        ForEach(manager.displays) { display in
                            Toggle(isOn: Binding(
                                get: { group.displays.contains(display.key) },
                                set: { on in
                                    group.displays.removeAll { $0 == display.key }
                                    if on { group.displays.append(display.key) }
                                }
                            )) {
                                Text(verbatim: manager.name(of: display))
                            }
                            .toggleStyle(.button)
                        }
                    }
                    GroupBrightnessSlider(group: group)
                }
            }
            Button("Add a Group") {
                viewModel.settings.displayGroups.append(DisplayGroup(name: String(localized: "Group \(settings.displayGroups.count + 1)", bundle: AppLocale.bundle)))
            }
        } header: {
            Text("Display Groups")
        } footer: {
            Text("Displays to change together: one slider here, and group=… in a command.")
        }

        Section {
            HStack {
                Button("Export Display Settings…") { export() }
                Button("Import…") { importSettings() }
                Spacer()
                Button("Save a Report…") { saveReport() }
            }
            if let message { Text(message).font(.callout) }
        } header: {
            Text("Settings and Diagnostics")
        } footer: {
            Text("The export holds what is set for each display, the kept arrangements, virtual screens and pictures. The report describes the displays and what they answered, for when something doesn't work; serial numbers are left out.")
        }
    }

    private func example(_ text: String) -> some View {
        Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ScreenHelm Displays.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = (try? DisplaySettingsArchive.export().write(to: url)) != nil ? "Exported." : "The file could not be written."
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        message = DisplaySettingsArchive.import(data) ? "Imported. Quit and reopen ScreenHelm to use everything in it." : "That file isn't an ScreenHelm display export."
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ScreenHelm Displays Report.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = (try? DisplayDiagnostics.report().write(to: url, atomically: true, encoding: .utf8)) != nil ? "Saved." : "The file could not be written."
    }
}

/// One slider for every display of a group.
private struct GroupBrightnessSlider: View {
    let group: DisplayGroup
    private let brightness = BrightnessController.shared

    var body: some View {
        let displays = DisplayManager.shared.displays.filter { group.displays.contains($0.key) }
        if !displays.isEmpty {
            let value = displays.map { min(1, brightness.value(for: $0)) }.reduce(0, +) / Double(displays.count)
            HStack(spacing: 10) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(get: { value }, set: { new in for display in displays { brightness.set(new, for: display) } }), in: 0...1)
                    .labelsHidden()
                Image(systemName: "sun.max").foregroundStyle(.secondary)
            }
        }
    }
}
