import CoreGraphics
import Foundation
import Testing
@testable import ScreenHelmCore

@Suite struct ResolutionWatchTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let laptop = CGSize(width: 1800, height: 1169), monitor = CGSize(width: 2560, height: 1440)

    /// The first look and a newly connected display are not changes; one display changing is.
    @Test func oneDisplayChangingIsTheSource() {
        var watch = ResolutionWatch()
        #expect(watch.source(in: ["mac": laptop], at: start) == nil)
        #expect(watch.source(in: ["mac": laptop, "dell": monitor], at: start) == nil)
        #expect(watch.source(in: ["mac": CGSize(width: 1512, height: 982), "dell": monitor], at: start) == "mac")
        #expect(watch.source(in: ["mac": CGSize(width: 1512, height: 982), "dell": monitor], at: start) == nil)
    }

    /// What ScreenHelm set while following is not followed in turn; two changing at once is no one's choice.
    @Test func followingDoesNotSetOffMoreFollowing() {
        var watch = ResolutionWatch()
        _ = watch.source(in: ["mac": laptop, "dell": monitor], at: start)
        let followed = CGSize(width: 3008, height: 1692)
        watch.expect(followed, on: "dell", at: start)
        #expect(watch.source(in: ["mac": laptop, "dell": followed], at: start.addingTimeInterval(1)) == nil)
        #expect(watch.source(in: ["mac": CGSize(width: 1512, height: 982), "dell": monitor], at: start.addingTimeInterval(2)) == nil)
    }

    /// A size expected long ago is forgotten: the same size later is someone's choice.
    @Test func anOldExpectationIsForgotten() {
        var watch = ResolutionWatch()
        _ = watch.source(in: ["dell": monitor], at: start)
        let other = CGSize(width: 3008, height: 1692)
        watch.expect(other, on: "dell", at: start)
        #expect(watch.source(in: ["dell": other], at: start.addingTimeInterval(ResolutionWatch.expectationLifetime + 1)) == "dell")
    }
}
