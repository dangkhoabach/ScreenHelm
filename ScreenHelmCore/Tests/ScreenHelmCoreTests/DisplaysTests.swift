import Foundation
import GRDB
import Testing
@testable import ScreenHelmCore

@Suite struct DisplayIdentityTests {
    private let dell = DisplayIdentity(vendor: 0x10AC, product: 0xA0F1, serial: 0x1234, alphanumericSerial: "ABC1", week: 12, year: 2023,
                                       location: "IOService:/dispext0")

    @Test func aDisplayAloneIsToldByVendorModelAndSerial() {
        let builtIn = DisplayIdentity(vendor: 0x610, product: 0xA050, serial: 0xFD626D62)
        #expect(DisplayIdentity.keys(for: [builtIn, dell]) == ["0610-a050-fd626d62", "10ac-a0f1-00001234"])
        #expect(builtIn.key == "0610-a050-fd626d62")
    }

    @Test func twinsUseTheTextSerialThenThePort() {
        var second = dell
        second.alphanumericSerial = "ABC2"
        let dated = DisplayIdentity.keys(for: [dell, second])
        #expect(dated == ["10ac-a0f1-00001234-ABC1-12-2023", "10ac-a0f1-00001234-ABC2-12-2023"])

        var samePort = dell
        samePort.location = "IOService:/dispext1"
        let ported = DisplayIdentity.keys(for: [dell, samePort])
        #expect(ported[0] == "10ac-a0f1-00001234-ABC1-12-2023@IOService:/dispext0")
        #expect(ported[1] == "10ac-a0f1-00001234-ABC1-12-2023@IOService:/dispext1")
        #expect(Set(ported).count == 2)
    }

    /// A monitor set up alone keeps its settings when a second one of the
    /// same model is plugged in.
    @Test func aTwinFallsBackToTheModelsProfile() {
        let stored: Set = ["10ac-a0f1-00001234"]
        #expect(DisplayIdentity.storedKey(for: "10ac-a0f1-00001234-ABC1-12-2023", in: stored) == "10ac-a0f1-00001234")
        #expect(DisplayIdentity.storedKey(for: "10ac-a0f1-00001234", in: stored) == "10ac-a0f1-00001234")
        #expect(DisplayIdentity.storedKey(for: "0610-a050-fd626d62", in: stored) == nil)
    }

    @Test func softwareOnlyKinds() {
        #expect(DisplayKind.allCases.filter(\.isSoftwareOnly) == [.airPlay, .sidecar, .virtual])
    }
}

/// The modes of the MacBook Pro 14" the feature was built on, cut down:
/// each size with and without the camera housing, at 120 and 60 Hz.
private func mode(_ number: Int, _ width: Int, _ height: Int, hz: Double = 60, hiDPI: Bool = true, bits: Int = 10) -> DisplayModeInfo {
    DisplayModeInfo(number: number, width: width, height: height, pixelWidth: width * (hiDPI ? 2 : 1),
                    pixelHeight: height * (hiDPI ? 2 : 1), refreshRate: hz, isHiDPI: hiDPI, bitsPerSample: bits)
}

private let macBookModes: [DisplayModeInfo] = [
    mode(60, 1800, 1125, hz: 120), mode(61, 1800, 1125), mode(62, 1800, 1125, hz: 59.94),
    mode(66, 1800, 1169, hz: 120), mode(67, 1800, 1169), mode(68, 1800, 1169, hz: 59.94),
    mode(40, 1512, 945, hz: 120), mode(41, 1512, 945), mode(46, 1512, 982, hz: 120), mode(47, 1512, 982),
    mode(20, 1147, 745, hz: 120), mode(21, 1147, 745),
    mode(90, 1800, 1169, hz: 120, hiDPI: false), mode(91, 1800, 1169, hiDPI: false),
    mode(100, 1920, 1080), mode(131, 3024, 1964, hz: 120, hiDPI: false),
]

@Suite struct DisplayModesTests {
    @Test func sizesAreListedOnceLargestFirstSharpBeforePlain() {
        let list = DisplayModes.resolutions(in: macBookModes)
        #expect(list.first == DisplayResolution(width: 3024, height: 1964, isHiDPI: false))
        #expect(list.count == Set(list).count)
        let sharp = list.firstIndex(of: DisplayResolution(width: 1800, height: 1169, isHiDPI: true))!
        let plain = list.firstIndex(of: DisplayResolution(width: 1800, height: 1169, isHiDPI: false))!
        #expect(sharp < plain)
        #expect(DisplayResolution(width: 1800, height: 1169, isHiDPI: true).label == "1800 × 1169")
    }

    /// 59.94 Hz and 60 Hz show as one "60".
    @Test func ratesAreWholeNumbersHighestFirst() {
        let size = DisplayResolution(width: 1800, height: 1169, isHiDPI: true)
        #expect(DisplayModes.refreshRates(for: size, in: macBookModes) == [120, 60])
    }

    @Test func theExactRateWinsOverItsFractionalTwin() {
        let size = DisplayResolution(width: 1800, height: 1169, isHiDPI: true)
        #expect(DisplayModes.mode(for: size, near: 60, in: macBookModes)?.number == 67)
        #expect(DisplayModes.mode(for: size, near: 120, in: macBookModes)?.number == 66)
        // A size that doesn't come at 120 gives its closest.
        #expect(DisplayModes.mode(for: DisplayResolution(width: 1920, height: 1080, isHiDPI: true), near: 120, in: macBookModes)?.number == 100)
        #expect(DisplayModes.mode(for: DisplayResolution(width: 1, height: 1, isHiDPI: true), near: 60, in: macBookModes) == nil)
    }

    @Test func theSameSizeAtAnotherRate() {
        let current = macBookModes.first { $0.number == 66 }!
        #expect(DisplayModes.mode(like: current, atRate: 60, in: macBookModes)?.number == 67)
        #expect(DisplayModes.mode(like: current, atRate: 75, in: macBookModes) == nil)
    }

    @Test func theCameraHousingPairSharesWidthAndRate() {
        let withNotch = macBookModes.first { $0.number == 66 }!
        let twin = DisplayModes.notchTwin(of: withNotch, in: macBookModes)
        #expect(twin?.number == 60)
        #expect(DisplayModes.showsNotch(withNotch, in: macBookModes) == true)
        #expect(DisplayModes.showsNotch(twin!, in: macBookModes) == false)
        #expect(DisplayModes.notchTwin(of: twin!, in: macBookModes)?.number == 66)
        // 16:9 on the same panel has no such twin.
        #expect(DisplayModes.notchTwin(of: macBookModes.first { $0.number == 100 }!, in: macBookModes) == nil)
        #expect(DisplayModes.showsNotch(macBookModes.first { $0.number == 100 }!, in: macBookModes) == nil)
    }

    @Test func theSliderStaysInOneShapeAndSharpness() {
        let current = macBookModes.first { $0.number == 66 }!
        let steps = DisplayModes.sliderResolutions(like: current, in: macBookModes)
        #expect(steps.map(\.width) == [1147, 1512, 1800])
        let allSharp = steps.allSatisfy { $0.isHiDPI }
        #expect(allSharp)
        #expect(DisplayModes.neighbor(of: current, in: macBookModes, larger: false)?.number == 46)
        #expect(DisplayModes.neighbor(of: current, in: macBookModes, larger: true) == nil)
    }

    @Test func sharpAndPlainOfOneSize() {
        let current = macBookModes.first { $0.number == 66 }!
        #expect(DisplayModes.hiDPITwin(of: current, in: macBookModes)?.number == 90)
        #expect(DisplayModes.hiDPITwin(of: macBookModes.first { $0.number == 100 }!, in: macBookModes) == nil)
    }
}

@Suite struct BrightnessCurveTests {
    @Test func softwareOnlyNeverGoesUnderTheFloor() {
        let dark = BrightnessCurve.split(0, hasHardware: false, combined: true, allowBlack: false)
        #expect(dark.software == 0.15 && dark.hardware == 1)
        #expect(BrightnessCurve.split(1, hasHardware: false, combined: true, allowBlack: false).software == 1)
        #expect(BrightnessCurve.split(0, hasHardware: false, combined: true, allowBlack: true).software == 0)
    }

    /// The backlight runs out first; only then are the pixels darkened.
    @Test func combinedRunsTheBacklightDownFirst() {
        let top = BrightnessCurve.split(1, hasHardware: true, combined: true, allowBlack: false)
        #expect(top == .init(hardware: 1, software: 1))
        let knee = BrightnessCurve.split(0.2, hasHardware: true, combined: true, allowBlack: false)
        #expect(knee == .init(hardware: 0, software: 1))
        let below = BrightnessCurve.split(0.1, hasHardware: true, combined: true, allowBlack: false)
        #expect(below.hardware == 0)
        #expect(abs(below.software - 0.575) < 1e-9)
        let middle = BrightnessCurve.split(0.6, hasHardware: true, combined: true, allowBlack: false)
        #expect(abs(middle.hardware - 0.5) < 1e-9 && middle.software == 1)
    }

    @Test func hardwareAloneIsTheSlider() {
        #expect(BrightnessCurve.split(0.3, hasHardware: true, combined: false, allowBlack: false) == .init(hardware: 0.3, software: 1))
        #expect(BrightnessCurve.split(7, hasHardware: true, combined: false, allowBlack: false).hardware == 1)
        #expect(BrightnessCurve.split(-1, hasHardware: true, combined: false, allowBlack: false).hardware == 0)
    }

    @Test(arguments: [0.0, 0.05, 0.2, 0.37, 0.8, 1.0], [true, false])
    func theSliderValueComesBackFromItsSplit(_ value: Double, _ allowBlack: Bool) {
        for (hardware, combined) in [(true, true), (true, false), (false, true)] {
            let split = BrightnessCurve.split(value, hasHardware: hardware, combined: combined, allowBlack: allowBlack)
            let back = BrightnessCurve.value(hardware: split.hardware, software: split.software, hasHardware: hardware,
                                             combined: combined, allowBlack: allowBlack)
            #expect(abs(back - value) < 1e-9, "\(hardware) \(combined)")
        }
    }

    @Test func keysStepInSixteenthsAndLandOnTheGrid() {
        #expect(BrightnessCurve.step(from: 0.5, up: true, fine: false) == 0.5625)
        #expect(BrightnessCurve.step(from: 0.5, up: false, fine: false) == 0.4375)
        // Off the grid, the next press lands on it rather than a full step away.
        #expect(BrightnessCurve.step(from: 0.51, up: true, fine: false) == 0.5625)
        #expect(BrightnessCurve.step(from: 0.51, up: false, fine: false) == 0.5)
        #expect(BrightnessCurve.step(from: 0.5, up: true, fine: true) == 0.515625)
        #expect(BrightnessCurve.step(from: 1, up: true, fine: false) == 1)
        #expect(BrightnessCurve.step(from: 0, up: false, fine: false) == 0)
        // Sixteen presses cross the whole range.
        var value = 0.0
        for _ in 0..<16 { value = BrightnessCurve.step(from: value, up: true, fine: false) }
        #expect(value == 1)
    }

    @Test func nothingComesBackDarkerThanTheFloor() {
        let black = BrightnessCurve.split(0, hasHardware: false, combined: true, allowBlack: true)
        #expect(BrightnessCurve.restorable(black).software == 0.15)
        let fine = BrightnessCurve.Split(hardware: 0.4, software: 1)
        #expect(BrightnessCurve.restorable(fine) == fine)
    }

    @Test func chiclets() {
        #expect(BrightnessCurve.chiclets(0) == 0)
        #expect(BrightnessCurve.chiclets(0.5) == 8)
        #expect(BrightnessCurve.chiclets(1) == 16)
    }
}

@Suite struct DDCPacketTests {
    /// Brightness to 50: the bytes ddcutil and m1ddc put on the wire.
    @Test func setBrightnessPacket() {
        #expect(DDCPacket.setVCP(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        let input: [UInt8] = [0x6E, 0x51, 0x84, 0x03, 0x60, 0x0F, 0x11]
        #expect(DDCPacket.setVCP(0x60, value: 0x0F11) == [0x84, 0x03, 0x60, 0x0F, 0x11, input.reduce(0, ^)])
    }

    /// The read checksum includes the host address, like the write one.
    @Test func getPacketChecksumIncludesTheHostAddress() {
        #expect(DDCPacket.getVCP(0x10) == [0x82, 0x01, 0x10, 0xAC])
    }

    private func reply(code: UInt8 = 0x10, result: UInt8 = 0, maximum: UInt16 = 100, current: UInt16 = 75) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00, UInt8(maximum >> 8), UInt8(maximum & 0xFF),
                              UInt8(current >> 8), UInt8(current & 0xFF)]
        bytes.append(bytes.reduce(0x50, ^))
        return bytes
    }

    @Test func aReplyGivesCurrentAndMaximum() throws {
        let value = try DDCPacket.parseReply(reply(), for: 0x10).get()
        #expect(value == VCPValue(current: 75, maximum: 100))
        #expect(value.fraction == 0.75)
        let wide = try DDCPacket.parseReply(reply(maximum: 0x0312, current: 0x0200), for: 0x10).get()
        #expect(wide == VCPValue(current: 512, maximum: 786))
        #expect(VCPValue(current: 3, maximum: 0).fraction == 0)
    }

    @Test func badRepliesAreToldApart() {
        #expect(DDCPacket.parseReply([0x6E, 0x88], for: 0x10) == .failure(.shortReply))
        var corrupt = reply()
        corrupt[9] ^= 0xFF
        #expect(DDCPacket.parseReply(corrupt, for: 0x10) == .failure(.badChecksum))
        #expect(DDCPacket.parseReply(corrupt, for: 0x10, ignoringChecksum: true) == .success(VCPValue(current: 180, maximum: 100)))
        #expect(DDCPacket.parseReply(reply(result: 1), for: 0x10) == .failure(.unsupported))
        #expect(DDCPacket.parseReply(reply(code: 0x12), for: 0x10) == .failure(.wrongCode))
        var other = reply()
        other[2] = 0xE3
        other[10] = other[0..<10].reduce(0x50, ^)
        #expect(DDCPacket.parseReply(other, for: 0x10) == .failure(.unexpectedReply))
        // A monitor that isn't there answers with zeros.
        #expect(DDCPacket.parseReply([UInt8](repeating: 0, count: 11), for: 0x10) != .success(VCPValue(current: 0, maximum: 0)))
    }

    @Test func fractionsScaleToTheMonitorsRange() {
        #expect(DDCPacket.value(for: 0.5, maximum: 100) == 50)
        #expect(DDCPacket.value(for: 2, maximum: 255) == 255)
        #expect(DDCPacket.value(for: -1, maximum: 255) == 0)
    }

    @Test func onlyKnownSettingsAreWrittenUnlessTheUserAllowsMore() {
        #expect(DDCPacket.mayWrite(0x10, allowingAnyCode: false))
        #expect(!DDCPacket.mayWrite(0x04, allowingAnyCode: false)) // factory reset
        #expect(DDCPacket.mayWrite(0x04, allowingAnyCode: true))
    }

    @Test func capabilitiesStringIsRead() throws {
        let text = "(prot(monitor)type(lcd)model(U2723QE)cmds(01 02 03 07 0C E3 F3)vcp(02 04 10 12 14(05 08 0B) 60(0F 11 12 1B) 62 8D(01 02) D6(01 04 05))mccs_ver(2.1))"
        let capabilities = try #require(DDCCapabilities(parsing: text))
        #expect(capabilities.model == "U2723QE")
        #expect(capabilities.mccsVersion == "2.1")
        #expect(capabilities.supports(.brightness) && capabilities.supports(.volume))
        #expect(!capabilities.supports(.redGain))
        #expect(capabilities.inputs.map(\.value) == [15, 17, 18, 27])
        #expect(capabilities.inputs.map(\.standardName) == ["DisplayPort 1", "HDMI 1", "HDMI 2", "USB-C"])
        #expect(capabilities.codes[0x14] == [5, 8, 11])
        #expect(capabilities.codes[0x10] == [])
        #expect(DDCCapabilities(parsing: "garbage") == nil)
        #expect(DDCCapabilities(parsing: "(prot(monitor)vcp(10 12") == nil)
        #expect(DDCInput(value: 99).standardName == "Input 99")
    }
}

@Suite struct GammaTableTests {
    private let ramp: [Float] = (0..<256).map { Float($0) / 255 }
    private var base: GammaTable.Channels { .init(red: ramp, green: ramp, blue: ramp) }

    @Test func neutralLeavesTheTableAlone() {
        #expect(GammaTable.apply(.neutral, to: base) == base)
        #expect(PictureAdjustment.neutral.isNeutral)
        #expect(!PictureAdjustment(brightness: 0.5).isNeutral)
    }

    @Test func dimmingScalesEveryEntry() {
        let half = GammaTable.apply(PictureAdjustment(brightness: 0.5), to: base)
        #expect(half.red[255] == 0.5 && half.green[255] == 0.5 && half.blue[255] == 0.5)
        #expect(half.red[0] == 0)
        #expect(abs(half.red[128] - ramp[128] / 2) < 1e-6)
    }

    @Test func invertSwapsTheEnds() {
        let inverted = GammaTable.apply(PictureAdjustment(invert: true), to: base)
        #expect(inverted.red[0] == 1 && inverted.red[255] == 0)
    }

    @Test func contrastPivotsOnMidGreyAndClips() {
        let more = GammaTable.apply(PictureAdjustment(contrast: 0.5), to: base)
        #expect(more.red[0] == 0 && more.red[255] == 1)
        #expect(more.red[64] < ramp[64] && more.red[192] > ramp[192])
        #expect(abs(more.red[128] - ramp[128]) < 0.005)
        let flat = GammaTable.apply(PictureAdjustment(contrast: -1), to: base)
        #expect(flat.red.allSatisfy { $0 == 0.5 })
    }

    @Test func gammaBendsTheMiddleOnly() {
        let lifted = GammaTable.apply(PictureAdjustment(gamma: 0.5), to: base)
        #expect(lifted.red[0] == 0 && lifted.red[255] == 1)
        #expect(lifted.red[64] > ramp[64])
    }

    @Test func gainsAreperChannel() {
        let result = GammaTable.apply(PictureAdjustment(redGain: 0.5, blueGain: 0.25), to: base)
        #expect(result.red[255] == 0.5 && result.green[255] == 1 && result.blue[255] == 0.25)
    }

    @Test func temperatureNeverGoesPastWhite() {
        let neutral = GammaTable.temperatureGains(6500)
        #expect(abs(neutral.red - 1) < 1e-9 && abs(neutral.green - 1) < 1e-9 && abs(neutral.blue - 1) < 1e-9)
        let warm = GammaTable.temperatureGains(3000)
        #expect(warm.red == 1 && warm.green < 1 && warm.blue < warm.green)
        let cool = GammaTable.temperatureGains(9000)
        #expect(cool.blue == 1 && cool.red < 1)
        let table = GammaTable.apply(PictureAdjustment(temperature: 3000), to: base)
        #expect(table.red[255] == 1 && table.blue[255] < 0.7)
    }

    @Test func quantizationLeavesFewLevels() {
        let coarse = GammaTable.apply(PictureAdjustment(quantization: 4), to: base)
        #expect(Set(coarse.red).count == 4)
        #expect(coarse.red[255] == 1 && coarse.red[0] == 0)
    }

    /// Boost is the only thing that goes above 1, and it scales after clipping.
    @Test func boostGoesPastWhite() {
        let boosted = GammaTable.apply(PictureAdjustment(boost: 1.5), to: base)
        #expect(boosted.red[255] == 1.5)
        let dimmedBoost = GammaTable.apply(PictureAdjustment(brightness: 0.5, boost: 1.5), to: base)
        #expect(dimmedBoost.red[255] == 0.75)
        #expect(GammaTable.apply(PictureAdjustment(boost: 0.2), to: base) == base)
    }

    @Test func aTableWrittenBySomeoneElseIsNoticed() {
        let mine = GammaTable.apply(PictureAdjustment(brightness: 0.5), to: base)
        #expect(GammaTable.matches(mine, mine))
        #expect(!GammaTable.matches(mine, base))
        var nudged = mine
        nudged.red[10] += 0.002
        #expect(GammaTable.matches(mine, nudged))
        #expect(!GammaTable.matches(mine, .init(red: [], green: [], blue: [])))
    }

    @Test func resetKeepsDimmingAndBoost() {
        let adjusted = PictureAdjustment(brightness: 0.4, contrast: 0.3, gamma: 1.2, redGain: 0.9, temperature: 5000, invert: true, boost: 1.3)
        #expect(adjusted.withoutPictureChanges == PictureAdjustment(brightness: 0.4, boost: 1.3))
    }
}

/// An EDID made up for the tests: no real display's serial is in here.
private func sampleEDID(extensionBlock: Bool = false) -> Data {
    var bytes = [UInt8](repeating: 0, count: 128)
    bytes.replaceSubrange(0..<8, with: [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0])
    // "TST": T=20, S=19, T=20 → 0b0_10100_10011_10100.
    bytes[8] = 0x52; bytes[9] = 0x74
    bytes[10] = 0x34; bytes[11] = 0x12
    bytes[12] = 0x78; bytes[13] = 0x56; bytes[14] = 0x34; bytes[15] = 0x12
    bytes[16] = 33; bytes[17] = 34 // week 33 of 2024
    bytes[18] = 1; bytes[19] = 4
    bytes[21] = 60; bytes[22] = 34
    // Preferred timing 3840 × 2160.
    bytes[54] = 0x4D; bytes[55] = 0xD0
    bytes[56] = 0x00; bytes[58] = 0xF0 // 0xF00 = 3840
    bytes[59] = 0x70; bytes[61] = 0x80 // 0x870 = 2160
    func descriptor(_ type: UInt8, _ text: String, at offset: Int) {
        bytes[offset + 3] = type
        var padded = Array(text.utf8) + [0x0A]
        while padded.count < 13 { padded.append(0x20) }
        bytes.replaceSubrange(offset + 5..<offset + 18, with: padded.prefix(13))
    }
    descriptor(0xFC, "Test Monitor", at: 72)
    descriptor(0xFF, "SERIAL0001", at: 90)
    bytes[126] = extensionBlock ? 1 : 0
    bytes[127] = 0 &- bytes[0..<127].reduce(0, &+)
    guard extensionBlock else { return Data(bytes) }
    var cta = [UInt8](repeating: 0, count: 128)
    cta[0] = 0x02; cta[1] = 0x03; cta[2] = 12
    cta[4] = 0x23; cta[5] = 0x09; cta[6] = 0x07; cta[7] = 0x07       // an audio block, to be skipped
    cta[8] = 0xE6; cta[9] = 0x06; cta[10] = 0x0D; cta[11] = 0x01    // HDR static metadata: SDR, PQ, HLG
    cta[12] = 138; cta[13] = 90; cta[14] = 20                      // max 50·2^(138/32) ≈ 993 nits
    cta[127] = 0 &- cta[0..<127].reduce(0, &+)
    return Data(bytes + cta)
}

@Suite struct EDIDTests {
    @Test func baseBlock() throws {
        let edid = try #require(EDID(sampleEDID()))
        #expect(edid.manufacturer == "TST")
        #expect(edid.productCode == 0x1234)
        #expect(edid.serialNumber == 0x12345678)
        #expect(edid.week == 33 && edid.year == 2024)
        #expect(edid.version == "1.4")
        #expect(edid.name == "Test Monitor")
        #expect(edid.serialText == "SERIAL0001")
        #expect(edid.nativeWidth == 3840 && edid.nativeHeight == 2160)
        let diagonal = try #require(edid.diagonalInches)
        #expect(abs(diagonal - 27.15) < 0.1)
        #expect(!edid.supportsHDR10 && edid.maxLuminance == nil)
    }

    @Test func hdrDataFromTheExtension() throws {
        let edid = try #require(EDID(sampleEDID(extensionBlock: true)))
        #expect(edid.extensionCount == 1)
        #expect(edid.supportsHDR10 && edid.supportsHLG)
        let peak = try #require(edid.maxLuminance)
        #expect(abs(peak - 993) < 2)
    }

    @Test func whatIsNotAnEDIDIsRefused() {
        #expect(EDID(Data()) == nil)
        #expect(EDID(Data(repeating: 0, count: 128)) == nil)
        var corrupt = [UInt8](sampleEDID())
        corrupt[40] ^= 1
        #expect(EDID(Data(corrupt)) == nil)
    }
}

@Suite struct DisplayStoreTests {
    private func store() throws -> DisplayStore {
        DisplayStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
    }

    @Test func profilesAreKeptByKey() throws {
        let store = try store()
        var profile = DisplayProfile(name: "Desk", brightnessMethod: .ddc, brightness: 0.4)
        profile.picture.contrast = 0.2
        profile.favoriteModes = [DisplayResolution(width: 1800, height: 1169, isHiDPI: true)]
        profile.inputNames = [17: "PlayStation"]
        profile.ddcValues = [0x10: 40]
        try store.save(profile, key: "10ac-a0f1-00001234", in: .profile)
        try store.save(DisplayProfile(), key: "other", in: .profile)
        let loaded = try store.load(DisplayProfile.self, from: .profile)
        #expect(loaded["10ac-a0f1-00001234"] == profile)
        #expect(loaded.count == 2)
        profile.name = nil
        try store.save(profile, key: "10ac-a0f1-00001234", in: .profile)
        #expect(try store.load(DisplayProfile.self, from: .profile)["10ac-a0f1-00001234"]?.name == nil)
        try store.delete(key: "other", from: .profile)
        #expect(try store.load(DisplayProfile.self, from: .profile).count == 1)
    }

    /// A profile saved before a setting existed reads with that setting's default.
    @Test func olderProfilesTakeDefaultsForNewFields() throws {
        let store = try store()
        try store.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO display_profile (key, json) VALUES ('old', '{\"brightnessMethod\":\"gamma\"}')")
            try db.execute(sql: "INSERT INTO display_profile (key, json) VALUES ('broken', 'not json')")
        }
        let loaded = try store.load(DisplayProfile.self, from: .profile)
        #expect(loaded["old"]?.brightnessMethod == .gamma)
        #expect(loaded["old"]?.xdrMaxNits == 1200)
        #expect(loaded["old"]?.panelControls == DisplayPanelControl.defaults)
        #expect(loaded["broken"] == nil)
    }

    @Test func theJournalKeepsWhatOutlivesTheApp() throws {
        let store = try store()
        let first = try store.record(DisplayJournalEntry(kind: .disconnected, display: "a", detail: "4"))
        try store.record(DisplayJournalEntry(kind: .overrideFile, display: "b", detail: "/Library/Displays/x", backup: Data([1, 2, 3])))
        #expect(try store.journal().count == 2)
        let disconnected = try store.journal(.disconnected)
        #expect(disconnected.map(\.detail) == ["4"])
        #expect(try store.journal(.overrideFile).first?.backup == Data([1, 2, 3]))
        try store.clearJournal(id: first)
        #expect(try store.journal(.disconnected).isEmpty)
        #expect(try store.journal().count == 1)
    }
}
