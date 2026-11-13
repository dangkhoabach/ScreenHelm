import Foundation

/// What a display says about itself in its EDID: the 128-byte base block
/// and, when present, the HDR data of a CTA-861 extension.
public struct EDID: Equatable, Sendable {
    /// Three letters, the PNP ID ("APP", "DEL", "GSM").
    public var manufacturer: String
    public var productCode: UInt16
    public var serialNumber: UInt32
    public var week: Int
    public var year: Int
    public var version: String
    /// Centimetres; zero for a projector or an unknown size.
    public var widthCentimeters: Int
    public var heightCentimeters: Int
    public var name: String?
    public var serialText: String?
    /// The preferred timing: the panel's own pixels.
    public var nativeWidth: Int?
    public var nativeHeight: Int?
    public var extensionCount: Int
    public var supportsHDR10: Bool
    public var supportsHLG: Bool
    /// The brightest the display says it gets, in nits.
    public var maxLuminance: Double?

    /// Nil when the bytes aren't an EDID: too short, wrong header, or a
    /// base block whose checksum doesn't add up.
    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 128, Array(bytes[0..<8]) == [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0],
              bytes[0..<128].reduce(0, &+) == 0 else { return nil }

        let id = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        manufacturer = String([10, 5, 0].map { shift in
            Character(UnicodeScalar(UInt8(64 + ((id >> UInt16(shift)) & 0x1F))))
        })
        productCode = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
        serialNumber = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        week = Int(bytes[16])
        year = 1990 + Int(bytes[17])
        version = "\(bytes[18]).\(bytes[19])"
        widthCentimeters = Int(bytes[21])
        heightCentimeters = Int(bytes[22])
        extensionCount = Int(bytes[126])

        for offset in stride(from: 54, through: 108, by: 18) {
            let block = Array(bytes[offset..<offset + 18])
            if block[0] == 0 && block[1] == 0 {
                let text = String(decoding: block[5..<18].prefix { $0 != 0x0A }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if block[3] == 0xFC { name = text }
                if block[3] == 0xFF { serialText = text }
            } else if nativeWidth == nil {
                nativeWidth = Int(block[2]) | Int(block[4] & 0xF0) << 4
                nativeHeight = Int(block[5]) | Int(block[7] & 0xF0) << 4
            }
        }

        supportsHDR10 = false
        supportsHLG = false
        var block = 128
        while block + 128 <= bytes.count {
            defer { block += 128 }
            guard bytes[block] == 0x02 else { continue } // CTA-861
            let end = block + min(127, max(4, Int(bytes[block + 2])))
            var index = block + 4
            while index < end {
                let length = Int(bytes[index] & 0x1F)
                defer { index += length + 1 }
                // Extended tag 6: HDR static metadata.
                guard bytes[index] >> 5 == 7, length >= 2, index + length < bytes.count, bytes[index + 1] == 6 else { continue }
                supportsHDR10 = bytes[index + 2] & 0b100 != 0
                supportsHLG = bytes[index + 2] & 0b1000 != 0
                if length >= 4, bytes[index + 4] != 0 {
                    maxLuminance = 50 * pow(2, Double(bytes[index + 4]) / 32)
                }
            }
        }
    }

    /// Inches across the diagonal, from the size in centimetres.
    public var diagonalInches: Double? {
        guard widthCentimeters > 0, heightCentimeters > 0 else { return nil }
        return (Double(widthCentimeters * widthCentimeters + heightCentimeters * heightCentimeters)).squareRoot() / 2.54
    }
}
