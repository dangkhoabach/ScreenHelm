import SwiftUI

struct ScreenHelmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue
    private let windowDelegate = HideInsteadOfCloseDelegate()

    private var appLocale: AppLocale {
        AppLocale(rawValue: languageRaw) ?? .systemDefault
    }

    var body: some Scene {
        // One window, made at launch even when a `screenhelm://` link starts
        // the app (AppDelegate hides it then), and never a second one for a link.
        Window(Text(verbatim: "ScreenHelm"), id: WindowPresenter.mainWindowID) {
            ContentView()
                .background(WindowAccessor(delegate: windowDelegate))
                .environment(\.locale, appLocale.locale)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.checkForUpdates() }
            }
            // Settings is a page of the main window, not a separate scene.
            // Deferred a run-loop turn: changing the sidebar selection while
            // AppKit's menu is still tracking left the sidebar unresponsive
            // in a sibling app.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    DispatchQueue.main.async { WindowPresenter.showSettings() }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // One main window: no File › New Window.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
