import ApplicationServices

/// The few Accessibility calls ScreenHelm makes on other apps' windows: only
/// to find the display of the window in front, for the brightness keys.
enum AX {
    /// An app that doesn't answer must not stall ScreenHelm's main thread for
    /// the system default of six seconds.
    static let messagingTimeout: Float = 0.3

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    /// Standard windows the user can see: not minimized, not full screen.
    static func visibleWindows(of pid: pid_t) -> [AXUIElement] {
        let windows: [AXUIElement] = value(application(pid), kAXWindowsAttribute) ?? []
        return windows.filter {
            (value($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
                && (value($0, kAXMinimizedAttribute) as Bool?) != true
                && (value($0, "AXFullScreen") as Bool?) != true
        }
    }

    /// In Accessibility coordinates: origin at the top left of the main screen, y downwards.
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(window, kAXPositionAttribute),
              let size: AXValue = value(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}
