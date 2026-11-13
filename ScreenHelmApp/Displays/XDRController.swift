import AppKit
import ScreenHelmCore
import Metal
import Observation
import QuartzCore
import os

/// A layer that shows one flat colour brighter than white, which is what
/// makes macOS give a display its extended range. Used one pixel big to
/// switch that range on, and screen-sized to multiply everything under it.
@MainActor
final class EDRLayerWindow {
    private let window: NSWindow
    private let layer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private var timer: Timer?
    private(set) var value: Double

    /// `multiply` makes the window brighten what is under it by `value`;
    /// without it the window only shows `value`.
    init?(frame: NSRect, value: Double, multiply: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        self.value = value
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = !multiply
        if multiply { layer.compositingFilter = "multiplyBlendMode" }
        layer.drawableSize = CGSize(width: max(1, frame.width), height: max(1, frame.height))

        window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        layer.frame = view.bounds
        view.layer = layer
        window.contentView = view
        window.orderFrontRegardless()
        draw()
        // The range stays on only while something keeps drawing; twice a
        // second is plenty and costs next to nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.draw() }
        }
        timer?.tolerance = 0.1
    }

    func setValue(_ value: Double) {
        self.value = value
        draw()
    }

    func setFrame(_ frame: NSRect) {
        window.setFrame(frame, display: false)
        layer.drawableSize = CGSize(width: max(1, frame.width), height: max(1, frame.height))
        draw()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
    }

    private func draw() {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// XDR boost: white brighter than the display's usual limit, for working
/// in bright light. The part of the brightness slider above 100%.
@MainActor
@Observable
final class XDRController {
    static let shared = XDRController()

    /// Displays being boosted now, with the factor white is multiplied by.
    private(set) var factors: [CGDirectDisplayID: Double] = [:]
    /// Why boost was last switched off without being asked to.
    private(set) var stopReason: XDRBoost.StopReason?

    @ObservationIgnored private var triggers: [CGDirectDisplayID: EDRLayerWindow] = [:]
    @ObservationIgnored private var overlays: [CGDirectDisplayID: EDRLayerWindow] = [:]
    @ObservationIgnored private var sliders: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var watch: Timer?
    @ObservationIgnored private var pausedNightShift = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DisplayManager.shared.onChange.append { [weak self] _ in self?.displaysChanged() }
        // The room a display has above white changes with its backlight
        // and with what else is on screen; macOS says so with this.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { XDRController.shared.reapply() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { XDRController.shared.checkLimits() }
        }
    }

    var isActive: Bool { !sliders.isEmpty }

    private func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
    }

    /// An Apple XDR panel: its backlight is macOS's to set, and it has
    /// room well above white.
    func isAvailable(for display: DisplayInfo) -> Bool {
        display.hasAppleBrightness && (screen(for: display.id)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.5
    }

    func isEnabled(for display: DisplayInfo) -> Bool {
        isAvailable(for: display) && DisplayManager.shared.profile(for: display).xdrBoost
    }

    func setEnabled(_ on: Bool, for display: DisplayInfo) {
        DisplayManager.shared.updateProfile(of: display) { $0.xdrBoost = on }
        if !on { stop(display.id) }
        stopReason = nil
    }

    /// What white shows at now, with the extended range on: the panel's
    /// peak over the room macOS gives above white. (The room it "could"
    /// give is a fixed 16 on these panels and says nothing about white.)
    private func sdrNits(of display: CGDirectDisplayID) -> Double {
        let headroom = Double(screen(for: display)?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        return headroom > 1.05 ? XDRBoost.panelPeakNits / headroom : 500
    }

    /// The brightness white is shown at now, for the slider's label.
    func nits(for display: DisplayInfo) -> Double? {
        factors[display.id].map { XDRBoost.nits(factor: $0, sdrNits: sdrNits(of: display.id)) }
    }

    /// The slider went above 1, or back under it.
    func setSlider(_ value: Double, for display: DisplayInfo) {
        guard value > 1, isEnabled(for: display), limitReason() == nil else { return stop(display.id) }
        sliders[display.id] = value
        if triggers[display.id] == nil, let frame = screen(for: display.id)?.frame {
            // One pixel in the top left corner, brighter than white.
            triggers[display.id] = EDRLayerWindow(frame: NSRect(x: frame.minX, y: frame.maxY - 1, width: 1, height: 1), value: 1.6, multiply: false)
            if settings.displaysXDRPauseNightShift, SystemToggles.nightShift == true {
                SystemToggles.setNightShift(false)
                pausedNightShift = true
            }
        }
        if watch == nil {
            watch = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                MainActor.assumeIsolated { XDRController.shared.checkLimits() }
            }
        }
        apply(display)
        // The range takes a moment to switch on; the factor is worked out again once it has.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reapply() }
        }
        DisplaySafety.shared.updatePanicHotKey()
    }

    private func apply(_ display: DisplayInfo) {
        guard let slider = sliders[display.id] else { return }
        let profile = DisplayManager.shared.profile(for: display)
        let headroom = screen(for: display.id)?.maximumExtendedDynamicRangeColorComponentValue
        // Until macOS has switched the range on there is nothing to go into.
        let engaged = (headroom ?? 1) > 1.05
        let factor = engaged ? XDRBoost.factor(slider: slider, sdrNits: sdrNits(of: display.id), limitNits: Double(profile.xdrMaxNits),
                                               headroom: headroom.map(Double.init)) : 1
        if factors[display.id] != factor { factors[display.id] = factor }
        if BrightnessController.shared.softwareMethod(for: display) == .overlay {
            // Where the colour table can't be used, a layer over the screen multiplies it instead.
            GammaController.shared.setBoost(1, for: display.id)
            guard factor > 1.001, let frame = screen(for: display.id)?.frame else {
                overlays.removeValue(forKey: display.id)?.close()
                return
            }
            if let overlay = overlays[display.id] {
                overlay.setFrame(frame)
                overlay.setValue(factor)
            } else {
                overlays[display.id] = EDRLayerWindow(frame: frame, value: factor, multiply: true)
            }
        } else {
            overlays.removeValue(forKey: display.id)?.close()
            GammaController.shared.setBoost(factor, for: display.id)
        }
    }

    private func reapply() {
        for id in sliders.keys {
            if let display = DisplayManager.shared.display(id) { apply(display) }
        }
    }

    func stop(_ display: CGDirectDisplayID) {
        guard sliders[display] != nil || triggers[display] != nil else { return }
        sliders[display] = nil
        factors[display] = nil
        GammaController.shared.setBoost(1, for: display)
        triggers.removeValue(forKey: display)?.close()
        overlays.removeValue(forKey: display)?.close()
        if sliders.isEmpty {
            watch?.invalidate()
            watch = nil
            if pausedNightShift {
                SystemToggles.setNightShift(true)
                pausedNightShift = false
            }
        }
        DisplaySafety.shared.updatePanicHotKey()
    }

    func stopAll() {
        for display in Set(sliders.keys).union(triggers.keys) { stop(display) }
    }

    private func limitReason() -> XDRBoost.StopReason? {
        let heat = ProcessInfo.processInfo.thermalState
        return XDRBoost.stopReason(battery: DisplayKeepAwake.battery(), minimumPercent: settings.displaysXDRBatteryMinimum,
                                   heatIsSerious: heat == .serious || heat == .critical, headroom: nil)
    }

    /// On a low battery or a hot Mac, boost goes off and says why.
    private func checkLimits() {
        guard isActive, let reason = limitReason() else { return }
        log.notice("XDR boost off: \(String(describing: reason), privacy: .public)")
        stopAll()
        stopReason = reason
        BrightnessController.shared.boostEnded()
    }

    private func displaysChanged() {
        let online = Set(DisplayManager.onlineDisplays())
        for gone in Set(sliders.keys).union(triggers.keys).subtracting(online) { stop(gone) }
        reapply()
    }
}
