import AppKit
import ScreenHelmCore
import Observation
import SwiftUI
import os

/// Switching a display off without unplugging it, and back on.
///
/// A display that is off is gone from every list macOS gives: only its
/// number brings it back. That number is written down before the display
/// is switched off, and everything ScreenHelm switched off comes back when
/// ScreenHelm quits, when it next starts, and, should it be killed, through
/// a second copy of itself that only waits for that.
@MainActor
@Observable
final class ConnectionController {
    static let shared = ConnectionController()

    struct Disconnected: Identifiable, Equatable {
        var id: CGDirectDisplayID
        var key: String
        var name: String
        var kind: DisplayKind
        var journalID: Int64?
    }

    private(set) var disconnected: [Disconnected] = []

    @ObservationIgnored private var started = false
    @ObservationIgnored private var watcher: Process?
    @ObservationIgnored private var knownKeys: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }
    private var store: DisplayStore? { AppDatabase.shared.map { DisplayStore(dbQueue: $0.dbQueue) } }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // Displays left off by a run that ended badly come back first.
        for entry in (try? store?.journal(.disconnected)) ?? [] {
            if let id = UInt32(entry.detail) { _ = Self.setEnabled(true, id) }
            if let journalID = entry.id { try? store?.clearJournal(id: journalID) }
        }
        knownKeys = Set(DisplayManager.shared.displays.map(\.key))
        DisplayManager.shared.onChange.append { [weak self] woke in self?.displaysChanged(woke: woke) }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DisplayEvents.run(.sleep, display: nil) }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DisplayEvents.run(.wake, display: nil) }
        }
    }

    var canDisconnect: Bool { DisplayPrivateAPIs.canDisconnect }

    /// Why a display can't be switched off now, or nil when it can.
    func refusal(for display: DisplayInfo) -> LocalizedStringKey? {
        if !canDisconnect { return "This version of macOS doesn't offer the call this needs." }
        if display.kind == .builtIn && !settings.displaysAdvanced {
            return "Switching the built-in display off is a risky setting: on some Macs it only comes back after a restart. Turn on the risky settings under Safety to allow it."
        }
        // A virtual display shows nothing a person can see. One switched off a
        // moment ago is listed until the displays are read again.
        let off = Set(disconnected.map(\.id))
        let others = DisplayManager.shared.displays.filter {
            $0.id != display.id && $0.kind != .virtual && $0.mirrorOf == nil && !off.contains($0.id)
        }
        if display.kind != .virtual && others.isEmpty { return "The last display stays on." }
        return nil
    }

    private static func setEnabled(_ enabled: Bool, _ display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard DisplayPrivateAPIs.configure(config, display: display, enabled: enabled) else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// `confirm` false is for ScreenHelm's own automatic switching, which
    /// the user set up beforehand.
    @discardableResult
    func disconnect(_ display: DisplayInfo, confirm: Bool = true) -> Bool {
        guard refusal(for: display) == nil, !disconnected.contains(where: { $0.id == display.id }) else { return false }
        if confirm { DisplaySafety.shared.keepPending() }
        let name = DisplayManager.shared.name(of: display)
        let journalID = try? store?.record(DisplayJournalEntry(kind: .disconnected, display: display.key, detail: String(display.id)))
        guard Self.setEnabled(false, display.id) else {
            if let journalID { try? store?.clearJournal(id: journalID) }
            log.error("display \(display.id) not switched off")
            return false
        }
        disconnected.append(Disconnected(id: display.id, key: display.key, name: name, kind: display.kind, journalID: journalID))
        updateWatcher()
        DisplaySafety.shared.updatePanicHotKey()
        log.info("display \(display.id) switched off")
        if confirm {
            let id = display.id
            DisplaySafety.shared.confirm(
                title: String(localized: "\(name) is switched off", bundle: AppLocale.bundle),
                signature: "disconnect:\(display.key)",
                revert: { [weak self] in self?.reconnect(id) }
            )
        }
        return true
    }

    @discardableResult
    func reconnect(_ id: CGDirectDisplayID) -> Bool {
        guard let index = disconnected.firstIndex(where: { $0.id == id }) else { return false }
        let entry = disconnected[index]
        let done = Self.setEnabled(true, id)
        // Forgotten either way: a display that won't come back by its
        // number comes back by its cable, or after sleep.
        disconnected.remove(at: index)
        if let journalID = entry.journalID { try? store?.clearJournal(id: journalID) }
        updateWatcher()
        DisplaySafety.shared.updatePanicHotKey()
        log.info("display \(id) switched on: \(done)")
        return done
    }

    func reconnectAll() {
        for entry in disconnected { reconnect(entry.id) }
    }

    // MARK: - Watcher

    nonisolated static let watcherArgument = "--reconnect-displays-after"

    /// The watcher's whole life, when the executable was started as one.
    nonisolated static func runWatcherIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: watcherArgument), arguments.indices.contains(index + 2),
              let pid = pid_t(arguments[index + 1]) else { return }
        waitForExit(of: pid)
        for id in arguments[index + 2].split(separator: ",").compactMap({ UInt32($0) }) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { continue }
            if DisplayPrivateAPIs.configure(config, display: id, enabled: true) {
                CGCompleteDisplayConfiguration(config, .forSession)
            } else {
                CGCancelDisplayConfiguration(config)
            }
        }
        exit(0)
    }

    /// Blocks until `pid` exits; returns at once if it already has.
    nonisolated private static func waitForExit(of pid: pid_t) {
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: NOTE_EXIT, data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { return } // ESRCH: already gone
        var event = kevent()
        while kevent(queue, nil, 0, &event, 1, nil) < 0 && errno == EINTR {}
    }

    /// One watcher for the displays that are off now; none when none is.
    private func updateWatcher() {
        watcher?.terminate()
        watcher = nil
        guard !disconnected.isEmpty, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.watcherArgument, String(ProcessInfo.processInfo.processIdentifier),
                             disconnected.map { String($0.id) }.joined(separator: ",")]
        if (try? process.run()) != nil { watcher = process }
    }

    // MARK: - Displays coming and going

    private func displaysChanged(woke: Bool) {
        let displays = DisplayManager.shared.displays
        let online = Set(displays.map(\.id))
        // macOS switches displays back on by itself after sleep.
        for entry in disconnected where online.contains(entry.id) {
            if woke, settings.displaysDisconnectAgainAfterWake, let display = DisplayManager.shared.display(entry.id) {
                let journalID = entry.journalID
                disconnected.removeAll { $0.id == entry.id }
                if let journalID { try? store?.clearJournal(id: journalID) }
                disconnect(display, confirm: false)
            } else {
                disconnected.removeAll { $0.id == entry.id }
                if let journalID = entry.journalID { try? store?.clearJournal(id: journalID) }
            }
        }
        updateWatcher()

        let keys = Set(displays.map(\.key))
        for key in keys.subtracting(knownKeys) { DisplayEvents.run(.connected, display: key) }
        for key in knownKeys.subtracting(keys) where !disconnected.contains(where: { $0.key == key }) {
            DisplayEvents.run(.disconnected, display: key)
        }
        knownKeys = keys
        applyAutoDisconnect(displays)
    }

    /// The built-in display off while a real external one is connected,
    /// and back the moment the last one goes.
    private func applyAutoDisconnect(_ displays: [DisplayInfo]) {
        guard settings.displaysAutoDisconnectBuiltIn, settings.displaysAdvanced else { return }
        let externals = displays.filter { $0.kind == .external || $0.kind == .tv }
        if let builtIn = displays.first(where: { $0.kind == .builtIn }), !externals.isEmpty, !DisplaySafety.shared.isSafeMode {
            disconnect(builtIn, confirm: false)
        } else if externals.isEmpty, let entry = disconnected.first(where: { $0.kind == .builtIn }) {
            reconnect(entry.id)
        }
    }
}

/// Runs what the user set up for a display connecting or going away, and
/// for the displays sleeping or waking.
@MainActor
enum DisplayEvents {
    private static let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    static func run(_ trigger: DisplayEventAction.Trigger, display: String?) {
        let actions = DisplayEventAction.matching(SettingsViewModel.shared.settings.displayEventActions, trigger: trigger, display: display)
        for action in actions {
            log.info("event \(trigger.rawValue, privacy: .public): \(action.kind.rawValue, privacy: .public)")
            switch action.kind {
            case .shortcut:
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = ["run", action.target]
                try? process.run()
            case .open:
                NSWorkspace.shared.open(URL(fileURLWithPath: action.target))
            }
        }
    }
}
