import Foundation
import Observation
import ScreenHelmCore

/// The settings every part of the app reads, loaded once and saved on every
/// change.
@MainActor
@Observable
final class SettingsViewModel {
    static let shared = SettingsViewModel(database: AppDatabase.shared)

    /// Nil only when the database failed to open — the startup alert covers
    /// that case, so every change here just isn't saved rather than repeating
    /// the complaint.
    private let database: AppDatabase?
    private var isLoaded = false

    /// Saved on every change rather than debounced: it is a handful of keys,
    /// and nothing is left waiting for a quit to discard.
    var settings: AppSettings = .defaults {
        didSet {
            guard isLoaded, oldValue != settings, let database else { return }
            try? SettingsRepository(dbQueue: database.dbQueue).update(settings)
        }
    }

    init(database: AppDatabase?) {
        self.database = database
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        settings = database.flatMap { try? SettingsRepository(dbQueue: $0.dbQueue).load() } ?? .defaults
        isLoaded = true
    }
}
