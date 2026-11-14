import AppKit
import ScreenHelmCore
import os

/// For groups that match text size: when a member's resolution changes,
/// by ScreenHelm or by macOS, the other members connected take the mode at
/// which things look as big, all under one "keep this?" question.
@MainActor
final class TextSizeMatcher {
    static let shared = TextSizeMatcher()
    /// How far a mode may be from the size wanted, as a fraction.
    static let tolerance = 0.1

    private var watch = ResolutionWatch()
    /// A display that changed while another change waited to be kept or undone.
    private var waitingSource: String?
    private var retry: Timer?
    private var started = false
    private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        _ = watch.source(in: Self.sizes(), at: Date())
        DisplayManager.shared.onChange.append { [weak self] _ in self?.displaysChanged() }
    }

    /// Whether the group's rule holds now. Virtual screens ScreenHelm made
    /// count only when they are members.
    static func isActive(_ group: DisplayGroup) -> Bool {
        let connected = DisplayManager.shared.displays.filter { $0.kind != .virtual || group.displays.contains($0.key) }.map(\.key)
        return group.isActive(connected: connected)
    }

    private static func sizes() -> [String: CGSize] {
        Dictionary(DisplayManager.shared.displays.map { ($0.key, $0.bounds.size) }, uniquingKeysWith: { first, _ in first })
    }

    private func displaysChanged() {
        guard let source = watch.source(in: Self.sizes(), at: Date()) else { return }
        guard settings.displayGroups.contains(where: { $0.matchTextSize && $0.displays.contains(source) }) else { return }
        waitingSource = source
        matchWhenSettled()
    }

    /// A change waiting to be kept is left alone: asking about another would settle it as kept.
    private func matchWhenSettled() {
        retry?.invalidate()
        retry = nil
        guard let source = waitingSource else { return }
        if DisplaySafety.shared.hasPendingChange {
            retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated { TextSizeMatcher.shared.matchWhenSettled() }
            }
            return
        }
        waitingSource = nil
        match(from: source)
    }

    private func match(from sourceKey: String) {
        let manager = DisplayManager.shared
        guard let source = manager.display(key: sourceKey) else { return }
        var targets: [String] = []
        for group in settings.displayGroups where group.matchTextSize && group.displays.contains(sourceKey) && Self.isActive(group) {
            targets += group.displays.filter { $0 != sourceKey && !targets.contains($0) }
        }
        var changes: [(mode: DisplayModeInfo, display: DisplayInfo)] = []
        for key in targets {
            guard let display = manager.display(key: key), display.mirrorOf == nil, display.kind != .airPlay,
                  let mode = ModeController.shared.textSizeMatch(on: display, to: source, within: Self.tolerance),
                  mode.number != ModeController.shared.current(of: display.id)?.number
            else { continue }
            changes.append((mode, display))
        }
        guard !changes.isEmpty else { return }
        let now = Date()
        for change in changes { watch.expect(CGSize(width: change.mode.width, height: change.mode.height), on: change.display.key, at: now) }
        let previous = changes.map { ($0.display.key, $0.display.bounds.size) }
        let names = changes.map { manager.name(of: $0.display) }.joined(separator: ", ")
        let title = String(localized: "Text as big as on \(manager.name(of: source)): \(names)", bundle: AppLocale.bundle)
        log.info("matching text size on \(changes.count) displays")
        ModeController.shared.setTogether(changes, title: title) { [weak self] in
            // Going back is not a change to follow either.
            let now = Date()
            for (key, size) in previous { self?.watch.expect(size, on: key, at: now) }
        }
    }
}
