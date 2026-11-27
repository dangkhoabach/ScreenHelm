import Foundation
import Testing
@testable import ScreenHelmCore

@Suite struct VirtualScreenTests {
    private let screen = VirtualScreen(name: "Share", serial: 0x1001, pixelWidth: 3840, pixelHeight: 2160, refreshRates: [60, 120])

    @Test func modesStepDownInTheSameShapeAtEveryRate() {
        let modes = screen.modes
        #expect(modes.first == .init(width: 1920, height: 1080, refreshRate: 120))
        #expect(modes[1] == .init(width: 1920, height: 1080, refreshRate: 60))
        #expect(modes.contains(.init(width: 1280, height: 720, refreshRate: 60)))
        #expect(modes.contains(.init(width: 960, height: 540, refreshRate: 120)))
        let even = modes.allSatisfy { $0.width % 2 == 0 && $0.height % 2 == 0 }
        #expect(even)
        let shapes = Set(modes.map { (Double($0.width) / Double($0.height) * 100).rounded() })
        #expect(shapes == [178])
        #expect(Set(modes).count == modes.count)
    }

    @Test func aPlainScreenListsPixels() {
        var plain = screen
        plain.hiDPI = false
        #expect(plain.modes.first == .init(width: 3840, height: 2160, refreshRate: 120))
    }

    @Test func theModeListStaysUnderWhatMacOSKeeps() {
        var busy = screen
        busy.refreshRates = VirtualScreen.allowedRefreshRates
        #expect(busy.modes.count <= VirtualScreen.maximumModes)
        #expect(busy.isValid)
    }

    @Test func whatMacOSWouldRefuseIsNotValid() {
        var wrong = screen
        wrong.name = "  "
        #expect(!wrong.isValid)
        wrong = screen
        wrong.pixelWidth = 200
        #expect(!wrong.isValid)
        wrong = screen
        wrong.pixelHeight = 20000
        #expect(!wrong.isValid)
        wrong = screen
        wrong.refreshRates = [61]
        #expect(!wrong.isValid)
        wrong.refreshRates = []
        #expect(!wrong.isValid)
        #expect(screen.isValid)
    }

    @Test func everyScreenGetsASerialOfItsOwn() {
        #expect(VirtualScreen.nextSerial(after: []) == 0x1001)
        var second = screen
        second.serial = 0x1007
        #expect(VirtualScreen.nextSerial(after: [screen, second]) == 0x1008)
        // A deleted screen's serial isn't given out again.
        #expect(VirtualScreen.nextSerial(after: [screen], lastUsed: 0x1009) == 0x100A)
    }

    @Test func templatesAreValidScreens() {
        for template in VirtualScreen.templates {
            let made = VirtualScreen(name: template.id, serial: 1, pixelWidth: template.pixelWidth, pixelHeight: template.pixelHeight)
            #expect(made.isValid && !made.modes.isEmpty, "\(template.id)")
        }
    }

    /// A screen in the shape of the MacBook's panel, 3840 pixels on its long side.
    @Test func aScreenMatchedToARealDisplayKeepsItsShape() {
        let size = VirtualScreen.matching(width: 3024, height: 1964, longSide: 3840)
        #expect(size.pixelWidth == 3840 && size.pixelHeight == 2494)
        let portrait = VirtualScreen.matching(width: 1080, height: 1920, longSide: 3840)
        #expect(portrait.pixelWidth == 2160 && portrait.pixelHeight == 3840)
    }

    @Test func screensSurviveStorage() throws {
        let decoded = try JSONDecoder().decode(VirtualScreen.self, from: JSONEncoder().encode(screen))
        #expect(decoded == screen)
    }
}

@Suite struct ScaledResolutionsTests {
    typealias Size = ScaledResolutions.Size

    /// The first entry of Apple's own file for the MacBook Pro 14": 3600 × 2338
    /// pixels, listed by macOS as 1800 × 1169.
    @Test func anEntryIsTheDrawingSizeInBigEndian() {
        let entry = ScaledResolutions.entry(for: Size(width: 1800, height: 1169))
        #expect([UInt8](entry) == [0x00, 0x00, 0x0E, 0x10, 0x00, 0x00, 0x09, 0x22])
        #expect(ScaledResolutions.size(of: entry) == Size(width: 1800, height: 1169))
    }

    @Test func entriesWithFlagsAreReadAndShortOnesRefused() {
        let flagged = Data([0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x06, 0x40, 0x00, 0x00, 0x00, 0x01]) // 2560 × 1600, flags 1
        #expect(ScaledResolutions.size(of: flagged) == Size(width: 1280, height: 800))
        #expect(ScaledResolutions.size(of: Data([0, 0, 1])) == nil)
        #expect(ScaledResolutions.size(of: Data(repeating: 0, count: 8)) == nil)
    }

    @Test func theChipSetsTheWidestDesktop() {
        #expect(ScaledResolutions.maximumBackingWidth(chip: "Apple M3 Pro") == 7680)
        #expect(ScaledResolutions.maximumBackingWidth(chip: "Apple M2") == 6144)
        #expect(ScaledResolutions.maximumBackingWidth(chip: "Apple M4 Max") == 6720)
        #expect(ScaledResolutions.maximumBackingWidth(chip: "Apple M1 Ultra") == 7680)
    }

    @Test func theGeneratedSizesKeepThePanelsShapeAndStopAtThePanel() {
        let sizes = ScaledResolutions.generate(panelWidth: 3024, panelHeight: 1964, maximumBackingWidth: 7680)
        #expect(sizes.count == 24)
        #expect(sizes.first == Size(width: 1008, height: 654))
        #expect(sizes.last == Size(width: 3024, height: 1964))
        #expect(sizes == sizes.sorted())
        for size in sizes {
            #expect(size.width % 2 == 0 && size.height % 2 == 0)
            #expect(abs(Double(size.width) / Double(size.height) - 3024.0 / 1964) < 0.01)
        }
    }

    /// A 5K panel on a chip that draws 6144 pixels across: no desktop wider than 3072 points.
    @Test func theChipsLimitCapsAWidePanel() {
        let sizes = ScaledResolutions.generate(panelWidth: 5120, panelHeight: 2880, maximumBackingWidth: 6144)
        #expect(sizes.last?.width == 3072)
        #expect(ScaledResolutions.generate(panelWidth: 0, panelHeight: 0, maximumBackingWidth: 7680).isEmpty)
        #expect(ScaledResolutions.generate(panelWidth: 1280, panelHeight: 720, maximumBackingWidth: 1000).isEmpty)
    }

    @Test func theFileIsNamedByTheIDsInHex() {
        #expect(ScaledResolutions.path(vendor: 1552, product: 41039)
            == "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/DisplayProductID-a04f")
        #expect(ScaledResolutions.path(vendor: 0x10AC, product: 0xA0F1, root: "/tmp/x") == "/tmp/x/DisplayVendorID-10ac/DisplayProductID-a0f1")
    }

    /// Apple's file for the model is the starting point: its own entries
    /// and settings stay, the new sizes are added once.
    @Test func sizesAreAddedToWhatTheFileAlreadyHas() throws {
        let apple: [String: Any] = [
            "DisplayVendorID": 1552, "DisplayProductID": 41039, "DisplayProductName": "Color LCD", "IOGFlags": 4,
            "scale-resolutions": [ScaledResolutions.entry(for: Size(width: 1800, height: 1169)), ScaledResolutions.entry(for: Size(width: 1512, height: 982))],
        ]
        let base = try PropertyListSerialization.data(fromPropertyList: apple, format: .xml, options: 0)
        let adding = [Size(width: 1512, height: 982), Size(width: 1650, height: 1072), Size(width: 2016, height: 1310)]
        let result = try ScaledResolutions.propertyList(base: base, vendor: 1552, product: 41039, name: "Built-in", adding: adding)
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: result, format: nil) as? [String: Any])
        #expect(dictionary["IOGFlags"] as? Int == 4)
        #expect(dictionary["DisplayProductName"] as? String == "Color LCD")
        #expect(ScaledResolutions.sizes(in: result).map(\.width) == [1800, 1512, 1650, 2016])
        #expect(String(decoding: result.prefix(40), as: UTF8.self).hasPrefix("<?xml"))
        // Installing the same sizes again changes nothing.
        let again = try ScaledResolutions.propertyList(base: result, vendor: 1552, product: 41039, name: "Built-in", adding: adding)
        #expect(ScaledResolutions.sizes(in: again) == ScaledResolutions.sizes(in: result))
    }

    @Test func aDisplayWithNoFileGetsAFreshOne() throws {
        let result = try ScaledResolutions.propertyList(base: nil, vendor: 0x10AC, product: 0xA0F1, name: "DELL U2723QE",
                                                        adding: [Size(width: 2560, height: 1440)])
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: result, format: nil) as? [String: Any])
        #expect(dictionary["DisplayVendorID"] as? Int == 0x10AC && dictionary["DisplayProductID"] as? Int == 0xA0F1)
        #expect(dictionary["DisplayProductName"] as? String == "DELL U2723QE")
        #expect(ScaledResolutions.sizes(in: result) == [Size(width: 2560, height: 1440)])
        #expect(ScaledResolutions.sizes(in: Data("junk".utf8)).isEmpty)
    }

    @Test func theCommandsQuoteTheirPaths() {
        let destination = "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/DisplayProductID-a04f"
        #expect(ScaledResolutions.installCommand(from: "/tmp/it's here/file", to: destination)
            == "/bin/mkdir -p '/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610' && /bin/cp '/tmp/it'\\''s here/file' '\(destination)' && /bin/chmod 644 '\(destination)'")
        #expect(ScaledResolutions.removeCommand(destination) == "/bin/rm -f '\(destination)'")
    }

    /// An external 27" monitor made to show things as big as the MacBook does.
    @Test func textSizeIsMatchedByPointsPerMillimetre() {
        func mode(_ number: Int, _ width: Int, _ height: Int) -> DisplayModeInfo {
            DisplayModeInfo(number: number, width: width, height: height, pixelWidth: width * 2, pixelHeight: height * 2, refreshRate: 60, isHiDPI: true)
        }
        let modes = [mode(1, 1920, 1080), mode(2, 2560, 1440), mode(3, 3008, 1692), mode(4, 3360, 1890), mode(5, 3840, 2160)]
        // The MacBook: 1800 points across 302 mm. The monitor is 597 mm wide.
        let match = DisplayModes.resolution(matching: 1800.0 / 302, widthMillimeters: 597, like: modes[0], in: modes)
        #expect(match?.width == 3360)
        #expect(DisplayModes.resolution(matching: 0, widthMillimeters: 597, like: modes[0], in: modes) == nil)
        // Within 10%, the nearest; past it, none: 3360 is 6% under the 3558 wanted, and on a 802 mm
        // monitor the widest, 3840, is 20% under the 4780 wanted.
        #expect(DisplayModes.resolution(matching: 1800.0 / 302, widthMillimeters: 597, like: modes[0], in: modes, within: 0.1)?.width == 3360)
        #expect(DisplayModes.resolution(matching: 1800.0 / 302, widthMillimeters: 802, like: modes[0], in: modes, within: 0.1) == nil)
    }
}
