import AppKit
import ScreenHelmCore
import os

/// Installs extra sharp resolutions for a real display by writing the
/// file macOS reads them from, under /Library/Displays. That folder is
/// the administrator's: each install and each removal asks for the
/// password, and ScreenHelm keeps no helper running with those rights.
@MainActor
enum OverrideInstaller {
    private static let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    /// Where the files go; a test points this at a folder of its own.
    static var root = "/Library/Displays/Contents/Resources/Overrides"
    static var systemRoot = "/System/Library/Displays/Contents/Resources/Overrides"
    /// Runs a shell command with administrator rights, after macOS asked
    /// for the password; false when it failed or the user said no.
    static var runPrivileged: (String) -> Bool = { command in
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        return error == nil
    }

    private static var store: DisplayStore? { AppDatabase.shared.map { DisplayStore(dbQueue: $0.dbQueue) } }

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func path(for display: DisplayInfo) -> String {
        ScaledResolutions.path(vendor: display.identity.vendor, product: display.identity.product, root: root)
    }

    /// The sizes ScreenHelm would add for a display: a close-set run in the
    /// panel's shape, plus any the user typed in.
    static func sizes(for display: DisplayInfo, extra: [ScaledResolutions.Size] = []) -> [ScaledResolutions.Size] {
        guard let native = ModeController.shared.modes(of: display.id).first(where: \.isNative) else { return extra }
        let generated = ScaledResolutions.generate(panelWidth: native.pixelWidth, panelHeight: native.pixelHeight,
                                                   maximumBackingWidth: ScaledResolutions.maximumBackingWidth(chip: chip))
        return generated + extra.filter { !generated.contains($0) }
    }

    struct Status: Equatable {
        /// A file for this display's model is in /Library.
        var installed: Bool
        /// ScreenHelm put it there, and can take it out again.
        var byScreenHelm: Bool
        var sizes: [ScaledResolutions.Size]
    }

    static func status(for display: DisplayInfo) -> Status {
        let path = path(for: display)
        let data = FileManager.default.contents(atPath: path)
        let journaled = ((try? store?.journal(.overrideFile)) ?? []).contains { $0.detail == path }
        return Status(installed: data != nil, byScreenHelm: journaled, sizes: data.map(ScaledResolutions.sizes(in:)) ?? [])
    }

    /// Writes the file for a display's model. What was in /Library before
    /// is kept in the journal, to be put back by `remove`. The new modes
    /// show after a restart for a built-in display; an external one may
    /// only need its cable pulled and put back.
    @discardableResult
    static func install(_ sizes: [ScaledResolutions.Size], for display: DisplayInfo) -> Bool {
        let destination = path(for: display)
        let existing = FileManager.default.contents(atPath: destination)
        // Apple's own file for the model, when there is one, is what the new one starts from.
        let system = FileManager.default.contents(atPath: ScaledResolutions.path(vendor: display.identity.vendor, product: display.identity.product,
                                                                                root: systemRoot))
        guard !sizes.isEmpty,
              let contents = try? ScaledResolutions.propertyList(base: existing ?? system, vendor: display.identity.vendor,
                                                                 product: display.identity.product, name: display.systemName, adding: sizes)
        else { return false }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("screenhelm-override-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (try? contents.write(to: temporary)) != nil else { return false }
        guard runPrivileged(ScaledResolutions.installCommand(from: temporary.path, to: destination)) else {
            log.notice("override file not installed")
            return false
        }
        // The first install's backup is the one to go back to; a later one would only hold ScreenHelm's own file.
        let journaled = ((try? store?.journal(.overrideFile)) ?? []).contains { $0.detail == destination }
        if !journaled {
            _ = try? store?.record(DisplayJournalEntry(kind: .overrideFile, display: display.key, detail: destination, backup: existing))
        }
        log.info("override file installed with \(sizes.count) sizes")
        return true
    }

    /// Takes ScreenHelm's file out: the file that was there before goes
    /// back, or none if there was none.
    @discardableResult
    static func remove(for display: DisplayInfo) -> Bool {
        let destination = path(for: display)
        guard let entry = ((try? store?.journal(.overrideFile)) ?? []).first(where: { $0.detail == destination }) else { return false }
        let command: String
        var temporary: URL?
        if let backup = entry.backup {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("screenhelm-override-\(UUID().uuidString)")
            guard (try? backup.write(to: file)) != nil else { return false }
            temporary = file
            command = ScaledResolutions.installCommand(from: file.path, to: destination)
        } else {
            command = ScaledResolutions.removeCommand(destination)
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        guard runPrivileged(command) else { return false }
        if let id = entry.id { try? store?.clearJournal(id: id) }
        log.info("override file removed")
        return true
    }
}
