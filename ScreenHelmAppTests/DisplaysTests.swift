import AppKit
import Carbon.HIToolbox
import ScreenHelmCore
import SwiftUI
import Testing
@testable import ScreenHelm

/// Defaults kept in memory, so nothing is written to ~/Library/Preferences.
private final class DisplayMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

private func memoryDefaults() -> UserDefaults {
    DisplayMemoryDefaults(suiteName: "com.dangkhoabach.screenhelm.tests.displays")!
}

@MainActor
@Suite(.serialized)
struct DisplaySafetyTests {
    @Test func aChangeNotKeptIsUndoneWhenTheCountdownEnds() {
        let safety = DisplaySafety(defaults: memoryDefaults())
        var reverted = false, kept = false
        safety.confirm(title: "Test", signature: "mode:test:1", revert: { reverted = true }, onKeep: { kept = true })
        #expect(safety.hasPendingChange)
        #expect(safety.secondsLeft == DisplaySafety.confirmationSeconds)
        for _ in 0..<(DisplaySafety.confirmationSeconds - 1) { safety.tick() }
        #expect(!reverted && safety.secondsLeft == 1)
        safety.tick()
        #expect(reverted && !kept)
        #expect(!safety.hasPendingChange && safety.secondsLeft == nil)
    }

    @Test func aKeptChangeIsNotAskedAboutAgain() {
        let safety = DisplaySafety(defaults: memoryDefaults())
        var reverted = 0, kept = 0
        safety.confirm(title: "Test", signature: "mode:test:2", revert: { reverted += 1 }, onKeep: { kept += 1 })
        safety.keepPending()
        #expect(kept == 1 && reverted == 0 && !safety.hasPendingChange)
        // The same change again is kept at once; another one is asked about.
        safety.confirm(title: "Test", signature: "mode:test:2", revert: { reverted += 1 }, onKeep: { kept += 1 })
        #expect(kept == 2 && !safety.hasPendingChange)
        safety.confirm(title: "Test", signature: "mode:test:3", revert: { reverted += 1 }, onKeep: { kept += 1 })
        #expect(safety.hasPendingChange)
        safety.revertPending()
        #expect(reverted == 1 && kept == 2)
        // Undone, so it is asked about next time too.
        safety.confirm(title: "Test", signature: "mode:test:3", revert: { reverted += 1 }, onKeep: { kept += 1 })
        #expect(safety.hasPendingChange)
        safety.revertPending()
    }

    /// A second change while one is waiting settles the first as it stands.
    @Test func aSecondChangeKeepsTheFirst() {
        let safety = DisplaySafety(defaults: memoryDefaults())
        var firstReverted = false, firstKept = false, secondReverted = false
        safety.confirm(title: "One", signature: "a", revert: { firstReverted = true }, onKeep: { firstKept = true })
        safety.confirm(title: "Two", signature: "b", revert: { secondReverted = true })
        #expect(firstKept && !firstReverted)
        #expect(safety.pendingTitle == "Two")
        safety.revertPending()
        #expect(secondReverted)
    }

    @Test func panicUndoesThePendingChangeAndRunsEveryAction() {
        let safety = DisplaySafety(defaults: memoryDefaults())
        var reverted = false, dropped = 0
        safety.panicActions = [{ dropped += 1 }, { dropped += 1 }]
        safety.confirm(title: "Test", signature: "c", revert: { reverted = true })
        safety.panic()
        #expect(reverted && dropped == 2 && !safety.hasPendingChange)
    }

    /// The shortcut is held only while something is applied or waiting.
    @Test func thePanicShortcutComesAndGoes() {
        let safety = DisplaySafety(defaults: memoryDefaults())
        var active = false
        safety.activityChecks = [{ active }]
        safety.updatePanicHotKey()
        #expect(!safety.panicHotKeyIsRegistered)
        active = true
        safety.updatePanicHotKey()
        // The app under test may already hold it for something really applied.
        let held = DisplaySafety.shared.panicHotKeyIsRegistered
        #expect(safety.panicHotKeyIsRegistered || held)
        active = false
        safety.updatePanicHotKey()
        #expect(!safety.panicHotKeyIsRegistered)
    }

    @Test func aStartThatEndedWhileApplyingIsFollowedByASafeOne() {
        let defaults = memoryDefaults()
        let first = DisplaySafety(defaults: defaults)
        first.beginLaunch(shiftHeld: false)
        #expect(!first.isSafeMode)
        first.guardLaunch(settle: 60) // The app "ends" before this passes.

        let second = DisplaySafety(defaults: defaults)
        second.beginLaunch(shiftHeld: false)
        #expect(second.isSafeMode && second.safeModeFollowsCrash)
        second.guardLaunch() // Leaves no mark in safe mode.

        let third = DisplaySafety(defaults: defaults)
        third.beginLaunch(shiftHeld: false)
        #expect(!third.isSafeMode)

        // Quitting the ordinary way right after launch is not a start that went wrong.
        third.guardLaunch(settle: 60)
        third.endLaunchGuard()
        let fourth = DisplaySafety(defaults: defaults)
        fourth.beginLaunch(shiftHeld: false)
        #expect(!fourth.isSafeMode)
    }

    @Test func shiftAtLaunchIsASafeStart() {
        let safety = DisplaySafety(defaults: memoryDefaults())
        safety.beginLaunch(shiftHeld: true)
        #expect(safety.isSafeMode && !safety.safeModeFollowsCrash)
        safety.leaveSafeMode()
        #expect(!safety.isSafeMode)
    }
}

/// A monitor made of code: remembers what it is sent, answers reads, and
/// can be told to fail.
private final class FakeMonitor: DDCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [UInt8: UInt16] = [0x10: 70, 0x12: 50, 0x62: 30]
    private var _writes: [[UInt8]] = []
    private var lastRequested: UInt8?
    private var _failuresLeft = 0
    var answers = true
    var corruptChecksum = false

    var values: [UInt8: UInt16] { lock.withLock { _values } }
    var writes: [[UInt8]] { lock.withLock { _writes } }
    func failNextReads(_ count: Int) { lock.withLock { _failuresLeft = count } }

    func write(_ bytes: [UInt8]) -> Bool {
        lock.withLock {
            _writes.append(bytes)
            if bytes.count == 6, bytes[0] == 0x84 { _values[bytes[2]] = UInt16(bytes[3]) << 8 | UInt16(bytes[4]) }
            if bytes.count == 4, bytes[0] == 0x82 { lastRequested = bytes[2] }
            return true
        }
    }

    func read(length: Int) -> [UInt8]? {
        lock.withLock {
            guard answers, let code = lastRequested else { return [UInt8](repeating: 0, count: length) }
            if _failuresLeft > 0 {
                _failuresLeft -= 1
                return nil
            }
            guard let value = _values[code] else {
                var bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x01, code, 0, 0, 0, 0, 0]
                bytes.append(bytes.reduce(0x50, ^))
                return bytes
            }
            var bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, code, 0x00, 0x00, 100, UInt8(value >> 8), UInt8(value & 0xFF)]
            bytes.append(bytes.reduce(0x50, ^) ^ (corruptChecksum ? 0xFF : 0))
            return bytes
        }
    }
}

@Suite(.serialized)
struct DDCServiceTests {
    private let display: CGDirectDisplayID = 9001
    private let fast = DDCSettings(writeDelay: 2, readDelay: 2, writeCount: 2, readRetries: 4)

    private func service(_ monitor: FakeMonitor, settings: DDCSettings? = nil) async -> DDCService {
        let service = DDCService()
        await service.setTransports([display: monitor])
        await service.setSettings(settings ?? fast, for: display)
        return service
    }

    @Test func aWriteReachesTheMonitorTwice() async {
        let monitor = FakeMonitor()
        let service = await service(monitor)
        await service.write(0x10, value: 42, to: display)
        await service.flush(display)
        #expect(monitor.values[0x10] == 42)
        #expect(monitor.writes == [DDCPacket.setVCP(0x10, value: 42), DDCPacket.setVCP(0x10, value: 42)])
    }

    /// Dragging a slider sends a hundred values; the monitor gets a few,
    /// and the last one for certain.
    @Test func aDragIsThinnedToItsNewestValue() async {
        let monitor = FakeMonitor()
        let service = await service(monitor)
        for value in UInt16(0)...100 { await service.write(0x10, value: value, to: display) }
        await service.flush(display)
        #expect(monitor.values[0x10] == 100)
        let sent = await service.writesSent
        #expect(sent < 20, "sent \(sent) of 101")
    }

    @Test func settingsOfOneMonitorDontWaitOnEachOther() async {
        let monitor = FakeMonitor()
        let service = await service(monitor)
        await service.write(0x10, value: 10, to: display)
        await service.write(0x62, value: 20, to: display)
        await service.write(0x12, value: 30, to: display)
        await service.flush(display)
        #expect(monitor.values[0x10] == 10 && monitor.values[0x62] == 20 && monitor.values[0x12] == 30)
    }

    @Test func codesOutsideTheListAreRefused() async {
        let monitor = FakeMonitor()
        let service = await service(monitor)
        await service.write(0x04, value: 1, to: display) // factory reset
        await service.flush(display)
        #expect(monitor.writes.isEmpty)
        await service.write(0x04, value: 1, to: display, allowingAnyCode: true)
        await service.flush(display)
        #expect(monitor.writes.count == 2)
    }

    @Test func nothingIsSentWhenDDCIsOffForTheMonitor() async {
        let monitor = FakeMonitor()
        let service = await service(monitor, settings: DDCSettings(enabled: false))
        await service.write(0x10, value: 42, to: display)
        await service.flush(display)
        #expect(monitor.writes.isEmpty)
        #expect(await service.read(0x10, from: display) == nil)
    }

    @Test func aReadIsTriedAgainUntilItAnswers() async {
        let monitor = FakeMonitor()
        let service = await service(monitor)
        monitor.failNextReads(3)
        #expect(await service.read(0x10, from: display) == VCPValue(current: 70, maximum: 100))
        monitor.failNextReads(9)
        #expect(await service.read(0x10, from: display) == nil)
    }

    @Test func aMonitorThatDoesNotAnswerGivesNothing() async {
        let monitor = FakeMonitor()
        monitor.answers = false
        let service = await service(monitor)
        #expect(await service.read(0x10, from: display) == nil)
        #expect(await service.read(0x10, from: 12345) == nil)
    }

    @Test func aSettingTheMonitorLacksIsNotRetried() async {
        let monitor = FakeMonitor()
        let service = await service(monitor)
        #expect(await service.read(0x16, from: display) == nil)
        // One request, not five.
        #expect(monitor.writes.count == 1)
    }

    @Test func aWrongChecksumIsTakenOnlyWhenAllowed() async {
        let monitor = FakeMonitor()
        monitor.corruptChecksum = true
        let strict = await service(monitor)
        #expect(await strict.read(0x10, from: display) == nil)
        let lenient = await service(monitor, settings: DDCSettings(writeDelay: 2, readDelay: 2, ignoreReadChecksum: true))
        #expect(await lenient.read(0x10, from: display) == VCPValue(current: 70, maximum: 100))
    }
}

@MainActor
@Suite struct DDCDiscoveryTests {
    private func candidate(_ id: CGDirectDisplayID, location: String = "", vendor: UInt32 = 0x10AC, product: UInt32 = 0xA0F1,
                           name: String = "DELL U2723QE", serial: String = "") -> DDCDiscovery.Candidate {
        .init(id: id, location: location, vendor: vendor, product: product, name: name, serial: serial)
    }

    @Test func theLocationSettlesIt() {
        let display = candidate(2, location: "IOService:/dispext0/shim")
        #expect(DDCDiscovery.score(display, "IOService:/dispext0/shim", "", "", "") == 10)
        #expect(DDCDiscovery.score(display, "IOService:/dispext1/shim", "", "", "") == 0)
    }

    /// The EDID UUID starts with the vendor, then the model with its bytes swapped.
    @Test func vendorModelNameAndSerialAddUp() {
        let display = candidate(2, serial: "ABC1")
        #expect(DDCDiscovery.score(display, "", "10ACF1A0-0000-0000-0C21-0104B53C2278", "DELL U2723QE", "ABC1") == 4)
        #expect(DDCDiscovery.score(display, "", "1E6D775B-0000-0000-0C21-0104B53C2278", "Other", "") == 0)
    }

    @Test func aMacWithOnlyItsBuiltInDisplayHasNoPorts() {
        // The built-in panel's service says "Embedded" and is skipped.
        let ports = DDCDiscovery.externalPorts()
        let externals = DisplayManager.onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
        if externals.isEmpty { #expect(ports.isEmpty) }
    }
}

@MainActor
@Suite struct DisplayHotKeyTests {
    private let rare = HotKey(keyCode: UInt32(kVK_F17), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))

    /// Nothing is registered until the user records keys, the panel's
    /// shortcut included, and a removed one is gone for good.
    @Test func shortcutsHaveNoKeysUntilRecorded() {
        let defaults = memoryDefaults()
        let keys = [HotKeyManager.panelKey] + DisplayAction.allCases.map(\.rawValue)
        let manager = HotKeyManager(defaults: defaults) { _ in }
        manager.start(keys: keys)
        #expect(keys.allSatisfy { manager.hotKey($0) == nil })
        manager.update("brightnessUp", to: rare)
        #expect(manager.hotKey("brightnessUp") == rare)
        #expect(manager.owner(of: rare) == "brightnessUp")
        // Kept across a restart.
        let again = HotKeyManager(defaults: defaults) { _ in }
        again.start(keys: keys)
        #expect(again.hotKey("brightnessUp") == rare)
        manager.update("brightnessUp", to: nil)
        again.update("brightnessUp", to: nil)
        #expect(manager.owner(of: rare) == nil)
        let third = HotKeyManager(defaults: defaults) { _ in }
        third.start(keys: keys)
        #expect(third.hotKey("brightnessUp") == nil)
    }

    @Test func thePanicShortcutCannotBeTakenByAnother() {
        let manager = HotKeyManager(defaults: memoryDefaults()) { _ in }
        #expect(manager.owner(of: DisplaySafety.panicHotKey) == DisplaySafety.panicKey)
        #expect(DisplaySafety.panicHotKey.displayString == "⌃⌥⌘⎋")
    }

    @Test func everyActionHasATitleAndASection() {
        for action in DisplayAction.allCases {
            #expect(!action.title.isEmpty && action.title != action.rawValue, "\(action)")
        }
        #expect(DisplayAction.favorite3.favoriteIndex == 2)
        #expect(DisplayAction.brightnessUp.favoriteIndex == nil)
        #expect(DisplayShortcuts.title(forKey: "panic") != "panic")
        #expect(DisplayShortcuts.title(forKey: HotKeyManager.panelKey) != HotKeyManager.panelKey)
    }
}

/// The parts that read the displays of the Mac the tests run on, without
/// changing anything.
@MainActor
@Suite struct DisplayReadingTests {
    @Test func everyOnlineDisplayIsListedWithAKeyOfItsOwn() {
        let manager = DisplayManager.shared
        manager.refresh()
        #expect(manager.displays.map(\.id) == DisplayManager.onlineDisplays())
        #expect(Set(manager.displays.map(\.key)).count == manager.displays.count)
        #expect(manager.displays.filter(\.isMain).count == 1)
        for display in manager.displays {
            #expect(!display.systemName.isEmpty)
            #expect((CGDisplayIsBuiltin(display.id) != 0) == (display.kind == .builtIn))
        }
    }

    @Test func modesAreListedAndTheCurrentOneIsAmongThem() throws {
        let manager = DisplayManager.shared
        manager.refresh()
        let display = try #require(manager.displays.first { $0.isMain })
        let modes = ModeController.shared.modes(of: display.id)
        #expect(!modes.isEmpty)
        let current = try #require(ModeController.shared.current(of: display.id))
        #expect(modes.contains(current))
        #expect(current.width == Int(CGDisplayBounds(display.id).width))
        #expect(Set(modes.map(\.number)).count == modes.count)
    }

    @Test func aBuiltInDisplayUsesItsBacklight() throws {
        let manager = DisplayManager.shared
        manager.refresh()
        guard let builtIn = manager.displays.first(where: { $0.kind == .builtIn }) else { return }
        #expect(builtIn.hasAppleBrightness)
        #expect(BrightnessController.shared.method(for: builtIn) == .apple)
        let value = BrightnessController.shared.value(for: builtIn)
        #expect((0...1).contains(value))
        #expect(BrightnessController.shared.availableMethods(for: builtIn).contains(.gamma))
    }

    /// The panel's quick switches: only those chosen, only those the display
    /// has, always in the same order.
    @Test func panelQuickSwitchesFollowTheChoiceAndTheDisplay() {
        let manager = DisplayManager.shared
        manager.refresh()
        for display in manager.displays {
            #expect(DisplayPanelBlock.quickSwitches(for: display, controls: []).isEmpty)
            let shown = DisplayPanelBlock.quickSwitches(for: display, controls: Set(DisplayPanelControl.allCases))
            #expect(shown == [.hiDPI, .notch, .xdr].filter(shown.contains))
            #expect(shown.contains(.xdr) == XDRController.shared.isAvailable(for: display))
            #expect(DisplayPanelBlock.quickSwitches(for: display, controls: [.xdr, .brightness]) == shown.filter { $0 == .xdr })
        }
    }
}

/// Tests that change real displays: they make a virtual one, dim it, switch
/// its mode, and move the built-in display's brightness and back. Run only
/// when asked, with `TEST_RUNNER_SCREENHELM_CHANGE_DISPLAYS=1`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCREENHELM_CHANGE_DISPLAYS"] == "1"))
struct DisplayChangingTests {
    /// A 1920 × 1080 HiDPI display that lasts as long as the returned object.
    private func makeVirtualDisplay(serial: UInt32 = 0x7E57) async throws -> (object: NSObject, display: DisplayInfo) {
        let made = try #require(DisplayPrivateAPIs.makeVirtualDisplay(
            name: "ScreenHelm Test", serial: serial, maxPixels: (3840, 2160), sizeInMillimeters: CGSize(width: 600, height: 340),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60), .init(width: 1280, height: 720, refreshRate: 60)], hiDPI: true
        ))
        try await Task.sleep(for: .milliseconds(1200))
        DisplayManager.shared.refresh()
        let display = try #require(DisplayManager.shared.display(made.id))
        return (made.object, display)
    }

    @Test func aVirtualDisplayIsRecognisedAndDimmedWithAnOverlay() async throws {
        let (object, display) = try await makeVirtualDisplay()
        defer { _ = object }
        #expect(display.kind == .virtual)
        #expect(!display.hasAppleBrightness)
        #expect(display.identity.vendor == DisplayPrivateAPIs.virtualVendorID)
        let brightness = BrightnessController.shared
        #expect(brightness.method(for: display) == .overlay)

        brightness.set(0.5, for: display)
        #expect(abs(brightness.value(for: display) - 0.5) < 0.001)
        // Half the slider is 57.5% light with the 15% floor.
        #expect(abs(DimOverlay.shared.dimming(for: display.id) - 0.575) < 0.001)
        #expect(DimOverlay.shared.isActive)
        #expect(DisplaySafety.shared.panicHotKeyIsRegistered)

        brightness.set(0, for: display)
        #expect(abs(DimOverlay.shared.dimming(for: display.id) - 0.15) < 0.001)

        DisplaySafety.shared.panic()
        #expect(!DimOverlay.shared.isActive)
        #expect(brightness.value(for: display) == 1)
        withExtendedLifetime(object) {}
    }

    /// The modes of a virtual display made by this very process, which
    /// CoreGraphics doesn't return, and switching between them with the way back.
    @Test func aModeIsSetUndoneAndKept() async throws {
        let (object, display) = try await makeVirtualDisplay(serial: 0x7E58)
        let controller = ModeController.shared
        let modes = controller.modes(of: display.id)
        #expect(modes.count >= 2)
        let start = try #require(controller.current(of: display.id))
        let other = try #require(modes.first { $0.width != start.width && $0.isHiDPI == start.isHiDPI })

        #expect(controller.set(other, on: display))
        try await Task.sleep(for: .milliseconds(700))
        #expect(controller.current(of: display.id)?.number == other.number)
        #expect(DisplaySafety.shared.hasPendingChange)
        #expect(Int(CGDisplayBounds(display.id).width) == other.width)

        DisplaySafety.shared.revertPending()
        try await Task.sleep(for: .milliseconds(700))
        #expect(controller.current(of: display.id)?.number == start.number)
        #expect(!DisplaySafety.shared.hasPendingChange)

        // Left to run out, the countdown undoes it as well.
        #expect(controller.set(other, on: display))
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<DisplaySafety.confirmationSeconds { DisplaySafety.shared.tick() }
        try await Task.sleep(for: .milliseconds(700))
        #expect(controller.current(of: display.id)?.number == start.number)
        withExtendedLifetime(object) {}
    }

    @Test func mirrorAndMainDisplayGoThereAndBack() async throws {
        let (object, display) = try await makeVirtualDisplay(serial: 0x7E59)
        let manager = DisplayManager.shared
        let main = try #require(manager.displays.first { $0.isMain })

        ConfigurationController.setMirror(of: display, to: main)
        try await Task.sleep(for: .milliseconds(1200))
        manager.refresh()
        #expect(manager.display(display.id)?.mirrorOf == main.id)
        DisplaySafety.shared.revertPending()
        try await Task.sleep(for: .milliseconds(1200))
        manager.refresh()
        #expect(manager.display(display.id)?.mirrorOf == nil)

        let fresh = try #require(manager.display(display.id))
        ConfigurationController.setMain(fresh)
        try await Task.sleep(for: .milliseconds(1200))
        manager.refresh()
        #expect(manager.display(display.id)?.isMain == true)
        DisplaySafety.shared.revertPending()
        try await Task.sleep(for: .milliseconds(1200))
        manager.refresh()
        #expect(manager.display(main.id)?.isMain == true)
        withExtendedLifetime(object) {}
    }

    /// The built-in display's backlight through the slider, put back after.
    @Test func theBuiltInBacklightFollowsTheSlider() async throws {
        let manager = DisplayManager.shared
        manager.refresh()
        guard let builtIn = manager.displays.first(where: { $0.kind == .builtIn }) else { return }
        let brightness = BrightnessController.shared
        let start = try #require(DisplayPrivateAPIs.brightness(of: builtIn.id))
        defer { DisplayPrivateAPIs.setBrightness(start, of: builtIn.id) }

        let target = start > 0.5 ? start - 0.25 : start + 0.25
        brightness.set(target, for: builtIn)
        try await Task.sleep(for: .milliseconds(600))
        let read = try #require(DisplayPrivateAPIs.brightness(of: builtIn.id))
        #expect(abs(read - target) < 0.01)
        if let nits = brightness.nits(for: builtIn) { #expect(nits > 0) }
        // macOS reports the change back, as it would for the keyboard's keys.
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(brightness.value(for: builtIn) - target) < 0.01)
    }

    /// The colour table written, read back, and given back.
    @Test func softwareDimmingWritesTheColorTable() async throws {
        let manager = DisplayManager.shared
        manager.refresh()
        guard let builtIn = manager.displays.first(where: { $0.kind == .builtIn }) else { return }
        func white() -> Float {
            var red = [CGGammaValue](repeating: 0, count: 1024), green = red, blue = red
            var count: UInt32 = 0
            CGGetDisplayTransferByTable(builtIn.id, 1024, &red, &green, &blue, &count)
            return red[Int(count) - 1]
        }
        let gamma = GammaController.shared
        let before = white()
        gamma.setDimming(0.6, for: builtIn.id)
        #expect(abs(white() - before * 0.6) < 0.01)
        #expect(gamma.isActive)
        var picture = PictureAdjustment.neutral
        picture.redGain = 0.5
        gamma.setPicture(picture, for: builtIn.id)
        #expect(abs(white() - before * 0.3) < 0.01)
        gamma.setPicture(.neutral, for: builtIn.id)
        gamma.setDimming(1, for: builtIn.id)
        #expect(abs(white() - before) < 0.01)
        #expect(!gamma.isActive)
    }

    @Test func nightShiftAndTrueToneSwitchAndComeBack() async throws {
        if let nightShift = SystemToggles.nightShift {
            SystemToggles.setNightShift(!nightShift)
            try await Task.sleep(for: .milliseconds(400))
            #expect(SystemToggles.nightShift == !nightShift)
            SystemToggles.setNightShift(nightShift)
            try await Task.sleep(for: .milliseconds(400))
            #expect(SystemToggles.nightShift == nightShift)
        }
        if let trueTone = SystemToggles.trueTone {
            SystemToggles.setTrueTone(!trueTone)
            try await Task.sleep(for: .milliseconds(400))
            #expect(SystemToggles.trueTone == !trueTone)
            SystemToggles.setTrueTone(trueTone)
            try await Task.sleep(for: .milliseconds(400))
            #expect(SystemToggles.trueTone == trueTone)
        }
    }

    /// macOS puts the brightness at full when a reference preset changes;
    /// ScreenHelm sets it back to what it was.
    @Test func changingThePresetKeepsTheBrightness() async throws {
        let manager = DisplayManager.shared
        manager.refresh()
        guard let builtIn = manager.displays.first(where: { $0.kind == .builtIn }) else { return }
        let presets = DisplayPrivateAPIs.presets(of: builtIn.id)
        guard let active = presets.active, let other = presets.all.first(where: { $0.name.contains("sRGB") }), other.id != active else { return }
        let start = try #require(DisplayPrivateAPIs.brightness(of: builtIn.id))
        defer { DisplayPrivateAPIs.setBrightness(start, of: builtIn.id) }
        DisplayPrivateAPIs.setBrightness(0.4, of: builtIn.id)
        try await Task.sleep(for: .milliseconds(400))

        #expect(other.isFixedBrightness)
        #expect(presets.all.first { $0.id == active }?.isFixedBrightness == false)
        ConfigurationController.setPreset(other.id, on: builtIn)
        try await Task.sleep(for: .milliseconds(2500))
        #expect(DisplayPrivateAPIs.presets(of: builtIn.id).active == other.id)
        #expect(BrightnessController.shared.locked.contains(builtIn.id))
        // Asking for another brightness meanwhile changes nothing, now or after.
        BrightnessController.shared.set(0.9, for: builtIn)
        DisplayPrivateAPIs.setBrightness(0.9, of: builtIn.id)
        ConfigurationController.setPreset(active, on: builtIn)
        try await Task.sleep(for: .milliseconds(2500))
        #expect(DisplayPrivateAPIs.presets(of: builtIn.id).active == active)
        let after = try #require(DisplayPrivateAPIs.brightness(of: builtIn.id))
        #expect(abs(after - 0.4) < 0.02, "brightness is \(after)")
        #expect(!BrightnessController.shared.locked.contains(builtIn.id))
    }

    /// A brightness key meant for a display ScreenHelm dims is taken; one for
    /// the built-in display is left to macOS.
    @Test func brightnessKeysReachTheDisplayUnderThePointerOnly() async throws {
        let (object, display) = try await makeVirtualDisplay(serial: 0x7E5A)
        let tap = MediaKeyTap.shared
        let builtIn = DisplayManager.shared.displays.first { $0.kind == .builtIn }
        let pointerDisplay = try #require(DisplayManager.shared.displayUnderPointer())
        let targets = tap.brightnessTargets(control: false)
        if pointerDisplay.id == builtIn?.id {
            #expect(targets.isEmpty)
            #expect(!tap.pressed(.brightnessUp, isDown: true, flags: []))
            // ⌃ sends the key to another display: a virtual one here. One
            // made by an earlier test may still be around, since a virtual
            // display whose mode was changed lasts until the process ends.
            let target = try #require(tap.brightnessTargets(control: true).first)
            #expect(target.kind == .virtual)
            BrightnessController.shared.set(0.5, for: target)
            #expect(tap.pressed(.brightnessUp, isDown: true, flags: .control))
            #expect(abs(BrightnessController.shared.value(for: target) - 0.5625) < 0.001)
            #expect(tap.pressed(.brightnessDown, isDown: true, flags: [.control, .shift, .option]))
            #expect(abs(BrightnessController.shared.value(for: target) - 0.546875) < 0.001)
            _ = display
        } else {
            #expect(targets.map(\.id) == [pointerDisplay.id])
        }
        // Volume keys are left alone: no display's speakers are playing over DDC.
        #expect(!tap.pressed(.soundUp, isDown: true, flags: []))
        DisplaySafety.shared.panic()
        withExtendedLifetime(object) {}
    }
}

/// Dragging a display's rectangle among the others.
@Suite struct ArrangementGeometryTests {
    private let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    @Test func edgesAndCentersPullWithinTheTolerance() {
        let dragged = CGRect(x: 1810, y: 8, width: 1920, height: 1080)
        let snapped = ArrangementGeometry.snap(dragged, to: [main], tolerance: 14)
        #expect(snapped.origin == CGPoint(x: 1800, y: 0))
        #expect(snapped.guides == [.init(vertical: true, position: 1800), .init(vertical: false, position: 0)])
        let far = ArrangementGeometry.snap(CGRect(x: 2000, y: 300, width: 1920, height: 1080), to: [main], tolerance: 14)
        #expect(far.origin == CGPoint(x: 2000, y: 300) && far.guides.isEmpty)
        // Centers line up too.
        let centered = ArrangementGeometry.snap(CGRect(x: 2400, y: 40, width: 1920, height: 1080), to: [main], tolerance: 14)
        #expect(centered.origin.y == 44.5)
    }

    /// A display dropped in mid-air lands against the nearest edge, never on top of another.
    @Test func aDropLandsAgainstAnEdge() {
        let floating = ArrangementGeometry.attach(CGRect(x: 2300, y: 200, width: 1920, height: 1080), to: [main])
        #expect(floating == CGRect(x: 1800, y: 200, width: 1920, height: 1080))
        let overlapping = ArrangementGeometry.attach(CGRect(x: 900, y: -900, width: 1920, height: 1080), to: [main])
        #expect(!overlapping.intersects(main.insetBy(dx: 1, dy: 1)))
        #expect(overlapping.maxY == 0 || overlapping.minX == 1800 || overlapping.maxX == 0 || overlapping.minY == 1169)
        // Slid past the end of an edge, it still touches by a point.
        let below = ArrangementGeometry.attach(CGRect(x: 1900, y: 3000, width: 1920, height: 1080), to: [main])
        #expect(below.minX == 1800 || below.minY == 1169)
        #expect(below.minY <= 1169 && below.minX <= 1800)
    }

    @Test func aDisplayNeverLandsOnAThirdOne() {
        let right = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
        let dropped = ArrangementGeometry.attach(CGRect(x: 1700, y: 100, width: 1280, height: 720), to: [main, right])
        #expect(!dropped.intersects(main.insetBy(dx: 1, dy: 1)) && !dropped.intersects(right.insetBy(dx: 1, dy: 1)))
        #expect(ArrangementGeometry.union([main, right]) == CGRect(x: 0, y: 0, width: 3720, height: 1169))
    }
}

/// Stage two of the display-changing tests: switching a display off and
/// on, keeping an arrangement, XDR boost, syncing and picture settings.
/// Run only when asked, with `TEST_RUNNER_SCREENHELM_CHANGE_DISPLAYS=1`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCREENHELM_CHANGE_DISPLAYS"] == "1"))
struct DisplayArrangementChangingTests {
    private func makeVirtualDisplay(serial: UInt32) async throws -> (object: NSObject, display: DisplayInfo) {
        let made = try #require(DisplayPrivateAPIs.makeVirtualDisplay(
            name: "ScreenHelm Test", serial: serial, maxPixels: (3840, 2160), sizeInMillimeters: CGSize(width: 600, height: 340),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60), .init(width: 1280, height: 720, refreshRate: 60)], hiDPI: true
        ))
        try await Task.sleep(for: .milliseconds(1200))
        DisplayManager.shared.refresh()
        return (made.object, try #require(DisplayManager.shared.display(made.id)))
    }

    @Test func aDisplayIsSwitchedOffAndComesBackByItsNumber() async throws {
        let (object, display) = try await makeVirtualDisplay(serial: 0x7E61)
        let connection = ConnectionController.shared
        #expect(connection.canDisconnect)
        #expect(connection.refusal(for: display) == nil)
        #expect(connection.disconnect(display, confirm: false))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!DisplayManager.onlineDisplays().contains(display.id))
        #expect(connection.disconnected.map(\.id) == [display.id])
        #expect(DisplaySafety.shared.panicHotKeyIsRegistered)
        let journal = try DisplayStore(dbQueue: try #require(AppDatabase.shared).dbQueue).journal(.disconnected)
        #expect(journal.contains { $0.detail == String(display.id) })

        #expect(connection.reconnect(display.id))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(DisplayManager.onlineDisplays().contains(display.id))
        #expect(connection.disconnected.isEmpty)
        let after = try DisplayStore(dbQueue: try #require(AppDatabase.shared).dbQueue).journal(.disconnected)
        #expect(!after.contains { $0.detail == String(display.id) })
        withExtendedLifetime(object) {}
    }

    /// The second copy of the executable that waits for a process to end
    /// and then switches displays back on: here it waits for a `sleep`.
    @Test func theWatcherSwitchesDisplaysBackOnWhenTheAppIsGone() async throws {
        let (object, display) = try await makeVirtualDisplay(serial: 0x7E64)
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        #expect(DisplayPrivateAPIs.configure(config, display: display.id, enabled: false))
        CGCompleteDisplayConfiguration(config, .forSession)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(!DisplayManager.onlineDisplays().contains(display.id))

        let standIn = Process()
        standIn.executableURL = URL(fileURLWithPath: "/bin/sleep")
        standIn.arguments = ["2"]
        try standIn.run()
        let watcher = Process()
        watcher.executableURL = Bundle.main.executableURL
        watcher.arguments = [ConnectionController.watcherArgument, String(standIn.processIdentifier), String(display.id)]
        try watcher.run()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(watcher.isRunning)
        #expect(!DisplayManager.onlineDisplays().contains(display.id))
        try await Task.sleep(for: .milliseconds(2500))
        #expect(!watcher.isRunning)
        #expect(DisplayManager.onlineDisplays().contains(display.id))
        withExtendedLifetime(object) {}
    }

    @Test func theBuiltInAndTheLastDisplayStayOn() async throws {
        let manager = DisplayManager.shared
        manager.refresh()
        guard let builtIn = manager.displays.first(where: { $0.kind == .builtIn }) else { return }
        let advanced = SettingsViewModel.shared.settings.displaysAdvanced
        defer { SettingsViewModel.shared.settings.displaysAdvanced = advanced }
        SettingsViewModel.shared.settings.displaysAdvanced = false
        #expect(ConnectionController.shared.refusal(for: builtIn) != nil)
        #expect(!ConnectionController.shared.disconnect(builtIn))
        // With the risky settings shown, it is still the last real display.
        SettingsViewModel.shared.settings.displaysAdvanced = true
        if manager.displays.filter({ $0.kind != .virtual && $0.id != builtIn.id }).isEmpty {
            #expect(ConnectionController.shared.refusal(for: builtIn) != nil)
        }
    }

    /// A display moved to the other side is put back where it was kept.
    @Test func theKeptArrangementIsPutBack() async throws {
        let (object, display) = try await makeVirtualDisplay(serial: 0x7E62)
        let manager = DisplayManager.shared
        let guardian = LayoutGuard.shared
        let main = try #require(manager.displays.first { $0.isMain })
        func move(to origin: CGPoint) async throws {
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayOrigin(config, display.id, Int32(origin.x), Int32(origin.y))
            CGCompleteDisplayConfiguration(config, .forSession)
            try await Task.sleep(for: .milliseconds(1200))
            manager.refresh()
        }
        try await move(to: CGPoint(x: main.bounds.maxX, y: 0))
        let kept = try #require(manager.display(display.id)).bounds.origin
        guardian.saveCurrent()
        let saved = try #require(guardian.savedForCurrentDisplays)
        #expect(saved.items.first { $0.key == display.key }?.anchor?.edge == .right)

        try await move(to: CGPoint(x: -display.bounds.width, y: 0))
        #expect(try #require(manager.display(display.id)).bounds.origin != kept)
        #expect(!saved.operations(from: guardian.current()).isEmpty)
        guardian.applySaved()
        try await Task.sleep(for: .milliseconds(1200))
        manager.refresh()
        #expect(try #require(manager.display(display.id)).bounds.origin == kept)
        #expect(saved.operations(from: guardian.current()).isEmpty)
        guardian.forgetCurrent()
        #expect(guardian.savedForCurrentDisplays == nil)
        withExtendedLifetime(object) {}
    }

    @Test func aDisplayFollowsTheBuiltInOnesBrightness() async throws {
        let (object, display) = try await makeVirtualDisplay(serial: 0x7E63)
        let manager = DisplayManager.shared
        guard let builtIn = manager.displays.first(where: { $0.kind == .builtIn }) else { return }
        let brightness = BrightnessController.shared
        let start = try #require(DisplayPrivateAPIs.brightness(of: builtIn.id))
        let source = SettingsViewModel.shared.settings.displaysSyncSource
        defer {
            SettingsViewModel.shared.settings.displaysSyncSource = source
            DisplayPrivateAPIs.setBrightness(start, of: builtIn.id)
            DisplaySafety.shared.panic()
        }
        SettingsViewModel.shared.settings.displaysSyncSource = .builtIn
        SettingsViewModel.shared.settings.displaysSyncByNits = false
        try await Task.sleep(for: .milliseconds(200))
        brightness.set(0.6, for: builtIn)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(brightness.value(for: display) - 0.6) < 0.01)
        manager.updateProfile(of: display) { $0.syncOffset = 0.2 }
        brightness.set(0.5, for: builtIn)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(brightness.value(for: display) - 0.7) < 0.01)
        manager.updateProfile(of: display) { $0.syncExcluded = true }
        brightness.set(0.3, for: builtIn)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(brightness.value(for: display) - 0.7) < 0.01)
        withExtendedLifetime(object) {}
    }

    @Test func pictureSettingsChangeTheColorTableAndAreRemembered() async throws {
        let manager = DisplayManager.shared
        manager.refresh()
        guard let builtIn = manager.displays.first(where: { $0.kind == .builtIn }) else { return }
        func ends() -> (first: Float, last: Float) {
            var red = [CGGammaValue](repeating: 0, count: 1024), green = red, blue = red
            var count: UInt32 = 0
            CGGetDisplayTransferByTable(builtIn.id, 1024, &red, &green, &blue, &count)
            return (red[0], red[Int(count) - 1])
        }
        let before = ends()
        var picture = PictureAdjustment.neutral
        picture.invert = true
        BrightnessController.shared.setPicture(picture, for: builtIn)
        #expect(abs(ends().first - before.last) < 0.01 && abs(ends().last - before.first) < 0.01)
        #expect(manager.profile(for: builtIn).picture.invert)
        BrightnessController.shared.setPicture(.neutral, for: builtIn)
        #expect(abs(ends().last - before.last) < 0.01)
        #expect(manager.profile(for: builtIn).picture.isNeutral)
    }

    /// XDR boost on the built-in display: the slider goes past 100%, the
    /// extended range switches on and white is multiplied. Brightness is
    /// at full for a few seconds meanwhile.
    @Test func theSliderGoesPastOneHundredPercentOnAnXDRDisplay() async throws {
        let manager = DisplayManager.shared
        manager.refresh()
        guard let builtIn = manager.displays.first(where: { $0.kind == .builtIn }), XDRController.shared.isAvailable(for: builtIn) else { return }
        let brightness = BrightnessController.shared, xdr = XDRController.shared
        let start = try #require(DisplayPrivateAPIs.brightness(of: builtIn.id))
        let wasOn = manager.profile(for: builtIn).xdrBoost
        defer {
            xdr.stopAll()
            xdr.setEnabled(wasOn, for: builtIn)
            DisplayPrivateAPIs.setBrightness(start, of: builtIn.id)
        }
        xdr.setEnabled(false, for: builtIn)
        #expect(brightness.maximum(for: builtIn) == 1)
        xdr.setEnabled(true, for: builtIn)
        #expect(brightness.maximum(for: builtIn) == 2)

        brightness.set(2, for: builtIn)
        #expect(brightness.value(for: builtIn) == 2)
        #expect(xdr.isActive)
        try await Task.sleep(for: .milliseconds(4000))
        let backlight = try #require(DisplayPrivateAPIs.brightness(of: builtIn.id))
        #expect(backlight > 0.99)
        let factor = xdr.factors[builtIn.id] ?? 1
        let headroom = NSScreen.screens.first?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        // The factor is above 1 once macOS has switched the range on, and never above what it gives.
        #expect(headroom > 1.05, "extended range is \(headroom)")
        #expect(factor > 1.05 && factor <= Double(headroom) + 0.001, "factor \(factor), headroom \(headroom)")
        #expect(abs(GammaController.shared.adjustment(for: builtIn.id).boost - factor) < 0.001)
        // White is brighter than the backlight alone gives, and within the panel's peak.
        let white = XDRBoost.panelPeakNits / Double(headroom)
        let nits = try #require(brightness.nits(for: builtIn))
        print("XDR boost: factor \(factor), headroom \(headroom), white \(white) nits, boosted \(nits) nits")
        // No brighter than the limit set for the display.
        #expect(nits > white && nits <= Double(manager.profile(for: builtIn).xdrMaxNits) + 1)

        brightness.set(0.8, for: builtIn)
        #expect(!xdr.isActive)
        #expect(GammaController.shared.adjustment(for: builtIn.id).boost == 1)
    }
}

/// The override file installer, pointed at a folder of the test's own and
/// run without the administrator step.
@MainActor
@Suite(.serialized)
struct OverrideInstallerTests {
    private let display = DisplayInfo(id: CGMainDisplayID(), key: "test-override", identity: DisplayIdentity(vendor: 0x0EDC, product: 0x7E57, serial: 1),
                                      kind: .external, systemName: "Test Monitor", isMain: false,
                                      bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), rotation: 0, mirrorOf: nil, hasAppleBrightness: false)
    private let sizes = [ScaledResolutions.Size(width: 1600, height: 900), ScaledResolutions.Size(width: 2048, height: 1152)]

    /// Runs `body` with the installer writing under a temporary folder.
    private func withTemporaryRoot(_ body: (URL) throws -> Void) rethrows {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenhelm-override-test-\(UUID().uuidString)")
        let root = OverrideInstaller.root, systemRoot = OverrideInstaller.systemRoot, runner = OverrideInstaller.runPrivileged
        OverrideInstaller.root = folder.appendingPathComponent("Library").path
        OverrideInstaller.systemRoot = folder.appendingPathComponent("System").path
        OverrideInstaller.runPrivileged = { command in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        defer {
            OverrideInstaller.root = root
            OverrideInstaller.systemRoot = systemRoot
            OverrideInstaller.runPrivileged = runner
            try? FileManager.default.removeItem(at: folder)
            if let store = AppDatabase.shared.map({ DisplayStore(dbQueue: $0.dbQueue) }) {
                for entry in (try? store.journal(.overrideFile)) ?? [] where entry.display == "test-override" {
                    if let id = entry.id { try? store.clearJournal(id: id) }
                }
            }
        }
        try body(folder)
    }

    @Test func aFileIsInstalledAndTakenOutAgain() throws {
        try withTemporaryRoot { _ in
            #expect(OverrideInstaller.status(for: display) == .init(installed: false, byScreenHelm: false, sizes: []))
            #expect(OverrideInstaller.install(sizes, for: display))
            let path = OverrideInstaller.path(for: display)
            #expect(path.hasSuffix("/DisplayVendorID-edc/DisplayProductID-7e57"))
            let status = OverrideInstaller.status(for: display)
            #expect(status.installed && status.byScreenHelm && status.sizes == sizes)
            let written = try #require(FileManager.default.contents(atPath: path))
            let dictionary = try #require(try PropertyListSerialization.propertyList(from: written, format: nil) as? [String: Any])
            #expect(dictionary["DisplayProductName"] as? String == "Test Monitor")

            #expect(OverrideInstaller.remove(for: display))
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(!OverrideInstaller.status(for: display).byScreenHelm)
            // Nothing of ScreenHelm's left to remove.
            #expect(!OverrideInstaller.remove(for: display))
        }
    }

    /// Another tool's file, or the user's own, is added to and put back as it was.
    @Test func aFileAlreadyThereIsAddedToAndPutBack() throws {
        try withTemporaryRoot { _ in
            let path = OverrideInstaller.path(for: display)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let theirs = try ScaledResolutions.propertyList(base: nil, vendor: 0x0EDC, product: 0x7E57, name: "Theirs",
                                                            adding: [ScaledResolutions.Size(width: 1280, height: 720)])
            try theirs.write(to: URL(fileURLWithPath: path))
            let before = OverrideInstaller.status(for: display)
            #expect(before.installed && !before.byScreenHelm)

            #expect(OverrideInstaller.install(sizes, for: display))
            #expect(OverrideInstaller.status(for: display).sizes.map(\.width) == [1280, 1600, 2048])
            // A second install keeps the first backup, not ScreenHelm's own file.
            #expect(OverrideInstaller.install([ScaledResolutions.Size(width: 2304, height: 1296)], for: display))
            #expect(OverrideInstaller.remove(for: display))
            #expect(FileManager.default.contents(atPath: path) == theirs)
        }
    }

    /// Apple's own file for the model is what a new one starts from.
    @Test func applesFileIsTheStartingPoint() throws {
        try withTemporaryRoot { _ in
            let systemPath = ScaledResolutions.path(vendor: 0x0EDC, product: 0x7E57, root: OverrideInstaller.systemRoot)
            try FileManager.default.createDirectory(atPath: (systemPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let apple: [String: Any] = ["DisplayVendorID": 0x0EDC, "DisplayProductID": 0x7E57, "IOGFlags": 4,
                                        "scale-resolutions": [ScaledResolutions.entry(for: ScaledResolutions.Size(width: 1920, height: 1080))]]
            try PropertyListSerialization.data(fromPropertyList: apple, format: .xml, options: 0).write(to: URL(fileURLWithPath: systemPath))
            #expect(OverrideInstaller.install(sizes, for: display))
            let installed = try #require(FileManager.default.contents(atPath: OverrideInstaller.path(for: display)))
            let dictionary = try #require(try PropertyListSerialization.propertyList(from: installed, format: nil) as? [String: Any])
            #expect(dictionary["IOGFlags"] as? Int == 4)
            #expect(ScaledResolutions.sizes(in: installed).map(\.width) == [1920, 1600, 2048])
        }
    }

    @Test func aRefusedPasswordChangesNothing() {
        withTemporaryRoot { _ in
            OverrideInstaller.runPrivileged = { _ in false }
            #expect(!OverrideInstaller.install(sizes, for: display))
            #expect(!OverrideInstaller.status(for: display).installed)
            #expect(!OverrideInstaller.status(for: display).byScreenHelm)
        }
    }

    /// This Mac's own display: sizes in its panel's shape, none past the panel.
    @Test func sizesForThisMacsDisplayStayWithinThePanel() throws {
        DisplayManager.shared.refresh()
        let main = try #require(DisplayManager.shared.displays.first { $0.isMain })
        guard let native = ModeController.shared.modes(of: main.id).first(where: \.isNative) else { return }
        let sizes = OverrideInstaller.sizes(for: main, extra: [ScaledResolutions.Size(width: 1600, height: 1000)])
        #expect(sizes.count > 10)
        #expect(sizes.contains(ScaledResolutions.Size(width: 1600, height: 1000)))
        let widest = sizes.map(\.width).max() ?? 0
        #expect(widest <= native.pixelWidth)
        #expect(!OverrideInstaller.chip.isEmpty)
    }
}

/// Virtual screens through their controller. Run only when asked, with
/// `TEST_RUNNER_SCREENHELM_CHANGE_DISPLAYS=1`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCREENHELM_CHANGE_DISPLAYS"] == "1"))
struct VirtualScreenChangingTests {
    @Test func aVirtualScreenIsMadeChangedAndDeleted() async throws {
        let controller = VirtualScreenController.shared
        #expect(controller.isAvailable)
        let before = Set(DisplayManager.onlineDisplays())
        let screen = controller.add(name: "Test Screen", pixelWidth: 2560, pixelHeight: 1600)
        defer { controller.delete(screen.id) }
        try await Task.sleep(for: .milliseconds(1200))
        let displayID = try #require(controller.connected[screen.id])
        #expect(DisplayManager.onlineDisplays().contains(displayID) && !before.contains(displayID))
        DisplayManager.shared.refresh()
        let display = try #require(DisplayManager.shared.display(displayID))
        #expect(display.kind == .virtual && display.systemName == "Test Screen")
        #expect(controller.screen(for: displayID)?.id == screen.id)
        let modes = ModeController.shared.modes(of: displayID)
        #expect(modes.contains { $0.width == 1280 && $0.height == 800 && $0.isHiDPI })
        #expect(DisplaySafety.shared.panicHotKeyIsRegistered)

        // It is remembered, with a serial of its own.
        let stored = try DisplayStore(dbQueue: try #require(AppDatabase.shared).dbQueue).load(VirtualScreen.self, from: .virtualScreen)
        #expect(stored[screen.id.uuidString]?.pixelWidth == 2560)
        let second = controller.add(name: "Second", pixelWidth: 1920, pixelHeight: 1080, connect: false)
        #expect(second.serial != screen.serial)
        controller.delete(second.id)

        controller.setConnected(false, screen.id)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(controller.connected[screen.id] == nil)
        #expect(!DisplayManager.onlineDisplays().contains(displayID))
        #expect(controller.screens.first { $0.id == screen.id }?.connectAtLaunch == false)

        controller.setConnected(true, screen.id)
        try await Task.sleep(for: .milliseconds(1200))
        let again = try #require(controller.connected[screen.id])
        #expect(DisplayManager.onlineDisplays().contains(again))

        // A wrong size is refused; a right one makes the display again.
        var changed = try #require(controller.screens.first { $0.id == screen.id })
        changed.pixelWidth = 100
        controller.update(changed)
        #expect(controller.screens.first { $0.id == screen.id }?.pixelWidth == 2560)
        changed.pixelWidth = 3840
        changed.pixelHeight = 2160
        controller.update(changed)
        try await Task.sleep(for: .milliseconds(1500))
        let resized = try #require(controller.connected[screen.id])
        #expect(ModeController.shared.modes(of: resized).contains { $0.width == 1920 && $0.height == 1080 })

        controller.delete(screen.id)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(controller.screens.first { $0.id == screen.id } == nil)
        #expect(!DisplayManager.onlineDisplays().contains(resized))
    }
}

/// Picture in picture on a virtual display. Run only when asked, with
/// `TEST_RUNNER_SCREENHELM_CHANGE_DISPLAYS=1`, and only with the Screen
/// Recording permission.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCREENHELM_CHANGE_DISPLAYS"] == "1" && CGPreflightScreenCaptureAccess()))
struct StreamChangingTests {
    /// Something that moves, so the capture has new frames to send.
    private func animatedWindow(on frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: frame.minX + 40, y: frame.minY + 40, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemBlue.cgColor
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = NSColor.systemBlue.cgColor
        animation.toValue = NSColor.systemOrange.cgColor
        animation.duration = 0.25
        animation.autoreverses = true
        animation.repeatCount = .infinity
        view.layer?.add(animation, forKey: "pulse")
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @Test func aDisplayIsShownInAFloatingWindowAndStopsWhenAsked() async throws {
        let controller = StreamController.shared
        DisplayManager.shared.refresh()
        let main = try #require(DisplayManager.shared.displays.first { $0.isMain })
        let screen = try #require(NSScreen.screens.first)
        let mover = animatedWindow(on: screen.frame)
        defer { mover.close() }
        let config = controller.add(source: .display(main.key), name: "Test Picture")
        defer { controller.delete(config.id) }

        for fps in [60, 120] {
            var changed = try #require(controller.configs.first { $0.id == config.id })
            changed.framesPerSecond = fps
            controller.update(changed)
            controller.start(config.id)
            #expect(controller.running.contains(config.id))
            #expect(DisplaySafety.shared.panicHotKeyIsRegistered)
            try await Task.sleep(for: .milliseconds(1500))
            let framesBefore = controller.frameCount(config.id), cpuBefore = cpuSeconds()
            try await Task.sleep(for: .milliseconds(3000))
            let frames = controller.frameCount(config.id) - framesBefore
            let cpu = (cpuSeconds() - cpuBefore) / 3 * 100
            print("stream at \(fps) fps: \(Double(frames) / 3) frames a second shown, \(String(format: "%.1f", cpu))% of one core in this process")
            #expect(frames > 10, "\(frames) frames in 3 s at \(fps) fps")
            #expect(controller.failure[config.id] == nil)
            controller.stop(config.id)
            #expect(!controller.running.contains(config.id))
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Turning, mirroring, cropping and filters are applied to the running picture without starting it again.
    @Test func thePictureIsTurnedCroppedAndFilteredWhileRunning() async throws {
        let controller = StreamController.shared
        DisplayManager.shared.refresh()
        let main = try #require(DisplayManager.shared.displays.first { $0.isMain })
        let config = controller.add(source: .display(main.key), name: "Test Filters")
        defer { controller.delete(config.id) }
        controller.start(config.id)
        try await Task.sleep(for: .milliseconds(1500))
        let window = try #require(NSApp.windows.compactMap { $0 as? StreamWindow }.first { $0.title == "Test Filters" })
        let upright = window.pictureLayer.bounds.size
        #expect(upright.width > upright.height)

        var changed = try #require(controller.configs.first { $0.id == config.id })
        changed.rotation = 90
        changed.flipHorizontal = true
        changed.crop = UnitRect(x0: 0, y0: 0.5, x1: 1, y1: 1)
        changed.filters = StreamFilters(monochrome: true, blur: 4)
        controller.update(changed)
        #expect(controller.running.contains(config.id))
        #expect(window.pictureLayer.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(window.pictureLayer.filters?.count == 2)
        #expect(window.pictureLayer.affineTransform() == StreamGeometry.transform(rotation: 90, flipHorizontal: true, flipVertical: false))

        // An invalid change is refused and the picture stays as it is.
        changed.framesPerSecond = 77
        controller.update(changed)
        #expect(controller.configs.first { $0.id == config.id }?.framesPerSecond == 30)

        DisplaySafety.shared.panic()
        #expect(controller.running.isEmpty)
    }

    /// A display shown across another one: here the built-in display on a virtual screen.
    @Test func aDisplayIsShownAcrossAnotherOne() async throws {
        let made = try #require(DisplayPrivateAPIs.makeVirtualDisplay(
            name: "ScreenHelm Test", serial: 0x7E71, maxPixels: (3840, 2160), sizeInMillimeters: CGSize(width: 600, height: 340),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60)], hiDPI: true))
        try await Task.sleep(for: .milliseconds(1500))
        DisplayManager.shared.refresh()
        let target = try #require(DisplayManager.shared.display(made.id))
        let main = try #require(DisplayManager.shared.displays.first { $0.isMain })
        let controller = StreamController.shared
        var config = controller.add(source: .display(main.key), name: "Test Across")
        defer { controller.delete(config.id) }
        config.target = .display(target.key)
        config.scaling = .fill
        controller.update(config)
        controller.start(config.id)
        try await Task.sleep(for: .milliseconds(2000))
        let window = try #require(NSApp.windows.compactMap { $0 as? StreamWindow }.first { $0.title == "Test Across" })
        let targetScreen = try #require(NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == made.id
        })
        #expect(window.frame == targetScreen.frame)
        #expect(window.ignoresMouseEvents)
        #expect(controller.frameCount(config.id) > 0)
        // A display onto itself with nothing changed would only feed on itself.
        config.target = .display(main.key)
        controller.update(config)
        #expect(controller.configs.first { $0.id == config.id }?.target == .display(target.key))
        controller.stop(config.id)
        withExtendedLifetime(made.object) {}
    }
}

/// Display commands from outside the app: the router's answers, the HTTP
/// gate, the command-line socket, and the settings archive.
@MainActor
@Suite(.serialized)
struct AutomationTests {
    @Test func commandsAreAnsweredInWords() throws {
        DisplayManager.shared.refresh()
        let all = AutomationRouter.run(arguments: ["get", "display=all"])
        #expect(all.ok)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(all.text.utf8)) as? [String: Any])
        let displays = try #require(json["displays"] as? [[String: Any]])
        #expect(displays.count == DisplayManager.shared.displays.count)
        #expect(displays.first?["key"] as? String == DisplayManager.shared.displays.first?.key)
        #expect(displays.allSatisfy { $0["resolution"] is String && $0["brightness"] is Double })

        #expect(AutomationRouter.run(arguments: ["set", "name=No Such Display", "brightness=0.5"]) == .failed("no display matches"))
        #expect(AutomationRouter.run(arguments: ["frobnicate"]).text.contains("unknown command"))
        #expect(AutomationRouter.run(arguments: ["set", "display=main", "brightness=very"]).text.contains("brightness takes"))
        #expect(AutomationRouter.run(arguments: ["set", "display=main", "resolution=1x1"]).text.contains("no 1x1 mode"))
        #expect(!AutomationRouter.run(arguments: []).ok)
        #expect(AutomationRouter.targets(of: .main).count == 1)
        #expect(AutomationRouter.targets(of: .group("nothing")).isEmpty)
    }

    /// No token, a wrong token, another path or another method: turned away before any command is read.
    @Test func theHTTPGateTurnsAwayWhatHasNoToken() {
        func status(_ request: String, token: String = "s3cret") -> String {
            AutomationServer.respond(to: request, token: token).components(separatedBy: "\r\n").first ?? ""
        }
        #expect(status("GET /display/get HTTP/1.1\r\nHost: x\r\n\r\n") == "HTTP/1.1 401 Unauthorized")
        #expect(status("GET /display/get?token=wrong HTTP/1.1\r\n\r\n") == "HTTP/1.1 401 Unauthorized")
        #expect(status("GET /display/get?token=s3cret HTTP/1.1\r\n\r\n") == "HTTP/1.1 200 OK")
        #expect(status("GET /display/get HTTP/1.1\r\nAuthorization: Bearer s3cret\r\n\r\n") == "HTTP/1.1 200 OK")
        #expect(status("POST /display/get HTTP/1.1\r\nauthorization: bearer s3cret\r\n\r\n") == "HTTP/1.1 200 OK")
        #expect(status("GET /other?token=s3cret HTTP/1.1\r\n\r\n") == "HTTP/1.1 404 Not Found")
        #expect(status("DELETE /display/get?token=s3cret HTTP/1.1\r\n\r\n") == "HTTP/1.1 404 Not Found")
        #expect(status("") == "HTTP/1.1 404 Not Found")
        #expect(status("GET /display/set?token=s3cret&sharpness=3 HTTP/1.1\r\n\r\n") == "HTTP/1.1 400 Bad Request")
        // With no token made yet, nothing gets in, not even an empty one.
        #expect(status("GET /display/get?token= HTTP/1.1\r\n\r\n", token: "") == "HTTP/1.1 401 Unauthorized")
        let body = AutomationServer.respond(to: "GET /display/get?token=s3cret HTTP/1.1\r\n\r\n", token: "s3cret")
        #expect(body.contains("Content-Type: application/json") && body.contains("\"displays\""))
    }

    /// The same executable started as `ScreenHelm display get` reaches the running app.
    @Test func theCommandLineReachesTheRunningApp() async throws {
        let wasOn = SettingsViewModel.shared.settings.displaysAutomation
        defer { SettingsViewModel.shared.settings.displaysAutomation = wasOn }
        SettingsViewModel.shared.settings.displaysAutomation = true
        try await Task.sleep(for: .milliseconds(300))
        #expect(AutomationServer.shared.socketIsListening)
        let attributes = try FileManager.default.attributesOfItem(atPath: AutomationServer.socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        func run(_ words: [String]) async throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["display"] + words
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            // The app answers on its main thread, which this test must not hold.
            while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile() + err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, text)
        }
        let got = try await run(["get", "display=all"])
        #expect(got.status == 0 && got.output.contains("\"displays\""))
        let wrong = try await run(["set", "name=No Such Display", "brightness=1"])
        #expect(wrong.status == 1 && wrong.output.contains("no display matches"))

        SettingsViewModel.shared.settings.displaysAutomation = false
        try await Task.sleep(for: .milliseconds(300))
        #expect(!AutomationServer.shared.socketIsListening)
        #expect(!FileManager.default.fileExists(atPath: AutomationServer.socketPath))
        let off = try await run(["get"])
        #expect(off.status == 1 && off.output.contains("turned off"))
    }

    @Test func settingsGoOutAndComeBackIn() throws {
        let exported = try DisplaySettingsArchive.export()
        let json = try #require(try JSONSerialization.jsonObject(with: exported) as? [String: Any])
        #expect(json["format"] as? String == "screenhelm-displays")
        #expect((json["settings"] as? [String: String])?.keys.allSatisfy { $0.hasPrefix("display") || $0 == "keep_awake_displays" } == true)
        #expect(DisplaySettingsArchive.import(exported))
        #expect(!DisplaySettingsArchive.import(Data("{}".utf8)))
        #expect(!DisplaySettingsArchive.import(Data("{\"format\":\"other\",\"version\":1,\"settings\":{},\"profiles\":{},\"layouts\":{},\"virtualScreens\":{},\"streams\":{}}".utf8)))
    }

    @Test func theReportDescribesTheDisplaysWithoutTheirSerials() throws {
        DisplayManager.shared.refresh()
        let report = DisplayDiagnostics.report()
        let main = try #require(DisplayManager.shared.displays.first { $0.isMain })
        #expect(report.contains(main.systemName))
        #expect(report.contains("Calls found: modes true"))
        if !main.identity.alphanumericSerial.isEmpty { #expect(!report.contains(main.identity.alphanumericSerial)) }
        #expect(!report.localizedCaseInsensitiveContains("serialnumber"))
    }

    @Test func customControlCodesAreRead() {
        #expect(CustomDDCControl.code(from: "0x72") == 0x72)
        #expect(CustomDDCControl.code(from: " 114 ") == 114)
        #expect(CustomDDCControl.code(from: "0x1FF") == nil && CustomDDCControl.code(from: "gamma") == nil)
    }
}

/// Commands and dithering on real displays. Run only when asked, with
/// `TEST_RUNNER_SCREENHELM_CHANGE_DISPLAYS=1`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCREENHELM_CHANGE_DISPLAYS"] == "1"))
struct AutomationChangingTests {
    @Test func aCommandChangesAVirtualDisplay() async throws {
        let made = try #require(DisplayPrivateAPIs.makeVirtualDisplay(
            name: "ScreenHelm Command Test", serial: 0x7E81, maxPixels: (3840, 2160), sizeInMillimeters: CGSize(width: 600, height: 340),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60), .init(width: 1280, height: 720, refreshRate: 60)], hiDPI: true))
        try await Task.sleep(for: .milliseconds(1200))
        DisplayManager.shared.refresh()
        let display = try #require(DisplayManager.shared.display(made.id))
        defer { DisplaySafety.shared.panic() }

        #expect(AutomationRouter.run(arguments: ["set", "name=ScreenHelm Command Test", "brightness=40%"]).ok)
        #expect(abs(BrightnessController.shared.value(for: display) - 0.4) < 0.001)
        #expect(AutomationRouter.run(url: try #require(URL(string: "screenhelm://display/perform?key=\(display.key)&brightnessup"))).ok)
        #expect(abs(BrightnessController.shared.value(for: display) - 0.4375) < 0.001)

        #expect(AutomationRouter.run(arguments: ["set", "key=\(display.key)", "resolution=1280x720"]).ok)
        try await Task.sleep(for: .milliseconds(700))
        #expect(ModeController.shared.current(of: display.id)?.width == 1280)
        // Asked for from outside, the change still waits to be kept.
        #expect(DisplaySafety.shared.hasPendingChange)
        DisplaySafety.shared.revertPending()
        try await Task.sleep(for: .milliseconds(700))
        #expect(ModeController.shared.current(of: display.id)?.width == 1920)

        // A group addresses its displays together.
        let groups = SettingsViewModel.shared.settings.displayGroups
        defer { SettingsViewModel.shared.settings.displayGroups = groups }
        SettingsViewModel.shared.settings.displayGroups = [DisplayGroup(name: "Test Group", displays: [display.key])]
        #expect(AutomationRouter.run(arguments: ["set", "group=test group", "brightness=0.8"]).ok)
        #expect(abs(BrightnessController.shared.value(for: display) - 0.8) < 0.001)
        #expect(AutomationRouter.run(arguments: ["set", "key=\(display.key)", "volume=50%"]).text.contains("no DDC connection"))
        #expect(AutomationRouter.run(arguments: ["set", "key=\(display.key)", "xdr=on"]).text.contains("not an XDR display"))
        withExtendedLifetime(made.object) {}
    }

    @Test func ditheringSwitchesOffAndBackOn() throws {
        DisplayManager.shared.refresh()
        guard let builtIn = DisplayManager.shared.displays.first(where: { $0.kind == .builtIn }),
              let start = DisplayPrivateAPIs.dithering(at: builtIn.identity.location) else { return }
        defer { DisplayPrivateAPIs.setDithering(start, at: builtIn.identity.location) }
        #expect(DisplayPrivateAPIs.setDithering(!start, at: builtIn.identity.location))
        #expect(DisplayPrivateAPIs.dithering(at: builtIn.identity.location) == !start)
        #expect(DisplayPrivateAPIs.setDithering(start, at: builtIn.identity.location))
        #expect(DisplayPrivateAPIs.dithering(at: builtIn.identity.location) == start)
        #expect(DisplayPrivateAPIs.dithering(at: "") == nil)
    }
}

/// Draws every page of the window and the menu bar panel to PNG files for
/// a look at the layout, in English and light and in Vietnamese and dark:
/// run only when asked, with `TEST_RUNNER_SCREENHELM_RENDER_DIR=<folder>`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SCREENHELM_RENDER_DIR"] != nil))
struct DisplaysRenderTests {
    private func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// The window at its smallest width, 760 points, each page tall enough
    /// to show all of it.
    @Test func renderEveryPage() throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SCREENHELM_RENDER_DIR"]))
        DisplayManager.shared.refresh()
        let navigation = AppNavigationState.shared
        let before = navigation.sidebarSelection
        defer { navigation.sidebarSelection = before }
        var pages: [(String, SidebarSection, CGFloat)] = SidebarSection.pages.map { page in
            let height: CGFloat = switch page {
            case .arrangement: 1500
            case .shortcuts: 2700
            case .automation: 1100
            default: 800
            }
            return ("\(page)", page, height)
        }
        pages += DisplayManager.shared.displays.enumerated().map { ("display\($0.offset + 1)", .display($0.element.key), 3300) }
        pages.append(("settings", .settings, 1500))
        for (language, appearance) in [("en", NSAppearance.Name.aqua), ("vi", .darkAqua)] {
            let locale = Locale(identifier: language)
            for (name, page, height) in pages {
                navigation.sidebarSelection = page
                try render(ContentView().environment(\.locale, locale), size: NSSize(width: 760, height: height), appearance: appearance,
                           to: folder.appendingPathComponent("page-\(name)-\(language).png"))
            }
            try render(MenuBarPanelView().environment(\.locale, locale).background(.background),
                       size: NSSize(width: MenuBarPanelView.width, height: 360), appearance: appearance,
                       to: folder.appendingPathComponent("panel-\(language).png"))
        }
        // The DDC controls, which this Mac's own display doesn't show.
        let monitor = DisplayInfo(id: 4242, key: "test", identity: DisplayIdentity(vendor: 0x10AC, product: 0xA0F1, serial: 1),
                                  kind: .external, systemName: "Test Monitor", isMain: false,
                                  bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), rotation: 0, mirrorOf: nil, hasAppleBrightness: false)
        try render(Form { DDCSection(display: monitor, assumeFound: true) }.formStyle(.grouped).environment(\.locale, Locale(identifier: "vi")),
                   size: NSSize(width: 550, height: 1500), appearance: .aqua, to: folder.appendingPathComponent("ddc-vi.png"))
        // A monitor's block in the panel, with the menu a single built-in display doesn't get.
        try render(DisplayPanelBlock(display: monitor).padding(14).environment(\.locale, Locale(identifier: "vi")).background(.background),
                   size: NSSize(width: MenuBarPanelView.width, height: 120), appearance: .aqua, to: folder.appendingPathComponent("panel-monitor-vi.png"))
    }
}
