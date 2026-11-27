import AppKit
import CoreImage
import CoreMedia
import ScreenHelmCore
import Observation
@preconcurrency import ScreenCaptureKit
import SwiftUI
import os

/// Live copies of displays and windows: picture in picture, and a display
/// shown across another one.
///
/// Each runs a ScreenCaptureKit stream at the size its picture is shown
/// at, not the source's, and stops capturing while its window can't be
/// seen. Frames go straight onto a layer and are never written anywhere.
@MainActor
@Observable
final class StreamController {
    static let shared = StreamController()

    private(set) var configs: [StreamConfig] = []
    private(set) var running: Set<UUID> = []
    /// Why a stream that was asked for isn't running.
    private(set) var failure: [UUID: LocalizedStringKey] = [:]

    @ObservationIgnored private var sessions: [UUID: StreamSession] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private var store: DisplayStore? { AppDatabase.shared.map { DisplayStore(dbQueue: $0.dbQueue) } }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // Only what the settings could have made: an edited or imported row may not be.
        configs = ((try? store?.load(StreamConfig.self, from: .stream)) ?? [:]).values.filter(\.isValid)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DisplayManager.shared.onChange.append { [weak self] _ in self?.displaysChanged() }
    }

    // MARK: - The list

    @discardableResult
    func add(source: StreamConfig.Source, name: String) -> StreamConfig {
        let config = StreamConfig(name: name, source: source)
        configs.append(config)
        save(config)
        return config
    }

    /// Only a valid stream is kept; one that is running picks the change up.
    func update(_ config: StreamConfig) {
        guard config.isValid, let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        let old = configs[index]
        configs[index] = config
        save(config)
        guard let session = sessions[config.id] else { return }
        // What decides the capture or the window it is shown in starts the stream again; the rest is applied to the picture.
        if old.source != config.source || old.target != config.target || old.framesPerSecond != config.framesPerSecond
            || old.showsCursor != config.showsCursor || old.hdr != config.hdr {
            stop(config.id)
            start(config.id)
        } else {
            session.apply(config)
            updatePointer()
        }
    }

    func delete(_ id: UUID) {
        stop(id)
        configs.removeAll { $0.id == id }
        try? store?.delete(key: id.uuidString, from: .stream)
    }

    private func save(_ config: StreamConfig) {
        do { try store?.save(config, key: config.id.uuidString, in: .stream) } catch {
            log.error("stream not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Running

    func toggle(_ id: UUID) {
        running.contains(id) ? stop(id) : start(id)
    }

    func start(_ id: UUID) {
        guard sessions[id] == nil, let config = configs.first(where: { $0.id == id }) else { return }
        guard Permissions.shared.screenRecording else {
            failure[id] = "This needs the Screen Recording permission."
            return
        }
        failure[id] = nil
        let session = StreamSession(config: config) { [weak self] reason in
            // The source went away, or macOS stopped the capture.
            self?.sessions[id] = nil
            self?.running.remove(id)
            self?.updatePointer()
            if let reason { self?.failure[id] = reason }
            DisplaySafety.shared.updatePanicHotKey()
        }
        sessions[id] = session
        running.insert(id)
        session.start()
        updatePointer()
        DisplaySafety.shared.updatePanicHotKey()
    }

    func stop(_ id: UUID) {
        sessions.removeValue(forKey: id)?.close()
        running.remove(id)
        updatePointer()
        DisplaySafety.shared.updatePanicHotKey()
    }

    /// The displays covered by a running stream that hides the pointer there.
    private func updatePointer() {
        let displays = sessions.values.compactMap { session -> CGDirectDisplayID? in
            guard session.config.hidesPointerOnTarget, case .display(let key) = session.config.target else { return nil }
            return DisplayManager.shared.display(key: key)?.id
        }
        PointerHider.shared.hide(over: Set(displays))
    }

    func stopAll() {
        for id in running { stop(id) }
    }

    /// The frames a running stream has shown, for tests of whether it shows any.
    func frameCount(_ id: UUID) -> Int {
        sessions[id]?.frameCount ?? 0
    }

    /// A stream whose source or target display is gone stops.
    private func displaysChanged() {
        let keys = Set(DisplayManager.shared.displays.map(\.key))
        for (id, session) in sessions {
            var needed: [String] = []
            if case .display(let key) = session.config.source { needed.append(key) }
            if case .display(let key) = session.config.target { needed.append(key) }
            if !needed.allSatisfy(keys.contains) { stop(id) } else { session.displaysChanged() }
        }
        updatePointer()
    }
}

/// One running stream: the capture and the window it is shown in.
@MainActor
final class StreamSession: NSObject, SCStreamDelegate, NSWindowDelegate {
    private(set) var config: StreamConfig
    private let window: StreamWindow
    private let sink: StreamFrameSink
    private var stream: SCStream?
    private var isStarting = false
    private var closed = false
    private var sourcePixels = CGSize(width: 1920, height: 1080)
    private var captured = CGSize.zero
    /// The window shown, when the source is one, and the size it had: a
    /// window made larger or smaller is captured again at its new shape.
    private var sourceWindow: (id: CGWindowID, size: CGSize)?
    private var sourceWatch: Timer?
    /// The source display's size when its capture started.
    private var sourceDisplaySize = CGSize.zero
    private let onEnd: (LocalizedStringKey?) -> Void

    var frameCount: Int { sink.frameCount }

    init(config: StreamConfig, onEnd: @escaping (LocalizedStringKey?) -> Void) {
        self.config = config
        self.onEnd = onEnd
        window = StreamWindow(config: config)
        sink = StreamFrameSink(layer: window.pictureLayer)
        super.init()
        window.delegate = self
        window.onClose = { [weak self] in self?.end(nil) }
    }

    func start() {
        layout()
        window.show()
        startCapture()
    }

    /// The parts of a change that only touch how the picture is shown.
    func apply(_ config: StreamConfig) {
        self.config = config
        window.apply(config, sourcePixels: sourcePixels)
        restartIfSizeChanged()
    }

    /// The window put where it belongs: over its target display, or left where the user dragged it.
    func layout() {
        window.place(config: config, sourcePixels: sourcePixels)
    }

    /// A source display at a new resolution or turned is measured and
    /// captured again; a target display at a new size gets a capture to match.
    func displaysChanged() {
        layout()
        if case .display(let key) = config.source, let id = DisplayManager.shared.display(key: key)?.id, stream != nil,
           CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)) != sourceDisplaySize {
            return restartCapture()
        }
        restartIfSizeChanged()
    }

    private func restartCapture() {
        stopCapture()
        startCapture()
    }

    private func watchSourceWindow() {
        sourceWatch?.invalidate()
        guard sourceWindow != nil else { return }
        sourceWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let watched = self.sourceWindow, self.stream != nil else { return }
                let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, watched.id) as? [[String: Any]]
                guard let bounds = info?.first?[kCGWindowBounds as String] as? [String: CGFloat],
                      let width = bounds["Width"], let height = bounds["Height"] else { return }
                if abs(width - watched.size.width) > 1 || abs(height - watched.size.height) > 1 { self.restartCapture() }
            }
        }
        sourceWatch?.tolerance = 0.3
    }

    func close() {
        closed = true
        sourceWatch?.invalidate()
        sourceWatch = nil
        stopCapture()
        window.onClose = nil
        window.orderOut(nil)
        window.close()
    }

    private func end(_ reason: LocalizedStringKey?) {
        guard !closed else { return }
        close()
        onEnd(reason)
    }

    // MARK: Capture

    private func startCapture() {
        guard stream == nil, !isStarting, !closed else { return }
        isStarting = true
        let config = config
        let own = window.windowNumber
        Task {
            defer { isStarting = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
                return end("The screen can't be captured. Check the Screen Recording permission.")
            }
            let filter: SCContentFilter
            switch config.source {
            case .display(let key):
                guard let id = DisplayManager.shared.display(key: key)?.id, let display = content.displays.first(where: { $0.displayID == id })
                else { return end("The display to show isn't connected.") }
                // Without this the picture would show itself, smaller each time.
                let streamWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                    .filter { NSApp.window(withWindowNumber: Int($0.windowID)) is StreamWindow || Int($0.windowID) == own }
                filter = SCContentFilter(display: display, excludingWindows: streamWindows)
                sourceWindow = nil
                sourceDisplaySize = CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
                sourcePixels = CGSize(width: CGFloat(CGDisplayPixelsWide(id)) * CGFloat(filter.pointPixelScale),
                                      height: CGFloat(CGDisplayPixelsHigh(id)) * CGFloat(filter.pointPixelScale))
            case .window(let bundleID, let title):
                let candidates = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width > 60 }
                guard let source = candidates.first(where: { title.isEmpty || $0.title == title }) ?? candidates.first
                else { return end("The window to show isn't open.") }
                filter = SCContentFilter(desktopIndependentWindow: source)
                sourceWindow = (source.windowID, source.frame.size)
                sourcePixels = CGSize(width: source.frame.width * CGFloat(filter.pointPixelScale), height: source.frame.height * CGFloat(filter.pointPixelScale))
            }
            guard !closed else { return }
            window.apply(config, sourcePixels: sourcePixels)
            layout()

            let size = StreamGeometry.captureSize(shown: window.pictureSize, scale: Double(window.backingScaleFactor), crop: config.crop,
                                                  sourcePixels: sourcePixels)
            let configuration: SCStreamConfiguration
            if config.hdr, #available(macOS 15.0, *) {
                // Sets the dynamic range, pixel format and color space for showing on this Mac's displays.
                configuration = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
            } else {
                configuration = SCStreamConfiguration()
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
            }
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(clamping: max(1, config.framesPerSecond)))
            configuration.showsCursor = config.showsCursor
            configuration.queueDepth = 3
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: StreamFrameSink.queue)
                try await stream.startCapture()
            } catch {
                return end("The screen can't be captured. Check the Screen Recording permission.")
            }
            guard !closed, window.isVisibleOnScreen else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            captured = size
            watchSourceWindow()
        }
    }

    private func stopCapture() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    /// A window made much larger or smaller is captured again at its new size.
    private func restartIfSizeChanged() {
        guard stream != nil else { return }
        let wanted = StreamGeometry.captureSize(shown: window.pictureSize, scale: Double(window.backingScaleFactor), crop: config.crop,
                                                sourcePixels: sourcePixels)
        guard abs(wanted.width - captured.width) > captured.width * 0.25 else { return }
        stopCapture()
        startCapture()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.stream = nil
            self.end("The picture stopped: what it showed is gone.")
        }
    }

    // MARK: Window

    /// Nothing is captured while the picture can't be seen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.isVisibleOnScreen { startCapture() } else { stopCapture() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        window.apply(config, sourcePixels: sourcePixels)
        restartIfSizeChanged()
    }

    func windowDidResize(_ notification: Notification) {
        window.apply(config, sourcePixels: sourcePixels)
    }
}

/// Puts each new frame on the layer; ScreenCaptureKit calls it on its own queue.
private final class StreamFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    static let queue = DispatchQueue(label: "com.dangkhoabach.screenhelm.stream")
    private let layer: CALayer
    /// Read and changed on the main thread only.
    private(set) var frameCount = 0

    init(layer: CALayer) {
        self.layer = layer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        nonisolated(unsafe) let surface = frame
        let layer = layer
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
            self.frameCount += 1
        }
    }
}

/// The window a stream is shown in: a small one that floats over
/// everything, or one that covers a display.
final class StreamWindow: NSWindow {
    let pictureLayer = CALayer()
    private let container = NSView()
    var onClose: (() -> Void)?
    private var placedForTarget: StreamConfig.Target?

    init(config: StreamConfig) {
        let floating = config.target == .floatingWindow
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                   styleMask: floating ? [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel] : [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = config.name
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = floating
        backgroundColor = .black
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        level = floating ? .floating : NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }

        container.wantsLayer = true
        container.layerUsesCoreImageFilters = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        pictureLayer.contentsGravity = .resize
        pictureLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pictureLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        container.layer?.addSublayer(pictureLayer)
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var pictureSize: CGSize { pictureLayer.bounds.size }
    var isVisibleOnScreen: Bool { isVisible && occlusionState.contains(.visible) }

    func show() {
        orderFrontRegardless()
    }

    override func close() {
        super.close()
        onClose?()
    }

    /// Over the whole target display; a floating window is sized to the picture's shape once and then left alone.
    func place(config: StreamConfig, sourcePixels: CGSize) {
        let aspect = StreamGeometry.aspect(sourceSize: sourcePixels, crop: config.crop, rotation: config.rotation)
        switch config.target {
        case .display(let key):
            guard let id = DisplayManager.shared.display(key: key)?.id,
                  let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id })
            else { return }
            setFrame(screen.frame, display: true)
        case .floatingWindow:
            contentAspectRatio = NSSize(width: aspect, height: 1)
            guard placedForTarget != config.target else { break }
            let screen = NSScreen.main?.visibleFrame ?? .zero
            let width = min(480, screen.width / 3)
            setFrame(NSRect(x: screen.maxX - width - 24, y: screen.minY + 24, width: width, height: width / aspect), display: true)
        }
        placedForTarget = config.target
        apply(config, sourcePixels: sourcePixels)
    }

    func apply(_ config: StreamConfig, sourcePixels: CGSize) {
        ignoresMouseEvents = config.clickThrough || config.target != .floatingWindow
        let bounds = container.bounds
        let aspect = StreamGeometry.aspect(sourceSize: sourcePixels, crop: config.crop, rotation: config.rotation)
        let frame = StreamGeometry.frame(aspect: aspect, in: bounds.size, scaling: config.target == .floatingWindow ? .fit : config.scaling)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer is laid out unturned, then turned about its center: a quarter turn swaps its sides.
        let turned = config.rotation % 180 != 0
        pictureLayer.bounds = CGRect(x: 0, y: 0, width: turned ? frame.height : frame.width, height: turned ? frame.width : frame.height)
        pictureLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        pictureLayer.setAffineTransform(StreamGeometry.transform(rotation: config.rotation, flipHorizontal: config.flipHorizontal,
                                                                 flipVertical: config.flipVertical))
        pictureLayer.contentsRect = StreamGeometry.contentsRect(for: config.crop)
        pictureLayer.filters = StreamFilterBuilder.filters(for: config.filters)
        if #available(macOS 26.0, *) {
            pictureLayer.preferredDynamicRange = config.hdr ? .high : .standard
        } else {
            pictureLayer.wantsExtendedDynamicRangeContent = config.hdr
        }
        CATransaction.commit()
    }
}

/// Hides the pointer while it is over one of the given displays: a
/// display shown across another one doesn't need a second pointer on it.
@MainActor
final class PointerHider {
    static let shared = PointerHider()

    private(set) var displays: Set<CGDirectDisplayID> = []
    private var monitors: [Any] = []
    /// Hiding and showing are counted by the window server, so they stay paired.
    private(set) var isHidden = false

    private init() {}

    func hide(over displays: Set<CGDirectDisplayID>) {
        guard displays != self.displays else { return }
        self.displays = displays
        if displays.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        } else if monitors.isEmpty {
            DisplayPrivateAPIs.allowPointerHidingInBackground()
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
                MainActor.assumeIsolated { PointerHider.shared.update() }
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
                MainActor.assumeIsolated { PointerHider.shared.update() }
                return event
            }) { monitors.append(local) }
        }
        update()
    }

    private func update() {
        let wanted = !displays.isEmpty && displays.contains { CGDisplayBounds($0).contains(Self.pointerLocation) }
        guard wanted != isHidden else { return }
        isHidden = wanted
        if wanted { CGDisplayHideCursor(CGMainDisplayID()) } else { CGDisplayShowCursor(CGMainDisplayID()) }
    }

    /// In global display coordinates, whose origin is the main display's top left.
    private static var pointerLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

/// Core Image filters for a stream's layer.
@MainActor
enum StreamFilterBuilder {
    private static var lutCache: [String: CIFilter] = [:]
    /// Files that couldn't be read, by when they were last changed: tried
    /// again only once they change, not on every redraw.
    private static var lutFailures: [String: Date] = [:]

    static func filters(for settings: StreamFilters) -> [CIFilter] {
        var filters: [CIFilter] = []
        if let path = settings.lutPath, let lut = lut(at: path) { filters.append(lut) }
        if settings.monochrome || settings.saturation != 1 {
            let filter = CIFilter(name: "CIColorControls")
            filter?.setDefaults()
            filter?.setValue(settings.monochrome ? 0 : settings.saturation, forKey: kCIInputSaturationKey)
            if let filter { filters.append(filter) }
        }
        if settings.hue != 0, let filter = CIFilter(name: "CIHueAdjust") {
            filter.setValue(settings.hue * .pi / 180, forKey: kCIInputAngleKey)
            filters.append(filter)
        }
        if settings.invert, let filter = CIFilter(name: "CIColorInvert") { filters.append(filter) }
        if settings.sharpen > 0, let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(settings.sharpen, forKey: kCIInputSharpnessKey)
            filters.append(filter)
        }
        if settings.blur > 0, let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(settings.blur, forKey: kCIInputRadiusKey)
            filters.append(filter)
        }
        return filters
    }

    /// A .cube file as a colour-cube filter; read once per path.
    private static func lut(at path: String) -> CIFilter? {
        if let cached = lutCache[path] { return cached }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
        if let failed = lutFailures[path], failed == modified { return nil }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let cube = CubeLUT(parsing: text),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            lutFailures[path] = modified
            return nil
        }
        filter.setValue(cube.size, forKey: "inputCubeDimension")
        filter.setValue(cube.values.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        lutCache[path] = filter
        return filter
    }
}
