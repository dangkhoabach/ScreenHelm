import Foundation

/// The monitor settings ScreenHelm reads and writes over DDC/CI, by their
/// VCP code in the MCCS standard.
public enum VCPCode: UInt8, Codable, Sendable, CaseIterable {
    case brightness = 0x10
    case contrast = 0x12
    case colorPreset = 0x14
    case redGain = 0x16
    case greenGain = 0x18
    case blueGain = 0x1A
    case inputSource = 0x60
    case volume = 0x62
    case mute = 0x8D
    case power = 0xD6
    /// LG's own input switch, on monitors that ignore 0x60.
    case lgInputSource = 0xF4

    /// Mute and power take one of a few values; the rest are a range.
    public var isContinuous: Bool {
        switch self {
        case .brightness, .contrast, .redGain, .greenGain, .blueGain, .volume: true
        case .colorPreset, .inputSource, .mute, .power, .lgInputSource: false
        }
    }
}

public enum DDCError: Error, Equatable, Sendable {
    /// Fewer bytes than a reply has.
    case shortReply
    case badChecksum
    /// Not a reply to a Get VCP request.
    case unexpectedReply
    /// The monitor answered that it doesn't have this setting.
    case unsupported
    /// Asked for another code than the one answered.
    case wrongCode
}

public struct VCPValue: Equatable, Sendable {
    public var current: UInt16
    public var maximum: UInt16

    public init(current: UInt16, maximum: UInt16) {
        self.current = current
        self.maximum = maximum
    }

    /// 0…1 of the monitor's range.
    public var fraction: Double {
        maximum == 0 ? 0 : min(1, Double(current) / Double(maximum))
    }
}

/// DDC/CI messages as they go over I2C on Apple silicon: the bytes after
/// the monitor's address (0x37) and the host's (0x51).
public enum DDCPacket {
    /// The monitor's I2C address, 7-bit; 0x6E is the same shifted for writing.
    public static let chipAddress: UInt8 = 0x37
    /// The built-in HDMI port of the first Apple silicon Macs sits behind a
    /// converter that listens here instead.
    public static let converterChipAddress: UInt8 = 0xB7
    public static let hostAddress: UInt8 = 0x51
    /// A monitor's EDID lives at this address. Nothing is ever written there.
    public static let edidAddress: UInt8 = 0x50
    public static let replyLength = 11

    /// XOR of the write address, the host address and every byte sent. The
    /// same rule for reading and writing: a monitor that checks it ignores
    /// a request with any other.
    public static func checksum(_ bytes: [UInt8], hostAddress: UInt8 = DDCPacket.hostAddress) -> UInt8 {
        bytes.reduce((chipAddress << 1) ^ hostAddress, ^)
    }

    public static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    public static func getVCP(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(body)]
    }

    /// Reads a Get VCP reply: source, length, 0x02, result, code, type,
    /// maximum (2 bytes), current (2 bytes), checksum.
    public static func parseReply(_ reply: [UInt8], for code: UInt8, ignoringChecksum: Bool = false) -> Result<VCPValue, DDCError> {
        guard reply.count >= replyLength else { return .failure(.shortReply) }
        // The reply is checked from the host's side of the bus: 0x50.
        let expected = reply[0..<10].reduce(UInt8(0x50), ^)
        guard ignoringChecksum || expected == reply[10] else { return .failure(.badChecksum) }
        guard reply[2] == 0x02 else { return .failure(.unexpectedReply) }
        guard reply[3] == 0 else { return .failure(.unsupported) }
        guard reply[4] == code else { return .failure(.wrongCode) }
        return .success(VCPValue(current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
                                 maximum: UInt16(reply[6]) << 8 | UInt16(reply[7])))
    }

    /// A monitor's range turned to the value to send; mute is 1 for on, 2 for off.
    public static func value(for fraction: Double, maximum: UInt16) -> UInt16 {
        UInt16((min(1, max(0, fraction)) * Double(maximum)).rounded())
    }

    public static let muteOn: UInt16 = 1
    public static let muteOff: UInt16 = 2
    public static let powerOn: UInt16 = 1
    public static let powerStandby: UInt16 = 4
    public static let powerOff: UInt16 = 5

    /// Whether writing `code` is allowed: the settings in `VCPCode` always,
    /// anything else only with the user's own DDC controls turned on.
    public static func mayWrite(_ code: UInt8, allowingAnyCode: Bool) -> Bool {
        allowingAnyCode || VCPCode(rawValue: code) != nil
    }
}

/// A monitor input as DDC numbers it (VCP 0x60).
public struct DDCInput: Codable, Hashable, Sendable, Identifiable {
    public var value: UInt16
    public var id: UInt16 { value }

    public init(value: UInt16) {
        self.value = value
    }

    /// The MCCS name for the common values; monitors do stray from it,
    /// which is why the user can rename an input.
    public var standardName: String {
        switch value {
        case 1: "VGA 1"
        case 2: "VGA 2"
        case 3: "DVI 1"
        case 4: "DVI 2"
        case 15: "DisplayPort 1"
        case 16: "DisplayPort 2"
        case 17: "HDMI 1"
        case 18: "HDMI 2"
        case 19: "HDMI 3"
        case 20: "HDMI 4"
        case 27: "USB-C"
        case 28: "USB-C 2"
        default: "Input \(value)"
        }
    }

    /// Offered when a monitor doesn't say which inputs it has.
    public static let common: [DDCInput] = [15, 16, 17, 18, 27].map(DDCInput.init)
}

/// What a monitor says it supports, read from its capabilities string:
/// `(prot(monitor)type(lcd)model(X)vcp(10 12 60(0F 11 12) 62)mccs_ver(2.1))`.
public struct DDCCapabilities: Equatable, Sendable {
    public var model: String?
    public var mccsVersion: String?
    /// Each supported code, with the values it takes when it lists them.
    public var codes: [UInt8: [UInt16]]

    public init(model: String? = nil, mccsVersion: String? = nil, codes: [UInt8: [UInt16]] = [:]) {
        self.model = model
        self.mccsVersion = mccsVersion
        self.codes = codes
    }

    public var inputs: [DDCInput] {
        (codes[VCPCode.inputSource.rawValue] ?? []).map(DDCInput.init)
    }

    public func supports(_ code: VCPCode) -> Bool {
        codes[code.rawValue] != nil
    }

    public init?(parsing text: String) {
        guard let root = Self.group(named: nil, in: Substring(text)) else { return nil }
        model = Self.group(named: "model", in: root).map(String.init)
        mccsVersion = Self.group(named: "mccs_ver", in: root).map(String.init)
        guard let vcp = Self.group(named: "vcp", in: root) else { return nil }
        codes = [:]
        var index = vcp.startIndex
        var last: UInt8?
        while index < vcp.endIndex {
            let character = vcp[index]
            if character == "(" {
                guard let close = Self.matchingParenthesis(in: vcp, from: index) else { return nil }
                if let last {
                    codes[last] = vcp[vcp.index(after: index)..<close].split(separator: " ").compactMap { UInt16($0, radix: 16) }
                }
                index = vcp.index(after: close)
            } else if character.isHexDigit {
                let end = vcp[index...].firstIndex { !$0.isHexDigit } ?? vcp.endIndex
                if let code = UInt8(vcp[index..<end], radix: 16) {
                    codes[code] = []
                    last = code
                }
                index = end
            } else {
                index = vcp.index(after: index)
            }
        }
    }

    /// The text inside `name(...)`, or inside the outermost parentheses for nil.
    private static func group(named name: String?, in text: Substring) -> Substring? {
        let open: Substring.Index
        if let name {
            guard let range = text.range(of: name + "(") else { return nil }
            open = text.index(before: range.upperBound)
        } else {
            guard let first = text.firstIndex(of: "(") else { return nil }
            open = first
        }
        guard let close = matchingParenthesis(in: text, from: open) else { return nil }
        return text[text.index(after: open)..<close]
    }

    private static func matchingParenthesis(in text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
