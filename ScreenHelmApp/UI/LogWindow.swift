import AppKit
import OSLog
import SwiftUI

/// One line of ScreenHelm's own log.
struct LogLine: Identifiable, Sendable, Equatable {
    let id: Int
    let date: Date
    let level: OSLogEntryLog.Level
    let category: String
    let message: String

    var isProblem: Bool { level == .error || level == .fault }

    var text: String {
        "\(date.formatted(.iso8601.time(includingFractionalSeconds: true)))  \(category)  \(message)"
    }
}

/// Reads this process's log entries off the main thread: the first read
/// of the store takes seconds.
actor LogReader {
    static let subsystem = "com.dangkhoabach.screenhelm"
    private var store: OSLogStore?
    private var nextID = 0

    /// The entries after `date`, oldest first.
    func entries(after date: Date) -> [LogLine] {
        do {
            if self.store == nil { self.store = try OSLogStore(scope: .currentProcessIdentifier) }
            guard let store else { return [] }
            let entries = try store.getEntries(at: store.position(date: date), matching: NSPredicate(format: "subsystem == %@", Self.subsystem))
            var lines: [LogLine] = []
            for case let entry as OSLogEntryLog in entries where entry.date > date {
                lines.append(LogLine(id: nextID, date: entry.date, level: entry.level, category: entry.category, message: entry.composedMessage))
                nextID += 1
            }
            return lines
        } catch {
            return []
        }
    }
}

@MainActor
@Observable
final class LogModel {
    static let shared = LogModel()
    /// Older lines are dropped past this many.
    static let limit = 2000

    private(set) var lines: [LogLine] = []
    private(set) var isReading = false
    var search = ""
    var problemsOnly = false

    @ObservationIgnored private let reader = LogReader()
    @ObservationIgnored private var lastDate = Date.distantPast
    @ObservationIgnored private var timer: Timer?

    var shown: [LogLine] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return lines.filter { (!problemsOnly || $0.isProblem) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
    }

    /// Reads now and every two seconds until `stop`.
    func start() {
        guard timer == nil else { return }
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { LogModel.shared.read() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Hides what is there now; new lines still come in.
    func clear() {
        lines = []
    }

    func copyShown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown.map(\.text).joined(separator: "\n"), forType: .string)
    }

    private func read() {
        guard !isReading else { return }
        isReading = true
        let after = lastDate
        Task {
            let new = await reader.entries(after: after)
            isReading = false
            guard !new.isEmpty else { return }
            lastDate = new.last?.date ?? lastDate
            lines.append(contentsOf: new)
            if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        }
    }
}

struct LogView: View {
    @Bindable private var model = LogModel.shared
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $model.search, prompt: Text("Find in the log"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Problems only", isOn: $model.problemsOnly)
                    .toggleStyle(.checkbox)
                Spacer()
                if model.isReading && model.lines.isEmpty { ProgressView().controlSize(.small) }
                Button("Copy") { model.copyShown() }
                Button("Clear") { model.clear() }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(model.shown) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: line.date.formatted(.dateTime.hour().minute().second()))
                            .foregroundStyle(.secondary)
                        Text(verbatim: line.category)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(verbatim: line.message)
                            .foregroundStyle(line.isProblem ? Color.red : Color.primary)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(line.id)
                }
                .overlay {
                    if model.shown.isEmpty && !model.isReading {
                        Text("Nothing logged yet.").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: model.lines.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Text("What ScreenHelm wrote since it started. Private details show as <private>.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minWidth: 560, minHeight: 320)
        .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
    }
}

/// The log in a window of its own, opened from the Automation page.
@MainActor
final class LogWindowController: NSObject, NSWindowDelegate {
    static let shared = LogWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = String(localized: "ScreenHelm Log", bundle: AppLocale.bundle)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LogView())
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("ScreenHelmLog")
            self.window = window
        }
        LogModel.shared.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        LogModel.shared.stop()
    }
}
