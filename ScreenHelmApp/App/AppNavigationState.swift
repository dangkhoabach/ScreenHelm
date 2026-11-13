import Observation

/// Sidebar selection, shared between `ContentView` and whatever opens a page
/// from outside the window: the menu items (Settings…) and the menu bar panel.
@MainActor
@Observable
final class AppNavigationState {
    static let shared = AppNavigationState()

    /// Nil until the window first opens, which then picks the main display.
    var sidebarSelection: SidebarSection?

    private init() {}
}
