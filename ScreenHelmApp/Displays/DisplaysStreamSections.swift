import ScreenHelmCore
import SwiftUI
import UniformTypeIdentifiers

/// The Picture in Picture tab: live copies of displays and windows, shown
/// in a floating window or across another display.
struct StreamsSections: View {
    private let controller = StreamController.shared
    private let manager = DisplayManager.shared
    private let permissions = Permissions.shared

    var body: some View {
        Section {
            Text("A live copy of a display or a window: in a small window that floats over everything, or across another display. Turned, mirrored, cropped or filtered on the way if you like. The picture is never saved.")
                .font(.caption).foregroundStyle(.secondary)
            if !permissions.screenRecording {
                HStack {
                    Label("This needs the Screen Recording permission.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Allow…") { permissions.requestScreenRecording() }
                }
            }
            Menu("New Picture") {
                ForEach(manager.displays) { display in
                    Button("Show \(manager.name(of: display))") {
                        controller.add(source: .display(display.key), name: manager.name(of: display))
                    }
                }
                Divider()
                ForEach(Self.appsWithWindows(), id: \.bundleID) { app in
                    Button("Show a Window of \(app.name)") { controller.add(source: .window(bundleID: app.bundleID, title: ""), name: app.name) }
                }
            }
            .fixedSize()
        } header: {
            Text("Picture in Picture")
        } footer: {
            Text("macOS asks again for the Screen Recording permission about once a month; that can't be turned off.")
        }

        ForEach(controller.configs) { config in
            StreamSection(config: config)
        }
    }

    /// Apps with a Dock icon, the ones that have windows to show.
    static func appsWithWindows() -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }
}

private struct StreamSection: View {
    let config: StreamConfig
    private let controller = StreamController.shared
    private let manager = DisplayManager.shared
    @State private var name = ""
    @State private var confirmDelete = false

    private var isRunning: Bool { controller.running.contains(config.id) }

    var body: some View {
        Section {
            Toggle("Showing", isOn: Binding(get: { isRunning }, set: { _ in controller.toggle(config.id) }))
            if let failure = controller.failure[config.id] {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            LabeledContent("Name") {
                TextField("Name", text: $name).labelsHidden().multilineTextAlignment(.trailing).onSubmit { change { $0.name = name } }
            }
            LabeledContent("Shows") { Text(verbatim: sourceName) }
            Picker("In", selection: Binding(get: { config.target }, set: { target in change { $0.target = target } })) {
                Text("A floating window").tag(StreamConfig.Target.floatingWindow)
                ForEach(manager.displays) { display in
                    Text("All of \(manager.name(of: display))").tag(StreamConfig.Target.display(display.key))
                }
            }
            if config.target != .floatingWindow {
                Picker("Fit", selection: Binding(get: { config.scaling }, set: { scaling in change { $0.scaling = scaling } })) {
                    Text("Whole picture, with bars").tag(StreamConfig.Scaling.fit)
                    Text("Fill, cutting the edges").tag(StreamConfig.Scaling.fill)
                    Text("Stretch").tag(StreamConfig.Scaling.stretch)
                }
            }
            Picker("Turn", selection: Binding(get: { config.rotation }, set: { degrees in change { $0.rotation = degrees } })) {
                ForEach([0, 90, 180, 270], id: \.self) { Text(verbatim: "\($0)°").tag($0) }
            }
            Toggle("Mirror left to right", isOn: Binding(get: { config.flipHorizontal }, set: { on in change { $0.flipHorizontal = on } }))
            Toggle("Flip upside down", isOn: Binding(get: { config.flipVertical }, set: { on in change { $0.flipVertical = on } }))
            if case .display(let key) = config.source, let display = manager.display(key: key) {
                HStack {
                    Button("Choose the Part on Screen…") {
                        let id = config.id
                        AreaPicker.pick(on: display.id) { crop in
                            // The stream as it is when the area is chosen: edits made meanwhile stay.
                            guard let crop, var current = controller.configs.first(where: { $0.id == id }) else { return }
                            current.crop = crop
                            controller.update(current)
                        }
                    }
                    if config.crop != .whole {
                        Button("Show All") { change { $0.crop = .whole } }
                    }
                }
            }
            crop("Cut from the left", \.x0, inverted: false)
            crop("Cut from the right", \.x1, inverted: true)
            crop("Cut from the top", \.y0, inverted: false)
            crop("Cut from the bottom", \.y1, inverted: true)
            Picker("Frames per second", selection: Binding(get: { config.framesPerSecond }, set: { fps in change { $0.framesPerSecond = fps } })) {
                ForEach(StreamConfig.allowedFrameRates, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            Toggle("Show the pointer", isOn: Binding(get: { config.showsCursor }, set: { on in change { $0.showsCursor = on } }))
            if config.target != .floatingWindow {
                Toggle("Hide the pointer while it is over the display this covers", isOn: Binding(
                    get: { config.hidesPointerOnTarget }, set: { on in change { $0.hidesPointerOnTarget = on } }))
            }
            if #available(macOS 15.0, *) {
                Toggle("Keep HDR highlights", isOn: Binding(get: { config.hdr }, set: { on in change { $0.hdr = on } }))
            }
            if config.target == .floatingWindow {
                Toggle("Clicks go through the picture", isOn: Binding(get: { config.clickThrough }, set: { on in change { $0.clickThrough = on } }))
            }
            filters
            HStack {
                Spacer()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
        } header: {
            Text(verbatim: config.name)
        }
        .onAppear { name = config.name }
        .onChange(of: config.name) { _, new in name = new }
        .confirmationDialog("Delete this picture?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { controller.delete(config.id) }
        }
    }

    @ViewBuilder
    private var filters: some View {
        Toggle("Black and white", isOn: Binding(get: { config.filters.monochrome }, set: { on in change { $0.filters.monochrome = on } }))
        Toggle("Invert colors", isOn: Binding(get: { config.filters.invert }, set: { on in change { $0.filters.invert = on } }))
        slider("Saturation", \.saturation, 0...2) { "\(Int(($0 * 100).rounded()))%" }
        slider("Hue", \.hue, -180...180) { "\(Int($0.rounded()))°" }
        slider("Blur", \.blur, 0...30) { String(format: "%.0f", $0) }
        slider("Sharpen", \.sharpen, 0...2) { String(format: "%.1f", $0) }
        LabeledContent("Color lookup table") {
            HStack {
                if let path = config.filters.lutPath {
                    Text(verbatim: (path as NSString).lastPathComponent).lineLimit(1)
                    Button("Clear") { change { $0.filters.lutPath = nil } }
                }
                Button("Choose…") { chooseLUT() }
            }
        }
    }

    private var sourceName: String {
        switch config.source {
        case .display(let key): manager.display(key: key).map(manager.name) ?? String(localized: "A display not connected now", bundle: AppLocale.bundle)
        case .window(let bundleID, _):
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
        }
    }

    private func change(_ edit: (inout StreamConfig) -> Void) {
        var updated = config
        edit(&updated)
        controller.update(updated)
    }

    /// A crop edge as "how much is cut away", 0 to 90 percent.
    private func crop(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<UnitRect, Double>, inverted: Bool) -> some View {
        let cut = inverted ? 1 - config.crop[keyPath: keyPath] : config.crop[keyPath: keyPath]
        return LabeledContent {
            HStack {
                Slider(value: Binding(get: { cut }, set: { value in change { $0.crop[keyPath: keyPath] = inverted ? 1 - value : value } }), in: 0...0.9)
                    .labelsHidden()
                Text(verbatim: "\(Int((cut * 100).rounded()))%").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<StreamFilters, Double>, _ range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        LabeledContent {
            HStack {
                Slider(value: Binding(get: { config.filters[keyPath: keyPath] }, set: { value in change { $0.filters[keyPath: keyPath] = value } }),
                       in: range).labelsHidden()
                Text(verbatim: format(config.filters[keyPath: keyPath])).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }

    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { $0.filters.lutPath = url.path }
    }
}
