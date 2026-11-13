import AppKit
import SwiftUI

/// Brings the main window forward with a Dock icon, the same sequence for the
/// launch, a Dock-icon reopen and the menu bar items.
@MainActor
enum WindowPresenter {
    static let mainWindowID = "main"

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        for window in mainWindows(in: NSApp.windows) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Only the main window, recognised by the delegate
    /// `WindowAccessor` gives it. `NSApp.windows` also holds the menu bar
    /// panel; ordering that front opens it outside the status item's own
    /// tracking, so it never closes.
    static func mainWindows(in windows: [NSWindow]) -> [NSWindow] {
        windows.filter { $0.delegate is HideInsteadOfCloseDelegate }
    }

    /// The main window ordered out, with no Dock icon, as `LSUIElement` has it.
    static func hideMainWindow() {
        for window in mainWindows(in: NSApp.windows) {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    static func show(_ section: SidebarSection) {
        showMainWindow()
        AppNavigationState.shared.sidebarSelection = section
    }

    static func showSettings() {
        show(.settings)
    }
}
