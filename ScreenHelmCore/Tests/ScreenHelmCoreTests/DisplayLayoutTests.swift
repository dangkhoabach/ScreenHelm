import CoreGraphics
import Foundation
import Testing
@testable import ScreenHelmCore

@Suite struct XDRBoostTests {
    @Test func theSliderIsTheBacklightUpToOne() {
        #expect(XDRBoost.factor(slider: 0.4, sdrNits: 600, limitNits: 1200, headroom: nil) == 1)
        #expect(XDRBoost.factor(slider: 1, sdrNits: 600, limitNits: 1200, headroom: nil) == 1)
    }

    /// From 600 nits of white to the user's 1200: twice at the slider's end, halfway there in the middle.
    @Test func aboveOneItGoesOnToTheLimit() {
        #expect(XDRBoost.factor(slider: 2, sdrNits: 600, limitNits: 1200, headroom: nil) == 2)
        #expect(XDRBoost.factor(slider: 1.5, sdrNits: 600, limitNits: 1200, headroom: nil) == 1.5)
        #expect(XDRBoost.factor(slider: 5, sdrNits: 600, limitNits: 1200, headroom: nil) == 2)
    }

    @Test func thePanelAndTheHeadroomCapIt() {
        // No panel goes past 1600 nits, whatever limit was typed in.
        let peak = XDRBoost.factor(slider: 2, sdrNits: 400, limitNits: 5000, headroom: nil)
        #expect(peak == 4)
        // macOS gives less room than that right now.
        #expect(XDRBoost.factor(slider: 2, sdrNits: 400, limitNits: 5000, headroom: 2.5) == 2.5)
        // A limit under what white already shows boosts nothing.
        #expect(XDRBoost.factor(slider: 2, sdrNits: 600, limitNits: 500, headroom: nil) == 1)
        #expect(XDRBoost.factor(slider: 2, sdrNits: 0, limitNits: 1200, headroom: nil) == 1)
        #expect(XDRBoost.nits(factor: 2, sdrNits: 600) == 1200)
        #expect(XDRBoost.nits(factor: 9, sdrNits: 600) == 1600)
    }

    @Test func boostStopsOnLowBatteryHeatOrLostHeadroom() {
        let low = BatteryLevel(percent: 15, onBattery: true), plugged = BatteryLevel(percent: 15, onBattery: false)
        #expect(XDRBoost.stopReason(battery: low, minimumPercent: 20, heatIsSerious: false, headroom: 2) == .lowBattery)
        #expect(XDRBoost.stopReason(battery: plugged, minimumPercent: 20, heatIsSerious: false, headroom: 2) == nil)
        #expect(XDRBoost.stopReason(battery: nil, minimumPercent: 20, heatIsSerious: true, headroom: 2) == .heat)
        #expect(XDRBoost.stopReason(battery: nil, minimumPercent: 20, heatIsSerious: false, headroom: 1.0) == .noHeadroom)
        #expect(XDRBoost.stopReason(battery: nil, minimumPercent: 20, heatIsSerious: false, headroom: nil) == nil)
    }
}

@Suite struct BrightnessSyncTests {
    @Test func theOffsetMovesTheTargetAndStaysInRange() {
        #expect(BrightnessSync.target(for: 0.5, offset: 0) == 0.5)
        #expect(BrightnessSync.target(for: 0.5, offset: 0.2) == 0.7)
        #expect(BrightnessSync.target(for: 0.9, offset: 0.2) == 1)
        #expect(BrightnessSync.target(for: 0.1, offset: -0.5) == 0)
    }

    @Test func nitsAreMatchedWithinTheMonitorsRange() {
        #expect(BrightnessSync.target(forNits: 175, minimumNits: 50, maximumNits: 300) == 0.5)
        #expect(BrightnessSync.target(forNits: 500, minimumNits: 50, maximumNits: 300) == 1)
        #expect(BrightnessSync.target(forNits: 10, minimumNits: 50, maximumNits: 300) == 0)
        #expect(BrightnessSync.target(forNits: 100, minimumNits: 300, maximumNits: 300) == 1)
    }

    @Test func theRoomsLightGivesABrightness() {
        #expect(BrightnessSync.value(forLux: 0) == 0.1)
        #expect(abs(BrightnessSync.value(forLux: 100) - 0.7) < 0.01)
        #expect(BrightnessSync.value(forLux: 1000) > 0.99)
        #expect(BrightnessSync.value(forLux: 50000) == 1)
        #expect(BrightnessSync.value(forLux: 300) > BrightnessSync.value(forLux: 30))
    }

    @Test func aJumpySensorIsAveragedAndSmallMovesIgnored() {
        #expect(BrightnessSync.smoothed([], last: nil) == nil)
        #expect(BrightnessSync.smoothed([0.4, 0.6], last: nil) == 0.5)
        #expect(BrightnessSync.smoothed([0.5, 0.52], last: 0.5) == nil)
        #expect(BrightnessSync.smoothed([0.6, 0.6], last: 0.5) == 0.6)
    }
}

private typealias Placed = DisplayLayout.Placed

/// A MacBook with a monitor to its right, a third of the way up, and a
/// portrait one to the left.
private let laptop = Placed(key: "mac", frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), isMain: true,
                            resolution: DisplayResolution(width: 1800, height: 1169, isHiDPI: true), refreshRate: 120)
private let monitor = Placed(key: "dell", frame: CGRect(x: 1800, y: -300, width: 2560, height: 1440), isMain: false,
                             resolution: DisplayResolution(width: 2560, height: 1440, isHiDPI: true), refreshRate: 60)
private let portrait = Placed(key: "lg", frame: CGRect(x: -1080, y: -400, width: 1080, height: 1920), isMain: false, rotation: 90)

@Suite struct DisplayLayoutTests {
    @Test func anArrangementBecomesRules() {
        let layout = DisplayLayout.capture([monitor, laptop, portrait])
        #expect(layout.mainKey == "mac")
        #expect(layout.signature == "dell|lg|mac")
        let dell = layout.items.first { $0.key == "dell" }!
        #expect(dell.anchor?.to == "mac" && dell.anchor?.edge == .right)
        #expect(abs(dell.anchor!.offset - (-300.0 / 1169)) < 1e-9)
        let lg = layout.items.first { $0.key == "lg" }!
        #expect(lg.anchor?.edge == .left && lg.rotation == 90)
    }

    @Test func theRulesGiveTheSamePlacesBack() {
        let displays = [laptop, monitor, portrait]
        let layout = DisplayLayout.capture(displays)
        let origins = layout.origins(for: Dictionary(uniqueKeysWithValues: displays.map { ($0.key, $0.frame.size) }))
        for display in displays {
            #expect(origins[display.key] == display.frame.origin, "\(display.key)")
        }
    }

    /// The monitor now runs at another resolution: it still sits to the
    /// right, the same share of the way up.
    @Test func theRulesHoldWhenASizeChanges() {
        let layout = DisplayLayout.capture([laptop, monitor])
        let origins = layout.origins(for: ["mac": CGSize(width: 1512, height: 982), "dell": CGSize(width: 1920, height: 1080)])
        #expect(origins["mac"] == .zero)
        #expect(origins["dell"]?.x == 1512)
        #expect(origins["dell"]?.y == (-300.0 / 1169 * 982).rounded())
    }

    @Test func aChainOfDisplaysIsFollowed() {
        let far = Placed(key: "far", frame: CGRect(x: 4360, y: -300, width: 1920, height: 1080), isMain: false)
        let layout = DisplayLayout.capture([laptop, far, monitor])
        #expect(layout.items.first { $0.key == "far" }?.anchor?.to == "dell")
        let origins = layout.origins(for: ["mac": laptop.frame.size, "dell": monitor.frame.size, "far": far.frame.size])
        #expect(origins["far"] == far.frame.origin)
        // Without the middle one connected, the far one has nothing to hang from.
        #expect(layout.origins(for: ["mac": laptop.frame.size, "far": far.frame.size])["far"] == nil)
    }

    @Test func aboveAndBelow() {
        let top = Placed(key: "top", frame: CGRect(x: 200, y: -1080, width: 1920, height: 1080), isMain: false)
        let bottom = Placed(key: "bottom", frame: CGRect(x: -100, y: 1169, width: 1920, height: 1080), isMain: false)
        let layout = DisplayLayout.capture([laptop, top, bottom])
        #expect(layout.items.first { $0.key == "top" }?.anchor?.edge == .above)
        #expect(layout.items.first { $0.key == "bottom" }?.anchor?.edge == .below)
        let origins = layout.origins(for: ["mac": laptop.frame.size, "top": top.frame.size, "bottom": bottom.frame.size])
        #expect(origins["top"] == top.frame.origin && origins["bottom"] == bottom.frame.origin)
    }

    @Test func nothingToDoWhenNothingChanged() {
        let displays = [laptop, monitor, portrait]
        #expect(DisplayLayout.capture(displays).operations(from: displays).isEmpty)
    }

    @Test func aMovedDisplayIsPutBack() {
        let layout = DisplayLayout.capture([laptop, monitor])
        var moved = monitor
        moved.frame.origin = CGPoint(x: -2560, y: 0) // macOS put it on the left
        #expect(layout.operations(from: [laptop, moved]) == [.arrange(["mac": .zero, "dell": CGPoint(x: 1800, y: -300)])])
    }

    /// Mirrors are undone and displays turned before modes and places.
    @Test func theStepsComeInTheOrderThatWorks() {
        var saved = [laptop, monitor, portrait]
        saved[1].colorProfile = "/Library/ColorSync/Profiles/Desk.icc"
        let layout = DisplayLayout.capture(saved)
        var now = [laptop, monitor, portrait]
        now[1].mirrorOf = "mac"
        now[1].resolution = DisplayResolution(width: 1920, height: 1080, isHiDPI: true)
        now[2].rotation = 0
        now[2].frame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let operations = layout.operations(from: now)
        #expect(operations.count == 5)
        #expect(operations[0] == .stopMirroring("dell"))
        #expect(operations[1] == .rotate("lg", degrees: 90))
        #expect(operations[2] == .setMode("dell", DisplayResolution(width: 2560, height: 1440, isHiDPI: true), refreshRate: 60))
        // The portrait display has no saved mode, so its place is worked out for its size once turned.
        #expect(operations[3] == .arrange(["mac": .zero, "dell": CGPoint(x: 1800, y: -300), "lg": CGPoint(x: -1080, y: -400)]))
        #expect(operations[4] == .setColorProfile("dell", path: "/Library/ColorSync/Profiles/Desk.icc"))
    }

    /// A mode's size is the unturned one: a portrait display with a saved
    /// mode is placed by its turned size, so one in its place isn't moved.
    @Test func aTurnedDisplayWithASavedModeIsPlacedByItsTurnedSize() {
        var turned = portrait
        turned.resolution = DisplayResolution(width: 1920, height: 1080, isHiDPI: false)
        turned.refreshRate = 60
        let layout = DisplayLayout.capture([laptop, monitor, turned])
        #expect(layout.operations(from: [laptop, monitor, turned]).isEmpty)
    }

    @Test func aMirrorIsMadeAgain() {
        var mirrored = monitor
        mirrored.mirrorOf = "mac"
        let layout = DisplayLayout.capture([laptop, mirrored])
        #expect(layout.items.first { $0.key == "dell" }?.mirrorOf == "mac")
        #expect(layout.operations(from: [laptop, monitor]).contains(.mirror("dell", of: "mac")))
    }

    @Test func aLayoutIsOnlyForItsOwnDisplays() {
        let layout = DisplayLayout.capture([laptop, monitor])
        #expect(layout.operations(from: [laptop, portrait]).isEmpty)
        #expect(layout.operations(from: [laptop]).isEmpty)
        #expect(DisplayLayout.capture([]).items.isEmpty)
    }

    @Test func layoutsSurviveStorage() throws {
        let layout = DisplayLayout.capture([laptop, monitor, portrait])
        let decoded = try JSONDecoder().decode(DisplayLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }
}

@Suite struct DisplayProtectionTests {
    private let operations: [DisplayLayout.Operation] = [
        .stopMirroring("a"), .rotate("a", degrees: 90), .setMode("a", DisplayResolution(width: 1, height: 1, isHiDPI: false), refreshRate: nil),
        .mirror("a", of: "b"), .arrange([:]), .setColorProfile("a", path: nil), .setHDR("a", true),
    ]

    @Test func nothingIsPutBackWhileProtectionIsOff() {
        #expect(DisplayProtection.allowed(operations, by: DisplayProtectionSettings()).isEmpty)
    }

    @Test func onlyTheChosenPartsArePutBack() {
        var settings = DisplayProtectionSettings(enabled: true)
        #expect(DisplayProtection.allowed(operations, by: settings).count == 5) // profile and HDR are off at first
        settings.resolution = false
        settings.mirroring = false
        #expect(DisplayProtection.allowed(operations, by: settings) == [.rotate("a", degrees: 90), .arrange([:])])
        settings.colorProfile = true
        settings.hdr = true
        #expect(DisplayProtection.allowed(operations, by: settings).count == 4)
    }

    @Test func settingsSurviveStorageAndBadTextGivesTheDefaults() {
        let settings = DisplayProtectionSettings(enabled: true, position: false, hdr: true)
        #expect(DisplayProtectionSettings.decode(settings.encoded) == settings)
        #expect(DisplayProtectionSettings.decode("nonsense") == DisplayProtectionSettings())
    }

    /// macOS may keep undoing an arrangement: three tries, then ScreenHelm stops.
    @Test func threeTriesThenItGivesUp() {
        var attempts = DisplayProtection.Attempts()
        let start = Date()
        var answers: [Bool] = []
        for second in [0.0, 2, 4, 6] { answers.append(attempts.shouldTry("a|b", at: start.addingTimeInterval(second))) }
        #expect(answers == [true, true, true, false])
        #expect(attempts.gaveUp)
        // Another set of displays, a success, or a quiet minute starts the count again.
        let otherSet = attempts.shouldTry("a|c", at: start.addingTimeInterval(7))
        #expect(otherSet)
        attempts.succeeded()
        #expect(!attempts.gaveUp)
        var again = DisplayProtection.Attempts()
        for second in 0..<3 { _ = again.shouldTry("x", at: start.addingTimeInterval(Double(second))) }
        let fourth = again.shouldTry("x", at: start.addingTimeInterval(5))
        let afterAMinute = again.shouldTry("x", at: start.addingTimeInterval(120))
        #expect(!fourth && afterAMinute)
    }
}

@Suite struct DisplayEventTests {
    private let desk = DisplayEventAction(trigger: .connected, display: "dell", kind: .shortcut, target: "Desk Mode")
    private let any = DisplayEventAction(trigger: .connected, kind: .open, target: "/Applications/Music.app")
    private let wake = DisplayEventAction(trigger: .wake, kind: .shortcut, target: "Morning")
    private let empty = DisplayEventAction(trigger: .connected, kind: .shortcut, target: "")

    @Test func actionsRunForTheirDisplayOrForAny() {
        let all = [desk, any, wake, empty]
        #expect(DisplayEventAction.matching(all, trigger: .connected, display: "dell") == [desk, any])
        #expect(DisplayEventAction.matching(all, trigger: .connected, display: "lg") == [any])
        #expect(DisplayEventAction.matching(all, trigger: .disconnected, display: "dell").isEmpty)
        #expect(DisplayEventAction.matching(all, trigger: .wake, display: nil) == [wake])
    }

    @Test func actionsSurviveStorage() {
        #expect(DisplayEventAction.decode(DisplayEventAction.encode([desk, wake])) == [desk, wake])
        #expect(DisplayEventAction.decode("garbage").isEmpty)
    }

    /// A connected display from the user's list keeps the Mac awake, the
    /// first of the list that is connected, and not on a low battery.
    @Test func aConnectedDisplayKeepsTheMacAwake() {
        func display(battery: BatteryLevel? = nil) -> String? {
            KeepAwakePolicy.display(connected: ["mac", "dell", "tv"], keepingAwake: ["lg", "dell", "tv"], battery: battery)
        }
        #expect(display() == "dell")
        #expect(display(battery: BatteryLevel(percent: 10, onBattery: true)) == nil)
        #expect(display(battery: BatteryLevel(percent: 10, onBattery: false)) == "dell")
        #expect(display(battery: BatteryLevel(percent: 21, onBattery: true)) == "dell")
        #expect(KeepAwakePolicy.display(connected: ["mac"], keepingAwake: ["dell"], battery: nil) == nil)
    }
}
