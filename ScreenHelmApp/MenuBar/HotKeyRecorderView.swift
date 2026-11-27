import AppKit
import SwiftUI

/// A Settings row: shows the shortcut, and while recording takes the next
/// key press (with ⌘/⌥/⌃) as the new one, as in the sibling apps. Every
/// shortcut can be cleared.
struct HotKeyRecorderView: View {
    let title: Text
    let key: String
    let manager: HotKeyManager
    @State private var recording = false
    @State private var monitor: Any?
    /// The name of the ScreenHelm shortcut that already uses the keys pressed.
    @State private var takenBy: String?

    init(title: LocalizedStringKey, key: String, manager: HotKeyManager) {
        self.init(title: Text(title), key: key, manager: manager)
    }

    /// For a title already translated, such as a display action's.
    init(title: Text, key: String, manager: HotKeyManager) {
        self.title = title
        self.key = key
        self.manager = manager
    }

    private var current: HotKey? { manager.hotKey(key) }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Button {
                        recording ? stop() : start()
                    } label: {
                        if recording {
                            Text("Press keys…")
                        } else if let current {
                            Text(verbatim: current.displayString)
                        } else {
                            Text("None").foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 110)
                    if recording {
                        Button("Cancel") { stop() }
                    } else if current != nil {
                        Button {
                            manager.update(key, to: nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove the shortcut"))
                    }
                }
                if let takenBy {
                    Label("“\(takenBy)” already uses this shortcut. Choose a different one.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                } else if manager.failed(key) {
                    Label("Another app already uses this shortcut, so it does nothing here. Choose a different one.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        } label: {
            title
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        manager.isRecording = true
        takenBy = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in stop() }
                return nil
            }
            if let hotKey = HotKey(event: event) {
                Task { @MainActor in
                    record(hotKey)
                    stop()
                }
                return nil
            }
            return event
        }
    }

    private func record(_ hotKey: HotKey) {
        if let owner = manager.owner(of: hotKey), owner != key {
            takenBy = DisplayShortcuts.title(forKey: owner)
            return
        }
        manager.update(key, to: hotKey)
    }

    private func stop() {
        if recording { manager.isRecording = false }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
