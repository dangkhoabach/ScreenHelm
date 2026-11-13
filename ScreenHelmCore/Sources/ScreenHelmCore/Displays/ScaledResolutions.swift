import Foundation

/// Extra sharp resolutions for a real display, through the file macOS
/// reads its own scaled resolutions from: a property list per display
/// model under /Library/Displays. Each entry is the size in pixels the
/// desktop is drawn at; macOS offers it as a HiDPI mode of half that in
/// points, scaled to the panel. This is the form Apple's own files use.
public enum ScaledResolutions {
    public struct Size: Equatable, Hashable, Sendable, Comparable {
        /// In points: what the mode is listed as.
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public static func < (a: Size, b: Size) -> Bool { a.width < b.width }
    }

    /// The drawing size, twice the points, as two big-endian 32-bit numbers.
    public static func entry(for size: Size) -> Data {
        var data = Data()
        for value in [UInt32(size.width * 2), UInt32(size.height * 2)] {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// The size an entry stands for. Entries with a third number, flags,
    /// are read the same way; nil for anything shorter than two numbers.
    public static func size(of entry: Data) -> Size? {
        guard entry.count >= 8 else { return nil }
        let bytes = [UInt8](entry)
        func word(_ offset: Int) -> Int { bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        let width = word(0), height = word(4)
        guard width > 0, height > 0 else { return nil }
        return Size(width: width / 2, height: height / 2)
    }

    /// The widest desktop, in pixels, the Mac's display pipeline draws: a
    /// limit of the chip, not of the monitor.
    public static func maximumBackingWidth(chip: String) -> Int {
        let bigger = chip.contains("Pro") || chip.contains("Max") || chip.contains("Ultra")
        // The M4 and M5 generations have a tighter budget per display.
        if chip.contains("M4") || chip.contains("M5") { return bigger ? 6720 : 6144 }
        return bigger ? 7680 : 6144
    }

    /// A close-set run of sizes in the panel's own shape, for a slider
    /// that moves smoothly between "larger text" and "more space": from a
    /// third of the panel's width up to the panel itself, or to what the
    /// chip can draw if that is less. Sizes are even and none repeats.
    public static func generate(panelWidth: Int, panelHeight: Int, maximumBackingWidth: Int, steps: Int = 24) -> [Size] {
        guard panelWidth > 0, panelHeight > 0, steps > 1 else { return [] }
        let widest = min(panelWidth, maximumBackingWidth / 2)
        let narrowest = max(640, panelWidth / 3)
        guard widest > narrowest else { return [] }
        var sizes: [Size] = []
        for step in 0..<steps {
            let width = Int((Double(narrowest) + Double(widest - narrowest) * Double(step) / Double(steps - 1)) / 2) * 2
            let height = Int((Double(width) * Double(panelHeight) / Double(panelWidth) / 2).rounded()) * 2
            let size = Size(width: width, height: height)
            if sizes.last != size { sizes.append(size) }
        }
        return sizes
    }

    /// "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/DisplayProductID-a04f":
    /// the folder and the file are named by the IDs in lowercase hex.
    public static func path(vendor: UInt32, product: UInt32, root: String = "/Library/Displays/Contents/Resources/Overrides") -> String {
        "\(root)/DisplayVendorID-\(String(vendor, radix: 16))/DisplayProductID-\(String(product, radix: 16))"
    }

    /// The file's contents: what was there before (Apple's own file for
    /// the model, or one already installed), with these sizes added to
    /// its scaled resolutions. Nothing already listed is taken out.
    public static func propertyList(base: Data?, vendor: UInt32, product: UInt32, name: String, adding sizes: [Size]) throws -> Data {
        var dictionary = (base.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]) ?? [:]
        dictionary["DisplayVendorID"] = Int(vendor)
        dictionary["DisplayProductID"] = Int(product)
        if dictionary["DisplayProductName"] == nil { dictionary["DisplayProductName"] = name }
        var entries = (dictionary["scale-resolutions"] as? [Data]) ?? []
        let listed = Set(entries.compactMap(size(of:)))
        for size in sizes where !listed.contains(size) { entries.append(entry(for: size)) }
        dictionary["scale-resolutions"] = entries
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// The sizes a file lists.
    public static func sizes(in propertyList: Data) -> [Size] {
        let dictionary = (try? PropertyListSerialization.propertyList(from: propertyList, format: nil)) as? [String: Any]
        return ((dictionary?["scale-resolutions"] as? [Data]) ?? []).compactMap(size(of:))
    }

    /// The command that puts a prepared file in place, run with
    /// administrator rights. Paths are built from hex IDs and a temporary
    /// file of ScreenHelm's, and are quoted all the same.
    public static func installCommand(from source: String, to destination: String) -> String {
        let folder = (destination as NSString).deletingLastPathComponent
        return "/bin/mkdir -p \(quoted(folder)) && /bin/cp \(quoted(source)) \(quoted(destination)) && /bin/chmod 644 \(quoted(destination))"
    }

    public static func removeCommand(_ destination: String) -> String {
        "/bin/rm -f \(quoted(destination))"
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension DisplayModes {
    /// The size at which things look as big on this display as on a
    /// reference one: the same points to the millimetre, as near as the
    /// display's modes come. `pointsPerMillimeter` is the reference's;
    /// `widthMillimeters` is this display's physical width.
    public static func resolution(matching pointsPerMillimeter: Double, widthMillimeters: Double, like current: DisplayModeInfo,
                                  in modes: [DisplayModeInfo]) -> DisplayResolution? {
        guard pointsPerMillimeter > 0, widthMillimeters > 0 else { return nil }
        let wanted = pointsPerMillimeter * widthMillimeters
        return sliderResolutions(like: current, in: modes).min { abs(Double($0.width) - wanted) < abs(Double($1.width) - wanted) }
    }
}
