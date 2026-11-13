import AppKit
import ScreenHelmCore
import SwiftUI

/// ScreenHelm's own on-screen display for brightness and volume, shown on
/// the display being changed. macOS only shows its own for displays it
/// controls itself.
@MainActor
final class DisplayOSD {
    static let shared = DisplayOSD()

    enum Kind {
        case brightness, volume, muted

        var symbol: String {
            switch self {
            case .brightness: "sun.max.fill"
            case .volume: "speaker.wave.2.fill"
            case .muted: "speaker.slash.fill"
            }
        }
    }

    @Observable
    final class Model {
        var kind = Kind.brightness
        var value = 0.0
        var detail = ""
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    private init() {}

    /// `detail` is the figure next to the bar: a percentage, or nits when known.
    func show(_ kind: Kind, value: Double, detail: String? = nil, on display: DisplayInfo) {
        guard SettingsViewModel.shared.settings.displaysOSD,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
              }) else { return }
        model.kind = kind
        model.value = value
        model.detail = detail ?? "\(Int((value * 100).rounded()))%"

        let panel = panel ?? makePanel()
        self.panel = panel
        // Top right, under the menu bar, where macOS 26 and later put theirs.
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 12))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self?.panel?.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { if self?.panel?.alphaValue == 0 { self?.panel?.orderOut(nil) } }
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    var isVisible: Bool { panel?.isVisible == true && panel?.alphaValue == 1 }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 52), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: DisplayOSDView(model: model))
        return panel
    }
}

private struct DisplayOSDView: View {
    let model: DisplayOSD.Model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.kind.symbol).font(.system(size: 15, weight: .medium)).frame(width: 22)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.18))
                    Capsule().fill(.primary).frame(width: max(0, min(1, model.value)) * proxy.size.width)
                }
            }
            .frame(height: 6)
            Text(verbatim: model.detail).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(width: 260, height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
