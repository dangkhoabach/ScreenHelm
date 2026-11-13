import AppKit
import SwiftUI

/// The status item and everything hanging off it: a left click (or the
/// global shortcut) opens the panel, and a right click opens a short menu.
///
/// AppKit rather than SwiftUI's `MenuBarExtra`, which can't be opened from a
/// shortcut, has no right-click menu and doesn't say when it opens or closes.
@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    static let shared = StatusBarController()

    private(set) var hotKeys: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanel?
    /// When the panel last closed because it lost focus. A click on the icon
    /// while the panel is open takes the focus first and only then reaches
    /// `statusItemClicked`, which would open the panel again at once.
    private var lastClosedAt = Date.distantPast

    var isPanelOpen: Bool { panel?.isVisible == true }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "ScreenHelm")
        item.button?.setAccessibilityTitle("ScreenHelm")
        statusItem = item

        let hotKeys = HotKeyManager { [weak self] key in
            if key == HotKeyManager.panelKey {
                self?.togglePanel()
            } else {
                DisplayShortcuts.perform(key: key)
            }
        }
        hotKeys.start(keys: [HotKeyManager.panelKey] + DisplayAction.allCases.map(\.rawValue))
        self.hotKeys = hotKeys
    }

    // MARK: - Panel

    func togglePanel() {
        isPanelOpen ? closePanel() : openPanel()
    }

    func openPanel() {
        guard !isPanelOpen, Date().timeIntervalSince(lastClosedAt) > 0.3,
              let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        Permissions.shared.refresh()
    }

    func closePanel() {
        guard isPanelOpen else { return }
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        lastClosedAt = Date()
    }

    /// The panel as tall as what it shows, up to `MenuBarPanelView`'s
    /// limit, growing and shrinking from its top edge under the menu bar.
    func fitPanel(height: CGFloat) {
        guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> MenuBarPanel {
        let view = MenuBarPanelView()
        let panel = MenuBarPanel(size: CGSize(width: MenuBarPanelView.width, height: 200), rootView: view)
        panel.delegate = self
        panel.onClose = { [weak self] in self?.closePanel() }
        self.panel = panel
        return panel
    }

    /// Clicking anywhere else — another app, the desktop, ScreenHelm's own
    /// window — takes the focus away from the panel.
    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            showQuickMenu()
        } else {
            togglePanel()
        }
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        func add(_ key: String, _ action: Selector, _ keyEquivalent: String = "") {
            let item = NSMenuItem(title: localized(key), action: action, keyEquivalent: keyEquivalent)
            item.target = self
            menu.addItem(item)
        }
        add("Show ScreenHelm", #selector(showMainWindow))
        add("Settings…", #selector(showSettings), ",")
        add("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        add("Quit ScreenHelm", #selector(quit), "q")
        // A menu set on the item opens on the next click; it's taken off
        // again so a left click keeps opening the panel.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func showMainWindow() { WindowPresenter.showMainWindow() }
    @objc private func showSettings() { WindowPresenter.showSettings() }
    @objc private func checkForUpdates() { AppUpdater.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: AppLocale.bundle)
    }
}
