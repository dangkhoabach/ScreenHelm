import Foundation

/// `~/Library/Application Support/com.dangkhoabach.screenhelm/screenhelm.db`.
enum AppDatabaseLocation {
    static func productionPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.dangkhoabach.screenhelm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("screenhelm.db")
    }
}
