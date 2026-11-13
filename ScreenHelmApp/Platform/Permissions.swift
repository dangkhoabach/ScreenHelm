import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit

/// The two privacy grants some of ScreenHelm's features need; neither is
/// needed to change a display. Both are given in System Settings while
/// ScreenHelm is in the background, so they are read again each time the
/// app becomes active, and every two seconds while a feature that needs one
/// waits for it.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    /// The keyboard's brightness and volume keys, and finding the window in front.
    private(set) var accessibility = AXIsProcessTrusted()
    /// Picture in picture.
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()

    private var poll: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
    }

    func refresh() {
        let accessibility = AXIsProcessTrusted(), screenRecording = CGPreflightScreenCaptureAccess()
        if accessibility != self.accessibility { self.accessibility = accessibility }
        if screenRecording != self.screenRecording { self.screenRecording = screenRecording }
        if accessibility && screenRecording { stopPolling() }
    }

    /// Reads the grants every two seconds until both are given, so a
    /// feature allowed from System Settings starts without a trip back to
    /// ScreenHelm. Started only when the user asks for a permission.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
        poll?.tolerance = 1
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    /// The prompt also adds ScreenHelm to the Accessibility list, where it has
    /// to be switched on; macOS shows the prompt only once, so the pane is
    /// opened as well.
    func requestAccessibility() {
        startPolling()
        // The value of `kAXTrustedCheckOptionPrompt`, a C global that Swift 6
        // refuses to read outside a single isolation domain.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    /// On macOS 27 `CGRequestScreenCaptureAccess` alone did not add the app
    /// to the Screen Recording list; asking ScreenCaptureKit for the shareable
    /// content does, so the pane opens only after that call returns.
    func requestScreenRecording() {
        guard !CGRequestScreenCaptureAccess() else { return refresh() }
        startPolling()
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            openPrivacyPane("Privacy_ScreenCapture")
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
