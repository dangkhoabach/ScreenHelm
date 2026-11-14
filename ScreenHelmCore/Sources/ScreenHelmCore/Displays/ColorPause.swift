import Foundation

/// Night Shift and True Tone switched off while a display shows HDR, and
/// back on after: only the ones that were on, and only once.
public struct ColorPause: Equatable, Sendable {
    public private(set) var pausedNightShift = false
    public private(set) var pausedTrueTone = false

    public init() {}

    public var isPaused: Bool { pausedNightShift || pausedTrueTone }

    /// What to set now: false switches one off, true back on, nil leaves it.
    public mutating func update(hdrShown: Bool, nightShiftOn: Bool, trueToneOn: Bool) -> (nightShift: Bool?, trueTone: Bool?) {
        if hdrShown {
            var change: (nightShift: Bool?, trueTone: Bool?) = (nil, nil)
            if nightShiftOn && !pausedNightShift {
                pausedNightShift = true
                change.nightShift = false
            }
            if trueToneOn && !pausedTrueTone {
                pausedTrueTone = true
                change.trueTone = false
            }
            return change
        }
        let restore: (nightShift: Bool?, trueTone: Bool?) = (pausedNightShift ? true : nil, pausedTrueTone ? true : nil)
        pausedNightShift = false
        pausedTrueTone = false
        return restore
    }
}
