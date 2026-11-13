import Foundation
import GRDB
import Testing
@testable import ScreenHelmCore

@Suite struct SettingsRepositoryTests {
    private func makeRepo() throws -> SettingsRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return SettingsRepository(dbQueue: app.dbQueue)
    }

    /// Every field must survive a write followed by a read.
    ///
    /// `load` and `update` each spell out the same `app_settings` keys by
    /// hand, in two separate lists. One typo on either side is invisible —
    /// the write lands under a key nothing reads, and the setting silently
    /// reverts to its default the next time the app starts. Round-tripping
    /// values that are all distinct from the defaults is what makes such a
    /// mismatch fail here.
    @Test func everySettingSurvivesARoundTrip() throws {
        let repo = try makeRepo()
        let settings = AppSettings(
            displaysKeysEnabled: true,
            displaysKeyTarget: .fixed,
            displaysKeyFixedDisplay: "10ac-a0f1-00001234",
            displaysOSD: false,
            displaysRemember: false,
            displaysAdvanced: true,
            displaysPreferOverlay: true,
            displaysXDRBatteryMinimum: 35,
            displaysXDRPauseNightShift: true,
            displaysSyncSource: .ambientLight,
            displaysSyncByNits: true,
            displaysProtection: DisplayProtectionSettings(enabled: true, position: false, hdr: true),
            displaysAutoDisconnectBuiltIn: true,
            displaysDisconnectAgainAfterWake: true,
            keepAwakeDisplays: ["10ac-a0f1-00001234"],
            displayEventActions: [DisplayEventAction(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!, trigger: .connected,
                                                     display: "10ac-a0f1-00001234", kind: .shortcut, target: "Desk Mode")],
            displaysHeadlessScreen: true,
            displaysAutomation: true,
            displaysHTTPEnabled: true,
            displaysHTTPPort: 50123,
            displayGroups: [DisplayGroup(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000002")!, name: "Desk", displays: ["a", "b"])]
        )
        try repo.update(settings)
        #expect(try repo.load() == settings)
    }

    @Test func aFreshDatabaseLoadsTheDefaults() throws {
        #expect(try makeRepo().load() == AppSettings.defaults)
    }
}
