import SwiftUI

/// The menu bar panel: a header, one block per display with the controls
/// reached every day, and a footer with the app-level actions. As tall as
/// what it shows, up to `maximumHeight`, past which the displays scroll.
struct MenuBarPanelView: View {
    static let width: CGFloat = 360
    static let maximumHeight: CGFloat = 640

    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        // The panel is not part of a SwiftUI scene, so the in-app language is
        // applied here rather than inherited.
        MenuBarPanelContent()
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
            .frame(width: Self.width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                StatusBarController.shared.fitPanel(height: height)
            }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MenuBarPanelContent: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "ScreenHelm").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Divider()
            ScrollView {
                DisplaysPanelContent()
            }
            .frame(maxHeight: MenuBarPanelView.maximumHeight - 90)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("Show ScreenHelm", systemImage: "macwindow") { WindowPresenter.showMainWindow() }
            ForEach([SidebarSection.virtualScreens, .pictureInPicture], id: \.self) { page in
                footerButton(page.title, systemImage: page.systemImage) { WindowPresenter.show(page) }
            }
            footerButton("Settings…", systemImage: "gearshape") { WindowPresenter.showSettings() }
            footerButton("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { AppUpdater.checkForUpdates() }
            Spacer()
            footerButton("Quit ScreenHelm", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func footerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}
