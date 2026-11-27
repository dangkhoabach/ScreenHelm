import AppKit
import ScreenHelmCore

/// AppKit glue SwiftUI scenes don't expose: apply the theme, start the
/// updater and the displays, keep running with no window open, and reopen
/// the window from the Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `screenhelm://` links that came before the displays were read: the
    /// ones that started the app.
    private var pendingLinks: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemePreference.apply()
        if let failure = AppDatabase.openFailure {
            presentDatabaseFailure(failure)
        }
        StatusBarController.shared.start()
        Displays.start()
        // A link that started the app runs its command without bringing a
        // window forward.
        let openedByLink = !pendingLinks.isEmpty
        run(pendingLinks)
        pendingLinks = []
        _ = AppUpdater.shared   // starts Sparkle's scheduled check (the controller is lazy)
        // Opened at login, ScreenHelm stays in the menu bar: the window SwiftUI
        // creates a turn later opens hidden. Otherwise `LSUIElement` keeps
        // the app out of the Dock until that window brings the icon back.
        if LoginItemManager.wasOpenedAtLogin() {
            NSApp.hide(nil)
        } else if openedByLink {
            DispatchQueue.main.async { WindowPresenter.hideMainWindow() }
        } else {
            DispatchQueue.main.async { WindowPresenter.showMainWindow() }
        }
    }

    /// `screenhelm://display/…` links. At launch this comes before
    /// `applicationDidFinishLaunching`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let links = urls.filter { $0.scheme == "screenhelm" && $0.host == "display" }
        guard Displays.isStarted else { return pendingLinks += links }
        run(links)
    }

    /// Only when the user turned display commands on: a link can come from anywhere.
    private func run(_ links: [URL]) {
        guard !links.isEmpty, SettingsViewModel.shared.settings.displaysAutomation else { return }
        for url in links { _ = AutomationRouter.run(url: url) }
    }

    /// Displays ScreenHelm switched off come back with its quitting, a
    /// change not yet kept is undone, and XDR boost gives back Night Shift.
    func applicationWillTerminate(_ notification: Notification) {
        DisplaySafety.shared.revertPending()
        XDRController.shared.stopAll()
        ConnectionController.shared.reconnectAll()
        ColorPauseController.shared.restore()
        DisplaySafety.shared.endLaunchGuard()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowPresenter.showMainWindow()
        // Already handled: AppKit's own reopen would bring the window back
        // without the Dock icon.
        return false
    }

    /// Says plainly that settings can't be kept, and where the file it
    /// couldn't open lives.
    private func presentDatabaseFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        let bundle = AppLocale.bundle
        alert.messageText = String(localized: "ScreenHelm can't open its database", bundle: bundle)
        alert.informativeText = String(localized: "Settings can't be saved until this is fixed.", bundle: bundle)
            + "\n\n\(error.localizedDescription)\n\n"
            + String(localized: "The database is at:", bundle: bundle)
            + "\n\(AppDatabaseLocation.productionPath().path)"
        alert.addButton(withTitle: String(localized: "Continue Anyway", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Show in Finder", bundle: bundle))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([AppDatabaseLocation.productionPath()])
        }
    }
}
