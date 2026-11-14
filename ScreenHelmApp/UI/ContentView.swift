import ScreenHelmCore
import SwiftUI

/// Sidebar + content, styled like the sibling apps: unselected row icons
/// dimmed, and focus handed back to the sidebar after every switch so its
/// selection keeps the accent colour instead of the inactive grey.
struct ContentView: View {
    @Bindable private var navigationState = AppNavigationState.shared
    private let manager = DisplayManager.shared
    @FocusState private var sidebarFocused: Bool

    /// The page shown: the one picked, or the main display's until then and
    /// when the display picked is gone.
    private var selection: SidebarSection {
        if let picked = navigationState.sidebarSelection {
            if case .display(let key) = picked, manager.display(key: key) == nil { return mainDisplayPage }
            return picked
        }
        return mainDisplayPage
    }

    private var mainDisplayPage: SidebarSection {
        (manager.displays.first(where: \.isMain) ?? manager.displays.first).map { .display($0.key) } ?? .arrangement
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selection },
                set: { if let newValue = $0 { navigationState.sidebarSelection = newValue } }
            )) {
                Section {
                    ForEach(manager.displays) { display in
                        row(Text(verbatim: manager.name(of: display)), systemImage: display.symbolName, for: .display(display.key))
                    }
                } header: {
                    Text("Displays")
                }
                Section {
                    ForEach(SidebarSection.tools, id: \.self) { page in
                        row(Text(page.title), systemImage: page.systemImage, for: page)
                    }
                } header: {
                    Text("Tools")
                }
                Section {
                    ForEach(SidebarSection.control, id: \.self) { page in
                        row(Text(page.title), systemImage: page.systemImage, for: page)
                    }
                } header: {
                    Text("Control")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarSettingsRow(isSelected: selection == .settings) {
                    navigationState.sidebarSelection = .settings
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .focused($sidebarFocused)
        } detail: {
            Form {
                DisplayNotices()
                page
            }
            .formStyle(.grouped)
            // A new page starts at its top, not where the last one was scrolled to.
            .id(selection)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { sidebarFocused = true }
        .onChange(of: navigationState.sidebarSelection) { _, _ in sidebarFocused = true }
    }

    private func row(_ title: Text, systemImage: String, for section: SidebarSection) -> some View {
        Label {
            title.lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(section == selection ? Color.primary : Color.secondary)
        }
        .tag(section)
    }

    @ViewBuilder
    private var page: some View {
        switch selection {
        case .display(let key):
            if let display = manager.display(key: key) { DisplaySections(display: display) }
        case .arrangement: ArrangementSections()
        case .virtualScreens: VirtualScreensSections()
        case .pictureInPicture: StreamsSections()
        case .shortcuts: DisplayShortcutsSections()
        case .automation: AutomationSections()
        case .settings: SettingsSections()
        }
    }
}
