import AppKit
import GRDB
import Testing
@testable import ScreenHelmCore
@testable import ScreenHelm

@MainActor
@Suite struct SettingsViewModelTests {
    /// Saved as it changes, so a change made right before quitting is not
    /// lost to a pending write.
    @Test func aChangeIsSavedImmediately() throws {
        let database = try AppDatabase(inMemory: DatabaseQueue())
        let model = SettingsViewModel(database: database)
        model.loadIfNeeded()

        model.settings.displaysHTTPPort = 50999

        #expect(try SettingsRepository(dbQueue: database.dbQueue).load().displaysHTTPPort == 50999)
    }
}

@MainActor
@Suite(.serialized) struct DisplayKeepAwakeTests {
    /// A connected display from the list holds a power assertion, and
    /// taking it off the list lets it go.
    @Test func aListedDisplayHoldsTheMacAwake() throws {
        let manager = DisplayManager.shared
        manager.refresh()
        let display = try #require(manager.displays.first)
        let viewModel = SettingsViewModel.shared
        viewModel.loadIfNeeded()
        let before = viewModel.settings.keepAwakeDisplays
        defer {
            viewModel.settings.keepAwakeDisplays = before
            DisplayKeepAwake.shared.update()
        }
        viewModel.settings.keepAwakeDisplays = ["not-connected", display.key]
        DisplayKeepAwake.shared.update()
        let battery = DisplayKeepAwake.battery()
        let low = KeepAwakePolicy.batteryIsLow(battery, minimumPercent: KeepAwakePolicy.batteryMinimumPercent)
        #expect(DisplayKeepAwake.shared.holdingFor == (low ? nil : display.key))
        viewModel.settings.keepAwakeDisplays = ["not-connected"]
        DisplayKeepAwake.shared.update()
        #expect(DisplayKeepAwake.shared.holdingFor == nil)
    }
}

@MainActor
@Suite(.serialized) struct MenuBarPanelTests {
    /// As tall as the displays it shows, never past its limit, and hanging
    /// from the same place however tall it gets.
    @Test func thePanelFitsWhatItShows() async throws {
        let bar = StatusBarController.shared
        bar.openPanel()
        defer { bar.closePanel() }
        try await Task.sleep(for: .milliseconds(800))
        let panel = try #require(NSApp.windows.first { $0 is MenuBarPanel })
        #expect(panel.isVisible)
        #expect(panel.frame.width == MenuBarPanelView.width)
        #expect(panel.frame.height > 150 && panel.frame.height <= MenuBarPanelView.maximumHeight)
        // Taller or shorter, the top edge stays where it hangs from.
        let top = panel.frame.maxY, height = panel.frame.height
        bar.fitPanel(height: height + 120)
        #expect(panel.frame.maxY == top && panel.frame.height == height + 120)
        bar.fitPanel(height: height)
        #expect(panel.frame.maxY == top && panel.frame.height == height)
    }
}
