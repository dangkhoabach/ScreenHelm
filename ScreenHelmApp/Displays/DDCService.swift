import CoreGraphics
import ScreenHelmCore
import Foundation
import Observation
import os

/// Talks DDC to monitors, off the main thread, one monitor at a time.
///
/// Each monitor has its own queue. While a slider is dragged only the
/// newest value of a setting waits to be sent: the ones in between are
/// dropped, since a write takes 20 to 50 ms and a monitor that falls
/// behind keeps moving after the hand has stopped.
actor DDCService {
    static let shared = DDCService()

    private var transports: [CGDirectDisplayID: any DDCTransport] = [:]
    private var waiting: [CGDirectDisplayID: [UInt8: UInt16]] = [:]
    private var draining: Set<CGDirectDisplayID> = []
    private var settings: [CGDirectDisplayID: DDCSettings] = [:]
    /// Writes sent, for tests of how many a drag turns into.
    private(set) var writesSent = 0

    func setTransports(_ transports: [CGDirectDisplayID: any DDCTransport]) {
        self.transports = transports
        waiting = waiting.filter { transports[$0.key] != nil }
    }

    func setSettings(_ settings: DDCSettings, for display: CGDirectDisplayID) {
        self.settings[display] = settings
    }

    func hasTransport(for display: CGDirectDisplayID) -> Bool {
        transports[display] != nil
    }

    /// Queues a value; a later one for the same setting replaces it if it
    /// hasn't gone out yet. Codes outside ScreenHelm's own list are refused
    /// unless the caller says the user allowed any.
    func write(_ code: UInt8, value: UInt16, to display: CGDirectDisplayID, allowingAnyCode: Bool = false) {
        guard transports[display] != nil, DDCPacket.mayWrite(code, allowingAnyCode: allowingAnyCode),
              settings[display]?.enabled != false else { return }
        waiting[display, default: [:]][code] = value
        guard !draining.contains(display) else { return }
        draining.insert(display)
        Task { await drain(display) }
    }

    private func drain(_ display: CGDirectDisplayID) async {
        while let (code, value) = waiting[display]?.first, let transport = transports[display] {
            waiting[display]?[code] = nil
            let settings = settings[display] ?? DDCSettings()
            let packet = DDCPacket.setVCP(code, value: value)
            for _ in 0..<max(1, settings.writeCount) {
                try? await Task.sleep(for: .milliseconds(settings.writeDelay))
                _ = transport.write(packet)
            }
            writesSent += 1
        }
        draining.remove(display)
    }

    /// Asks the monitor for a setting. Reading is slow and often fails, so
    /// it is tried a few times and the caller keeps what it gets.
    func read(_ code: UInt8, from display: CGDirectDisplayID) async -> VCPValue? {
        guard let transport = transports[display] else { return nil }
        let settings = settings[display] ?? DDCSettings()
        guard settings.enabled else { return nil }
        for attempt in 0...max(0, settings.readRetries) {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(settings.writeDelay))
            guard transport.write(DDCPacket.getVCP(code)) else { continue }
            try? await Task.sleep(for: .milliseconds(settings.readDelay))
            guard let reply = transport.read(length: DDCPacket.replyLength) else { continue }
            switch DDCPacket.parseReply(reply, for: code, ignoringChecksum: settings.ignoreReadChecksum) {
            case .success(let value): return value
            case .failure(.unsupported): return nil // The monitor answered: it has no such setting.
            case .failure: continue
            }
        }
        return nil
    }

    /// Waits until everything queued for a display has gone out.
    func flush(_ display: CGDirectDisplayID) async {
        while draining.contains(display) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// What the interface knows about each monitor's DDC: whether it answers,
/// and the last value of each setting. Values are remembered rather than
/// read each time.
@MainActor
@Observable
final class DDCController {
    static let shared = DDCController()

    /// Displays with a DDC port that ScreenHelm found.
    private(set) var available: Set<CGDirectDisplayID> = []
    private(set) var values: [CGDirectDisplayID: [UInt8: VCPValue]] = [:]

    @ObservationIgnored private var ports: [CGDirectDisplayID: AppleSiliconDDCTransport] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var saveWork: [CGDirectDisplayID: DispatchWorkItem] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DisplayManager.shared.onChange.append { [weak self] _ in self?.rediscover() }
        rediscover()
    }

    /// Finds the ports again; called when displays change and from "Try DDC again".
    func rediscover() {
        let displays = DisplayManager.shared.displays.filter { $0.kind == .external || $0.kind == .tv }
        guard !displays.isEmpty else {
            available = []
            ports = [:]
            Task { await DDCService.shared.setTransports([:]) }
            return
        }
        let ports = DDCDiscovery.externalPorts()
        let candidates = displays.map {
            DDCDiscovery.Candidate(id: $0.id, location: $0.identity.location, vendor: $0.identity.vendor, product: $0.identity.product,
                                   name: $0.systemName, serial: $0.identity.alphanumericSerial)
        }
        let matched = DDCDiscovery.match(candidates, to: ports)
        var transports: [CGDirectDisplayID: any DDCTransport] = [:]
        for (display, port) in matched { transports[display] = ports[port].transport }
        self.ports = matched.mapValues { ports[$0].transport }
        available = Set(transports.keys)
        log.info("DDC ports: \(ports.count), matched to displays: \(matched.count)")
        Task {
            await DDCService.shared.setTransports(transports)
            for display in displays where transports[display.id] != nil {
                let profile = DisplayManager.shared.profile(for: display)
                await DDCService.shared.setSettings(profile.ddc, for: display.id)
                await seed(display, profile: profile)
            }
        }
    }

    /// What a monitor is set to when it connects: asked once where it
    /// answers, otherwise what ScreenHelm last wrote.
    private func seed(_ display: DisplayInfo, profile: DisplayProfile) async {
        let before = values[display.id] ?? [:]
        var seeded: [UInt8: VCPValue] = [:]
        for code in [VCPCode.brightness, .contrast, .volume] {
            if let value = await DDCService.shared.read(code.rawValue, from: display.id) {
                seeded[code.rawValue] = value
            } else if let last = profile.ddcValues[code.rawValue] {
                seeded[code.rawValue] = VCPValue(current: last, maximum: before[code.rawValue]?.maximum ?? 100)
            }
        }
        for (code, value) in profile.ddcValues where seeded[code] == nil {
            seeded[code] = VCPValue(current: value, maximum: before[code]?.maximum ?? 100)
        }
        // A value set while the monitor was being asked is newer than its answer.
        for (code, value) in values[display.id] ?? [:] where before[code] != value { seeded[code] = value }
        values[display.id] = seeded
    }

    /// The display's EDID, read from its port; nil for displays without one.
    func edid(of display: DisplayInfo) -> Data? {
        ports[display.id]?.edid()
    }

    func isAvailable(_ display: DisplayInfo) -> Bool {
        available.contains(display.id) && DisplayManager.shared.profile(for: display).ddc.enabled
    }

    /// Whether the monitor is known to have a setting: it answered a read
    /// of it, or the user has set it before.
    func supports(_ code: VCPCode, on display: DisplayInfo) -> Bool {
        values[display.id]?[code.rawValue] != nil
    }

    /// 0…1 of the monitor's range; nil when the value isn't known.
    func fraction(_ code: VCPCode, on display: DisplayInfo) -> Double? {
        values[display.id]?[code.rawValue]?.fraction
    }

    func value(_ code: VCPCode, on display: DisplayInfo) -> UInt16? {
        values[display.id]?[code.rawValue]?.current
    }

    func setFraction(_ fraction: Double, for code: VCPCode, on display: DisplayInfo) {
        let maximum = values[display.id]?[code.rawValue]?.maximum ?? 100
        set(DDCPacket.value(for: fraction, maximum: maximum == 0 ? 100 : maximum), for: code, on: display)
    }

    func set(_ value: UInt16, for code: VCPCode, on display: DisplayInfo) {
        guard isAvailable(display) else { return }
        let maximum = values[display.id]?[code.rawValue]?.maximum ?? 100
        values[display.id, default: [:]][code.rawValue] = VCPValue(current: value, maximum: maximum)
        Task { await DDCService.shared.write(code.rawValue, value: value, to: display.id) }
        // Remembered for the next connection, once the dragging stops.
        saveWork[display.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = DisplayManager.shared.display(display.id), let known = values[display.id] else { return }
            DisplayManager.shared.updateProfile(of: current) { $0.ddcValues = known.mapValues(\.current) }
        }
        saveWork[display.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The input is switched with LG's code on monitors set to need it.
    func setInput(_ input: DDCInput, on display: DisplayInfo) {
        let code: VCPCode = DisplayManager.shared.profile(for: display).ddc.lgInputCode ? .lgInputSource : .inputSource
        set(input.value, for: code, on: display)
    }

    func updateSettings(of display: DisplayInfo, _ change: (inout DDCSettings) -> Void) {
        DisplayManager.shared.updateProfile(of: display) { change(&$0.ddc) }
        let settings = DisplayManager.shared.profile(for: display).ddc
        Task { await DDCService.shared.setSettings(settings, for: display.id) }
    }
}
