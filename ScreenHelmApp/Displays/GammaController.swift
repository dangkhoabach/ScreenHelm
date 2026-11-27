import AppKit
import ScreenHelmCore
import Observation
import os

/// The one place that writes a display's colour table.
///
/// Software dimming, picture adjustments and XDR boost all change the same
/// table, so each hands its part here and the table written is their
/// product. Written separately they would undo each other.
@MainActor
@Observable
final class GammaController {
    static let shared = GammaController()

    /// Another app changed a table ScreenHelm had written (f.lux, another
    /// display utility). Shown at the top of every page; ScreenHelm doesn't
    /// fight for the table.
    private(set) var conflict = false

    @ObservationIgnored private var dimming: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var pictures: [CGDirectDisplayID: PictureAdjustment] = [:]
    @ObservationIgnored private var boosts: [CGDirectDisplayID: Double] = [:]
    /// Each display's own table, read before ScreenHelm first wrote to it.
    @ObservationIgnored private var bases: [CGDirectDisplayID: GammaTable.Channels] = [:]
    @ObservationIgnored private var written: [CGDirectDisplayID: GammaTable.Channels] = [:]
    @ObservationIgnored private var enforcer: NSWindow?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingReapply: DispatchWorkItem?
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DisplayManager.shared.onChange.append { [weak self] _ in self?.reapplyAfterReset(profileChanged: false) }
        // A colour profile chosen in System Settings replaces the table.
        // The name is the value of `kColorSyncDisplayDeviceProfilesNotification`.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.ColorSync.DisplayProfileNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { GammaController.shared.reapplyAfterReset(profileChanged: true) }
        }
    }

    /// Whether anything is applied to any display.
    var isActive: Bool { !written.isEmpty }

    func setDimming(_ value: Double, for display: CGDirectDisplayID) {
        dimming[display] = value >= 0.999 ? nil : value
        apply(to: display)
    }

    func setPicture(_ picture: PictureAdjustment, for display: CGDirectDisplayID) {
        pictures[display] = picture.withoutBrightnessAndBoost.isNeutral ? nil : picture
        apply(to: display)
    }

    func setBoost(_ factor: Double, for display: CGDirectDisplayID) {
        boosts[display] = factor <= 1.001 ? nil : factor
        apply(to: display)
    }

    func dimming(for display: CGDirectDisplayID) -> Double {
        dimming[display] ?? 1
    }

    /// What is in force for a display, all parts together.
    func adjustment(for display: CGDirectDisplayID) -> PictureAdjustment {
        var adjustment = pictures[display] ?? .neutral
        adjustment.brightness = dimming[display] ?? 1
        adjustment.boost = boosts[display] ?? 1
        return adjustment
    }

    /// Gives every display its own table back and forgets what was applied.
    func resetAll() {
        dimming = [:]
        pictures = [:]
        boosts = [:]
        written = [:]
        bases = [:]
        conflict = false
        pendingReapply?.cancel()
        CGDisplayRestoreColorSyncSettings()
        enforcer?.orderOut(nil)
        enforcer = nil
    }

    private func apply(to display: CGDirectDisplayID) {
        let wanted = adjustment(for: display)
        if wanted.isNeutral {
            guard written[display] != nil else { return }
            written[display] = nil
            if written.isEmpty { conflict = false }
            // The only call that gives a table back restores every display,
            // so the others are written again.
            CGDisplayRestoreColorSyncSettings()
            for other in written.keys { write(adjustment(for: other), to: other) }
            return
        }
        write(wanted, to: display)
    }

    private func write(_ adjustment: PictureAdjustment, to display: CGDirectDisplayID) {
        guard let base = bases[display] ?? Self.readTable(of: display) else { return }
        bases[display] = base
        let table = GammaTable.apply(adjustment, to: base)
        let result = CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue)
        guard result == .success else {
            log.error("colour table not written to \(display): \(result.rawValue)")
            return
        }
        written[display] = table
        nudge()
    }

    private static func readTable(of display: CGDirectDisplayID) -> GammaTable.Channels? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity)), green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 0 else { return nil }
        let n = Int(count)
        return GammaTable.Channels(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    /// After displays changed or the Mac woke, macOS may have put its own
    /// tables back; ScreenHelm's adjustments go on top again a second later,
    /// once things have settled. A table that is neither macOS's nor
    /// ScreenHelm's was written by another app and is left to it. A colour
    /// profile chosen in System Settings brings a new table of macOS's own:
    /// then every table is read again as the new starting point.
    private func reapplyAfterReset(profileChanged: Bool) {
        guard !written.isEmpty else {
            conflict = false
            return
        }
        pendingReapply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let displays = Set(DisplayManager.onlineDisplays())
            let wanted = Set(dimming.keys).union(pictures.keys).union(boosts.keys)
            for gone in wanted.subtracting(displays) {
                dimming[gone] = nil
                pictures[gone] = nil
                boosts[gone] = nil
                written[gone] = nil
                bases[gone] = nil
            }
            if profileChanged {
                written = [:]
                bases = [:]
                conflict = false
                CGDisplayRestoreColorSyncSettings()
                for display in wanted.intersection(displays) { write(adjustment(for: display), to: display) }
                return
            }
            var foreign = false
            for (display, table) in written {
                guard let now = Self.readTable(of: display), let base = bases[display] else { continue }
                // A table read back never goes above 1, whatever was written.
                let clipped = GammaTable.Channels(red: table.red.map { min(1, $0) }, green: table.green.map { min(1, $0) },
                                                  blue: table.blue.map { min(1, $0) })
                if GammaTable.matches(now, clipped) { continue }
                if GammaTable.matches(now, base) {
                    write(adjustment(for: display), to: display)
                } else {
                    // Moving ScreenHelm's slider again puts its part on top of the other app's table.
                    foreign = true
                    written[display] = nil
                    bases[display] = nil
                }
            }
            conflict = foreign
        }
        pendingReapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// A new table sometimes doesn't show until something on screen is
    /// drawn again. A one-pixel window changing its opacity by a hair is
    /// that something.
    private func nudge() {
        if enforcer == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
            window.backgroundColor = .black
            window.alphaValue = 0.01
            window.orderFrontRegardless()
            enforcer = window
        }
        enforcer?.alphaValue = enforcer?.alphaValue == 0.01 ? 0.02 : 0.01
    }
}

extension PictureAdjustment {
    /// The picture settings alone.
    var withoutBrightnessAndBoost: PictureAdjustment {
        var copy = self
        copy.brightness = 1
        copy.boost = 1
        return copy
    }
}

/// Dimming for displays with no backlight to turn down and, where the
/// colour table has no effect, for any display: a black window over
/// everything, more or less see-through.
@MainActor
final class DimOverlay {
    static let shared = DimOverlay()

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var levels: [CGDirectDisplayID: Double] = [:]
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DisplayManager.shared.onChange.append { [weak self] _ in self?.layout() }
    }

    var isActive: Bool { !levels.isEmpty }

    func dimming(for display: CGDirectDisplayID) -> Double {
        levels[display] ?? 1
    }

    /// 1 removes the window.
    func setDimming(_ value: Double, for display: CGDirectDisplayID) {
        levels[display] = value >= 0.999 ? nil : max(0, value)
        layout()
    }

    func removeAll() {
        levels = [:]
        layout()
    }

    /// Windows made, moved or closed to match `levels` and the screens there are now.
    private func layout() {
        // Gone, a display's level goes too: coming back, it gets what is
        // remembered for it, never darker than the floor.
        let online = Set(DisplayManager.onlineDisplays())
        levels = levels.filter { online.contains($0.key) }
        for (display, window) in windows where levels[display] == nil || screen(for: display) == nil {
            window.orderOut(nil)
            windows[display] = nil
        }
        for (display, level) in levels {
            guard let screen = screen(for: display) else { continue }
            let window = windows[display] ?? makeWindow()
            windows[display] = window
            window.setFrame(screen.frame, display: false)
            window.alphaValue = 1 - level
            window.orderFrontRegardless()
        }
    }

    private func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Above everything, full-screen apps and the menu bar included.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .black
        return window
    }
}
