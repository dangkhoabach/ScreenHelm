import Testing
@testable import ScreenHelmCore

@Suite struct ColorPauseTests {
    /// Only what was on is switched off, and only that comes back.
    @Test func onlyWhatWasOnIsPausedAndRestored() {
        var pause = ColorPause()
        let off = pause.update(hdrShown: true, nightShiftOn: true, trueToneOn: false)
        #expect(off.nightShift == false && off.trueTone == nil)
        #expect(pause.isPaused)
        let back = pause.update(hdrShown: false, nightShiftOn: false, trueToneOn: false)
        #expect(back.nightShift == true && back.trueTone == nil)
        #expect(!pause.isPaused)
    }

    /// While HDR stays on, nothing is switched again; without HDR nothing happens.
    @Test func nothingHappensTwiceOrWithoutHDR() {
        var pause = ColorPause()
        _ = pause.update(hdrShown: true, nightShiftOn: true, trueToneOn: true)
        let again = pause.update(hdrShown: true, nightShiftOn: false, trueToneOn: false)
        #expect(again.nightShift == nil && again.trueTone == nil)
        _ = pause.update(hdrShown: false, nightShiftOn: false, trueToneOn: false)
        let idle = pause.update(hdrShown: false, nightShiftOn: true, trueToneOn: true)
        #expect(idle.nightShift == nil && idle.trueTone == nil)
    }
}
