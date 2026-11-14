import AppKit
import ScreenHelmCore

/// Lets the user drag a rectangle over a display to choose the part of it
/// a stream shows. Return or letting go of the mouse takes it, Escape
/// cancels; either way the overlay goes.
@MainActor
final class AreaPicker {
    private static var current: AreaPicker?

    private let window: AreaPickerWindow
    private let completion: (UnitRect?) -> Void

    /// Nothing happens for a display that isn't connected.
    static func pick(on display: CGDirectDisplayID, completion: @escaping (UnitRect?) -> Void) {
        current?.finish(nil)
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return completion(nil) }
        let picker = AreaPicker(screen: screen, completion: completion)
        current = picker
        picker.show()
    }

    private init(screen: NSScreen, completion: @escaping (UnitRect?) -> Void) {
        self.completion = completion
        window = AreaPickerWindow(screen: screen)
        window.pickerView.onFinish = { [weak self] rect in self?.finish(rect) }
    }

    private func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.pickerView)
    }

    private func finish(_ selection: CGRect?) {
        guard Self.current === self else { return }
        Self.current = nil
        window.orderOut(nil)
        completion(selection.map { UnitRect(selection: $0, in: window.pickerView.bounds.size) })
    }
}

private final class AreaPickerWindow: NSPanel {
    let pickerView = AreaPickerView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = pickerView
    }

    override var canBecomeKey: Bool { true }
}

private final class AreaPickerView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection: CGRect?

    /// Smaller than this, a click or a slip of the hand, not a choice.
    private static let smallest: CGFloat = 20

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        if let selection, selection.width >= Self.smallest, selection.height >= Self.smallest { onFinish?(selection) } else { selection = nil }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(nil) // Escape
        case 36, 76: // Return, Enter
            if let selection, selection.width >= Self.smallest, selection.height >= Self.smallest { onFinish?(selection) }
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
        }
        let hint = String(localized: "Drag over the part to show. Escape cancels.", bundle: AppLocale.bundle)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: attributes)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 80)
        let plate = CGRect(origin: origin, size: size).insetBy(dx: -14, dy: -8)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 8, yRadius: 8).fill()
        hint.draw(at: origin, withAttributes: attributes)
    }
}
