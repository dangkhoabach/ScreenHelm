import AppKit
import Carbon.HIToolbox
import ScreenHelmCore
import Observation
import SwiftUI
import os

/// What stands between a display setting and a screen nobody can use:
/// a countdown that undoes a change unless it is kept, one shortcut that
/// drops everything ScreenHelm has applied, and a safe start.
@MainActor
@Observable
final class DisplaySafety {
    static let shared = DisplaySafety()

    /// Seconds a change waits to be kept before it is undone.
    static let confirmationSeconds = 15

    /// The app was started with ⇧ held, or the start before this one ended
    /// while it was applying display settings: nothing saved is applied.
    private(set) var isSafeMode = false
    /// Why, for the notice at the top of every page.
    private(set) var safeModeFollowsCrash = false
    /// Counts down while a change waits; nil otherwise.
    private(set) var secondsLeft: Int?
    private(set) var pendingTitle = ""

    /// Each feature adds how to drop what it applied; all run on the panic shortcut.
    @ObservationIgnored var panicActions: [() -> Void] = []
    /// Whether anything is applied, feature by feature: the panic shortcut
    /// is registered only while one says yes.
    @ObservationIgnored var activityChecks: [() -> Bool] = []

    @ObservationIgnored private var pendingRevert: (() -> Void)?
    @ObservationIgnored private var pendingKeep: (() -> Void)?
    @ObservationIgnored private var pendingSignature: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panels: [NSPanel] = []
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var localKeyMonitor: Any?
    @ObservationIgnored private var panicHotKey: EventHotKeyRef?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private static let launchMarker = "displays.applyingAtLaunch"
    private static let keptChanges = "displays.keptChanges"
    /// ⌃⌥⌘⎋; ⌥⌘⎋ alone is macOS's Force Quit.
    static let panicHotKey = HotKey(keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
    static let panicCarbonID: UInt32 = 900
    /// Its name among the Displays shortcuts, where it is shown but not changed.
    static let panicKey = "panic"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Safe start

    /// Decides safe mode. Call once, before anything saved is applied.
    func beginLaunch(shiftHeld: Bool = NSEvent.modifierFlags.contains(.shift)) {
        safeModeFollowsCrash = defaults.bool(forKey: Self.launchMarker)
        isSafeMode = shiftHeld || safeModeFollowsCrash
        if isSafeMode { log.notice("safe mode: saved display settings are not applied") }
        defaults.removeObject(forKey: Self.launchMarker)
    }

    /// Leaves a mark while saved settings are being applied at launch and
    /// for `settle` seconds after: if the app ends in that time, the next
    /// start is a safe one, so a setting that brings the app down can't do
    /// so on every launch.
    func guardLaunch(settle: TimeInterval = 30) {
        guard !isSafeMode else { return }
        defaults.set(true, forKey: Self.launchMarker)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [defaults] in
            defaults.removeObject(forKey: Self.launchMarker)
        }
    }

    /// A quit of the ordinary kind is not a start that went wrong, however
    /// soon after launch it comes.
    func endLaunchGuard() {
        defaults.removeObject(forKey: Self.launchMarker)
    }

    /// Leaves safe mode for the rest of this run; what is saved applies
    /// from the next change on.
    func leaveSafeMode() {
        isSafeMode = false
    }

    // MARK: - Keep or undo

    /// For a change already made that could leave a display unusable.
    /// `revert` runs unless the user keeps the change within the countdown;
    /// `onKeep` runs when they do. A change kept once (same `signature`)
    /// isn't asked about again: `onKeep` runs at once.
    func confirm(title: String, signature: String, revert: @escaping () -> Void, onKeep: @escaping () -> Void = {}) {
        resolvePending(keep: true) // A second change settles the first as it stands.
        guard !Set(defaults.stringArray(forKey: Self.keptChanges) ?? []).contains(signature) else { return onKeep() }
        pendingRevert = revert
        pendingKeep = onKeep
        pendingSignature = signature
        pendingTitle = title
        secondsLeft = Self.confirmationSeconds
        showPanels()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        updatePanicHotKey()
    }

    var hasPendingChange: Bool { pendingRevert != nil }

    /// One second of the countdown; the timer calls it.
    func tick() {
        guard let left = secondsLeft else { return }
        if left <= 1 { resolvePending(keep: false) } else { secondsLeft = left - 1 }
    }

    func keepPending() { resolvePending(keep: true) }
    func revertPending() { resolvePending(keep: false) }

    private func resolvePending(keep: Bool) {
        guard let revert = pendingRevert else { return }
        timer?.invalidate()
        timer = nil
        let onKeep = pendingKeep
        pendingRevert = nil
        pendingKeep = nil
        secondsLeft = nil
        hidePanels()
        if keep {
            onKeep?()
            if let signature = pendingSignature {
                var kept = defaults.stringArray(forKey: Self.keptChanges) ?? []
                if !kept.contains(signature) { kept.append(signature) }
                defaults.set(Array(kept.suffix(200)), forKey: Self.keptChanges)
            }
        } else {
            log.notice("display change undone: \(self.pendingTitle, privacy: .public)")
            revert()
        }
        pendingSignature = nil
        updatePanicHotKey()
    }

    /// One panel on every screen: after a bad change it may be that only
    /// one of them still shows a picture.
    private func showPanels() {
        hidePanels()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .modalPanel
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: KeepChangeView(safety: self).environment(\.locale, AppLocale.selected.locale))
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 190, y: frame.midY - 75))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        // ↩ keeps and ⎋ undoes while the panels are up, whichever app is in
        // front: one monitor for other apps' key presses, one for ScreenHelm's own.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int(event.keyCode)
            guard code == kVK_Return || code == kVK_Escape else { return }
            DispatchQueue.main.async { [weak self] in self?.resolvePending(keep: code == kVK_Return) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int(event.keyCode)
            guard code == kVK_Return || code == kVK_Escape else { return event }
            DispatchQueue.main.async { [weak self] in self?.resolvePending(keep: code == kVK_Return) }
            return nil
        }
    }

    private func hidePanels() {
        for panel in panels { panel.orderOut(nil) }
        panels = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        keyMonitor = nil
        localKeyMonitor = nil
    }

    // MARK: - Panic

    /// Drops everything ScreenHelm has applied to any display, and undoes a
    /// change still waiting to be kept. Values a monitor stored itself
    /// (DDC) and files in /Library stay.
    func panic() {
        log.notice("panic: dropping everything applied to displays")
        resolvePending(keep: false)
        for action in panicActions { action() }
        updatePanicHotKey()
    }

    /// The shortcut is held only while there is something to drop, so it
    /// isn't taken from other apps the rest of the time.
    func updatePanicHotKey() {
        let wanted = hasPendingChange || activityChecks.contains { $0() }
        if wanted, panicHotKey == nil {
            let id = EventHotKeyID(signature: HotKeyManager.signature, id: Self.panicCarbonID)
            RegisterEventHotKey(Self.panicHotKey.keyCode, Self.panicHotKey.carbonModifiers, id, GetApplicationEventTarget(), 0, &panicHotKey)
        } else if !wanted, let registered = panicHotKey {
            UnregisterEventHotKey(registered)
            panicHotKey = nil
        }
    }

    var panicHotKeyIsRegistered: Bool { panicHotKey != nil }
}

private struct KeepChangeView: View {
    let safety: DisplaySafety

    var body: some View {
        VStack(spacing: 10) {
            Text("Keep this display setting?").font(.headline)
            Text(safety.pendingTitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Going back in \(safety.secondsLeft ?? 0) seconds").font(.callout).monospacedDigit()
            HStack(spacing: 12) {
                Button("Go Back") { safety.revertPending() }
                Button("Keep") { safety.keepPending() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 150)
    }
}
