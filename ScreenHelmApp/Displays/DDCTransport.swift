import CoreGraphics
import ScreenHelmCore
import Foundation
import IOKit

/// The wire under DDC: bytes to the monitor and bytes back. The real one
/// goes over the display's I2C bus; tests use one that plays a monitor.
protocol DDCTransport: Sendable {
    func write(_ bytes: [UInt8]) -> Bool
    func read(length: Int) -> [UInt8]?
}

/// DDC over the I2C bus of an Apple silicon display port.
final class AppleSiliconDDCTransport: DDCTransport, @unchecked Sendable {
    private let service: CFTypeRef
    private let chipAddress: UInt8

    init(service: CFTypeRef, chipAddress: UInt8) {
        self.service = service
        self.chipAddress = chipAddress
    }

    func write(_ bytes: [UInt8]) -> Bool {
        DisplayPrivateAPIs.writeI2C(service, chip: chipAddress, address: DDCPacket.hostAddress, bytes: bytes)
    }

    func read(length: Int) -> [UInt8]? {
        DisplayPrivateAPIs.readI2C(service, chip: chipAddress, address: DDCPacket.hostAddress, length: length)
    }

    func edid() -> Data? {
        DisplayPrivateAPIs.edid(from: service)
    }
}

/// Finds the I2C service of each external display, the way AppleSiliconDDC
/// and m1ddc do: every framebuffer in the registry is followed by the
/// service of the port it drives.
enum DDCDiscovery {
    struct Port {
        /// Registry path of the framebuffer, which CoreDisplay also reports
        /// as the display's location.
        var location: String
        var edidUUID: String
        var productName: String
        var serial: String
        var transport: AppleSiliconDDCTransport
    }

    /// What is known about a connected display, to find its port.
    struct Candidate {
        var id: CGDirectDisplayID
        var location: String
        var vendor: UInt32
        var product: UInt32
        var name: String
        var serial: String
    }

    static func externalPorts() -> [Port] {
        guard DisplayPrivateAPIs.canUseDDC else { return [] }
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [Port] = []
        var framebuffer: (location: String, edidUUID: String, productName: String, serial: String)?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let name = Self.name(of: entry)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                let attributes = (property("DisplayAttributes", of: entry) as? [String: Any])?["ProductAttributes"] as? [String: Any]
                framebuffer = (path(of: entry), property("EDID UUID", of: entry) as? String ?? "",
                               attributes?["ProductName"] as? String ?? "", attributes?["AlphanumericSerialNumber"] as? String ?? "")
            } else if name == "DCPAVServiceProxy", let found = framebuffer {
                // One service per framebuffer; the built-in panel's says "Embedded".
                framebuffer = nil
                guard property("Location", of: entry) as? String == "External", let service = DisplayPrivateAPIs.avService(for: entry) else { continue }
                ports.append(Port(location: found.location, edidUUID: found.edidUUID, productName: found.productName, serial: found.serial,
                                  transport: AppleSiliconDDCTransport(service: service, chipAddress: chipAddress(for: entry))))
            }
        }
        return ports
    }

    /// The first Apple silicon Macs put a converter chip between the HDMI
    /// port and the display, and it answers at another address.
    private static func chipAddress(for proxy: io_registry_entry_t) -> UInt8 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else { return DDCPacket.chipAddress }
        defer { IOObjectRelease(parent) }
        return property("EPICProviderClass", of: parent) as? String == "AppleDCPMCDP29XX" ? DDCPacket.converterChipAddress : DDCPacket.chipAddress
    }

    /// Pairs displays with ports by how much they agree: the location
    /// settles it; vendor, model, name and serial break ties when the
    /// location is missing. Best pairs first, each port and display once.
    static func match(_ candidates: [Candidate], to ports: [Port]) -> [CGDirectDisplayID: Int] {
        var scored: [(score: Int, display: Int, port: Int)] = []
        for (d, candidate) in candidates.enumerated() {
            for (p, port) in ports.enumerated() {
                let score = score(candidate, port.location, port.edidUUID, port.productName, port.serial)
                if score > 0 { scored.append((score, d, p)) }
            }
        }
        var result: [CGDirectDisplayID: Int] = [:]
        var usedDisplays = Set<Int>(), usedPorts = Set<Int>()
        for pair in scored.sorted(by: { $0.score > $1.score }) where !usedDisplays.contains(pair.display) && !usedPorts.contains(pair.port) {
            result[candidates[pair.display].id] = pair.port
            usedDisplays.insert(pair.display)
            usedPorts.insert(pair.port)
        }
        return result
    }

    static func score(_ candidate: Candidate, _ location: String, _ edidUUID: String, _ productName: String, _ serial: String) -> Int {
        var score = 0
        if !location.isEmpty, location == candidate.location { score += 10 }
        // The UUID starts with the vendor, then the model with its bytes swapped.
        let uuid = edidUUID.uppercased()
        let vendor = String(format: "%04X", candidate.vendor & 0xFFFF)
        let product = String(format: "%02X%02X", candidate.product & 0xFF, (candidate.product >> 8) & 0xFF)
        if uuid.hasPrefix(vendor) { score += 1 }
        if uuid.dropFirst(4).hasPrefix(product) { score += 1 }
        if !productName.isEmpty, productName == candidate.name { score += 1 }
        if !serial.isEmpty, serial == candidate.serial { score += 1 }
        return score
    }

    private static func name(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func path(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: MemoryLayout<io_string_t>.size)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
