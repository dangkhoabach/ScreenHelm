import Foundation
import GRDB
import Testing
@testable import ScreenHelmCore

@Suite struct AppDatabaseTests {
    @Test func aFreshDatabaseHasEveryTable() throws {
        let db = try AppDatabase(inMemory: DatabaseQueue())
        for table in ["app_settings", "display_profile", "display_layout", "virtual_screen", "stream_config", "display_journal"] {
            let exists = try db.dbQueue.read { try $0.tableExists(table) }
            #expect(exists, "\(table)")
        }
    }

    @Test func migratingTwiceIsANoOp() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("screenhelm-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try AppDatabase(path: path)
        let reopened = try AppDatabase(path: path)
        let applied = try reopened.dbQueue.read { try AppDatabase.migrator.appliedMigrations($0) }
        #expect(applied == ["v1"])
    }

    @Test func settingsFallBackToTheDefaultAndOverwrite() throws {
        let db = try AppDatabase(inMemory: DatabaseQueue())
        try db.dbQueue.write { db in
            #expect(try AppSettingsStore.get(db, key: "k", default: "fallback") == "fallback")
            try AppSettingsStore.set(db, key: "k", value: "one")
            try AppSettingsStore.set(db, key: "k", value: "two")
            #expect(try AppSettingsStore.get(db, key: "k", default: "fallback") == "two")
        }
    }
}
