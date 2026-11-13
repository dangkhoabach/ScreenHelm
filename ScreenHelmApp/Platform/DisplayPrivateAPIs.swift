import AppKit
import ScreenHelmCore
import IOKit

/// Every undocumented call ScreenHelm makes, in one place.
///
/// Each one is looked up at run time rather than linked: if a later macOS
/// removes or renames it, the feature that needs it reports itself
/// unavailable instead of the app failing to start. They are the calls
/// display utilities such as MonitorControl, Lunar and displayplacer rely on.
enum DisplayPrivateAPIs {
    nonisolated(unsafe) private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    nonisolated(unsafe) private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    nonisolated(unsafe) private static let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
    /// Loaded for their Objective-C classes, which are then found by name.
    nonisolated(unsafe) private static let monitorPanel = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
    nonisolated(unsafe) private static let coreBrightness = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        let pointer = handle.flatMap { dlsym($0, name) } ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
        return pointer.map { unsafeBitCast($0, to: type) }
    }

    /// Calls an Objective-C method whose arguments or result aren't objects,
    /// which `perform(_:)` can't.
    private static func method<T>(_ object: NSObject, _ selector: String, as type: T.Type) -> (T, Selector)? {
        let selector = NSSelectorFromString(selector)
        guard object.responds(to: selector) else { return nil }
        return (unsafeBitCast(object.method(for: selector), to: type), selector)
    }

    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias VoidBoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias IntGetter = @convention(c) (AnyObject, Selector) -> Int32
    private typealias VoidIntSetter = @convention(c) (AnyObject, Selector, Int32) -> Void
    private typealias ObjectSetter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

    private static func bool(_ object: NSObject, _ selector: String) -> Bool? {
        method(object, selector, as: BoolGetter.self).map { $0.0(object, $0.1) }
    }

    // MARK: - Modes

    private typealias ModeCount = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
    private typealias ModeDescription = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Int32
    private typealias ModeFlag = @convention(c) (CGDirectDisplayID, Int32) -> Bool
    private typealias ConfigureMode = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> Int32

    private static let numberOfModes = symbol(skyLight, "SLSGetNumberOfDisplayModes", as: ModeCount.self)
    private static let currentMode = symbol(skyLight, "SLSGetCurrentDisplayMode", as: ModeCount.self)
    private static let modeDescription = symbol(skyLight, "SLSGetDisplayModeDescriptionOfLength", as: ModeDescription.self)
    private static let modeIsVRR = symbol(skyLight, "SLSIsDisplayModeVRR", as: ModeFlag.self)
    private static let modeIsProMotion = symbol(skyLight, "SLSIsDisplayModeProMotion", as: ModeFlag.self)
    private static let configureMode = symbol(skyLight, "SLSConfigureDisplayMode", as: ConfigureMode.self)

    static var canListModes: Bool { numberOfModes != nil && currentMode != nil && modeDescription != nil && configureMode != nil }

    /// Every mode of a display as the window server knows them, including
    /// the ones System Settings leaves out. This also works for a virtual
    /// display made by this process, whose modes CoreGraphics doesn't return.
    static func modes(of display: CGDirectDisplayID) -> [DisplayModeInfo]? {
        guard let numberOfModes, let modeDescription else { return nil }
        var count: Int32 = 0
        guard numberOfModes(display, &count) == 0, count > 0 else { return nil }
        // The window server's 212-byte description of a mode.
        let length = 0xD4
        var buffer = [UInt8](repeating: 0, count: length)
        var modes: [DisplayModeInfo] = []
        for index in 0..<count {
            let read = buffer.withUnsafeMutableBytes { modeDescription(display, index, $0.baseAddress!, Int32(length)) }
            guard read == 0 else { continue }
            buffer.withUnsafeBytes { bytes in
                func int(_ offset: Int) -> Int { Int(bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self)) }
                let flags = bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                let density = bytes.loadUnaligned(fromByteOffset: 208, as: Float.self)
                let fixedRate = Double(int(188)) / 65536
                modes.append(DisplayModeInfo(
                    number: int(0), width: int(8), height: int(12), pixelWidth: int(200), pixelHeight: int(204),
                    // A display with no rate of its own (a virtual one) reports 0.
                    refreshRate: fixedRate > 0 ? fixedRate : Double(int(36)),
                    isHiDPI: density >= 1.5, isNative: flags & 0x2000000 != 0,
                    isVariableRate: modeIsVRR?(display, index) ?? false, isProMotion: modeIsProMotion?(display, index) ?? false,
                    bitsPerSample: int(28)
                ))
            }
        }
        return modes
    }

    static func currentModeNumber(of display: CGDirectDisplayID) -> Int? {
        guard let currentMode else { return nil }
        var number: Int32 = -1
        return currentMode(display, &number) == 0 && number >= 0 ? Int(number) : nil
    }

    /// Inside a display configuration that the caller begins and completes.
    static func configure(_ config: CGDisplayConfigRef?, display: CGDirectDisplayID, modeNumber: Int) -> Bool {
        configureMode.map { $0(config, display, Int32(modeNumber)) == 0 } ?? false
    }

    // MARK: - Disconnect

    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32
    private static let configureEnabled = symbol(skyLight, "SLSConfigureDisplayEnabled", as: ConfigureEnabled.self)
        ?? symbol(nil, "CGSConfigureDisplayEnabled", as: ConfigureEnabled.self)

    static var canDisconnect: Bool { configureEnabled != nil }

    /// Switches a display off without unplugging it, or back on. A display
    /// that is off is no longer listed, so the caller keeps its ID to turn
    /// it on again.
    static func configure(_ config: CGDisplayConfigRef?, display: CGDirectDisplayID, enabled: Bool) -> Bool {
        configureEnabled.map { $0(config, display, enabled) == 0 } ?? false
    }

    // MARK: - Brightness of Apple displays

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias RegisterBrightness = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias UnregisterBrightness = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    private static let getBrightness = symbol(displayServices, "DisplayServicesGetBrightness", as: GetBrightness.self)
    private static let setBrightnessCall = symbol(displayServices, "DisplayServicesSetBrightness", as: SetBrightness.self)
    private static let getLinearBrightness = symbol(displayServices, "DisplayServicesGetLinearBrightness", as: GetBrightness.self)
    private static let canChange = symbol(displayServices, "DisplayServicesCanChangeBrightness", as: CanChangeBrightness.self)
    private static let registerBrightness = symbol(displayServices, "DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterBrightness.self)
    private static let unregisterBrightness = symbol(displayServices, "DisplayServicesUnregisterForBrightnessChangeNotifications", as: UnregisterBrightness.self)

    /// A display whose backlight macOS itself controls: the built-in one
    /// and Apple's own monitors.
    static func hasAppleBrightness(_ display: CGDirectDisplayID) -> Bool {
        guard getBrightness != nil, setBrightnessCall != nil else { return false }
        return canChange?(display) ?? false
    }

    /// 0…1, the value of the slider in System Settings.
    static func brightness(of display: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? Double(value) : nil
    }

    @discardableResult
    static func setBrightness(_ value: Double, of display: CGDirectDisplayID) -> Bool {
        setBrightnessCall.map { $0(display, Float(min(1, max(0, value)))) == 0 } ?? false
    }

    /// The backlight's share of full power, which isn't the slider's value:
    /// the slider follows how bright it looks.
    static func linearBrightness(of display: CGDirectDisplayID) -> Double? {
        guard let getLinearBrightness else { return nil }
        var value: Float = 0
        return getLinearBrightness(display, &value) == 0 ? Double(value) : nil
    }

    /// Calls back on a system thread whenever the display's brightness
    /// changes, whoever changed it.
    static func observeBrightness(of display: CGDirectDisplayID, observer: UnsafeRawPointer, callback: CFNotificationCallback) -> Bool {
        registerBrightness.map { $0(display, observer, callback) == 0 } ?? false
    }

    static func stopObservingBrightness(of display: CGDirectDisplayID, observer: UnsafeRawPointer) {
        _ = unregisterBrightness?(display, observer)
    }

    /// What the built-in panel is putting out now, in nits, read from its
    /// framebuffer; nil on a Mac without one.
    static func builtInNits() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Only the built-in panel's framebuffer has brightness compensation on.
            guard (IORegistryEntryCreateCFProperty(service, "IOMFBBrightnessCompensationEnable" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) == true,
                let level = IORegistryEntryCreateCFProperty(service, "IOMFBBrightnessLevel" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int
            else { continue }
            return Double(level) / 65536 // 16.16 fixed point
        }
        return nil
    }

    // MARK: - What a display is

    private typealias CreateInfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let createInfoDictionary = symbol(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary", as: CreateInfoDictionary.self)

    /// CoreDisplay's description of a display: its name, whether it is
    /// virtual or an AirPlay screen, and where it is plugged in.
    static func info(of display: CGDirectDisplayID) -> [String: Any] {
        (createInfoDictionary?(display)?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    // MARK: - MonitorPanel: rotation, HDR, presets

    /// Making System Settings' display manager takes tens of milliseconds,
    /// so one is kept until the displays change. Used on the main thread only.
    nonisolated(unsafe) private static var panelManager: NSObject?

    /// Called when displays were added, removed or reconfigured.
    static func displaysChanged() {
        panelManager = nil
    }

    /// System Settings' own object for a display.
    private static func panelDisplay(_ display: CGDirectDisplayID) -> NSObject? {
        if panelManager == nil, monitorPanel != nil { panelManager = (NSClassFromString("MPDisplayMgr") as? NSObject.Type)?.init() }
        guard let manager = panelManager, manager.responds(to: NSSelectorFromString("displays")),
              let displays = manager.value(forKey: "displays") as? [NSObject]
        else { return nil }
        return displays.first { ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == display }
    }

    /// One of System Settings' yes-or-no facts about a display: "isTV",
    /// "isSidecarDisplay", "isAirPlayDisplay".
    static func panelFlag(_ name: String, of display: CGDirectDisplayID) -> Bool {
        panelDisplay(display).flatMap { bool($0, name) } ?? false
    }

    static func canRotate(_ display: CGDirectDisplayID) -> Bool {
        panelDisplay(display).flatMap { bool($0, "canChangeOrientation") } ?? false
    }

    /// 0, 90, 180 or 270. The change is asynchronous: `CGDisplayRotation`
    /// shows it a moment later.
    @discardableResult
    static func setRotation(_ degrees: Int, of display: CGDirectDisplayID) -> Bool {
        guard let panel = panelDisplay(display), bool(panel, "canChangeOrientation") == true,
              let (call, selector) = method(panel, "setOrientation:", as: VoidIntSetter.self) else { return false }
        call(panel, selector, Int32(degrees))
        return true
    }

    static func hasHDRModes(_ display: CGDirectDisplayID) -> Bool {
        panelDisplay(display).flatMap { bool($0, "hasHDRModes") } ?? false
    }

    static func prefersHDR(_ display: CGDirectDisplayID) -> Bool? {
        panelDisplay(display).flatMap { bool($0, "preferHDRModes") }
    }

    @discardableResult
    static func setPrefersHDR(_ on: Bool, for display: CGDirectDisplayID) -> Bool {
        guard let panel = panelDisplay(display), let (call, selector) = method(panel, "setPreferHDRModes:", as: VoidBoolSetter.self) else { return false }
        call(panel, selector, on)
        return true
    }

    struct Preset: Identifiable, Equatable {
        var id: Int
        var name: String
        /// A reference mode that holds the display at one brightness: its
        /// slider has the same lowest and highest value.
        var isFixedBrightness: Bool
    }

    /// The reference modes of an Apple XDR display that can be chosen, and the one in use.
    static func presets(of display: CGDirectDisplayID) -> (all: [Preset], active: Int?) {
        guard let panel = panelDisplay(display), bool(panel, "hasPresets") == true,
              let presets = panel.value(forKey: "presets") as? [NSObject] else { return ([], nil) }
        let valid = presets.compactMap { preset -> Preset? in
            guard bool(preset, "isValid") == true, let name = preset.value(forKey: "presetName") as? String,
                  let index = (preset.value(forKey: "presetIndex") as? NSNumber)?.intValue else { return nil }
            let settings = preset.value(forKey: "presetDictionary") as? [String: Any]
            let lowest = (settings?["PresetHostMinSliderBrightness"] as? NSNumber)?.doubleValue
            let highest = (settings?["PresetHostMaxSliderBrightness"] as? NSNumber)?.doubleValue
            return Preset(id: index, name: name, isFixedBrightness: lowest != nil && lowest == highest)
        }
        let active = ((panel.value(forKey: "activePreset") as? NSObject)?.value(forKey: "presetIndex") as? NSNumber)?.intValue
        return (valid, active)
    }

    @discardableResult
    static func setActivePreset(_ index: Int, of display: CGDirectDisplayID) -> Bool {
        guard let panel = panelDisplay(display), let presets = panel.value(forKey: "presets") as? [NSObject],
              let preset = presets.first(where: { ($0.value(forKey: "presetIndex") as? NSNumber)?.intValue == index }),
              let (call, selector) = method(panel, "setActivePreset:", as: ObjectSetter.self) else { return false }
        return call(panel, selector, preset)
    }

    // MARK: - Night Shift and True Tone

    private static func client(_ name: String) -> NSObject? {
        guard coreBrightness != nil else { return nil }
        return (NSClassFromString(name) as? NSObject.Type)?.init()
    }

    /// Nil on a Mac without Night Shift.
    static var nightShiftIsOn: Bool? {
        guard let client = client("CBBlueLightClient"),
              let (call, selector) = method(client, "getBlueLightStatus:", as: (@convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool).self)
        else { return nil }
        // The status structure is 40 bytes; its second byte is "enabled".
        var status = [UInt8](repeating: 0, count: 64)
        guard status.withUnsafeMutableBytes({ call(client, selector, $0.baseAddress!) }) else { return nil }
        return status[1] != 0
    }

    @discardableResult
    static func setNightShift(_ on: Bool) -> Bool {
        guard let client = client("CBBlueLightClient"), let (call, selector) = method(client, "setEnabled:", as: BoolSetter.self) else { return false }
        return call(client, selector, on)
    }

    /// Nil on a Mac without True Tone.
    static var trueToneIsOn: Bool? {
        guard let client = client("CBTrueToneClient"), bool(client, "supported") == true, bool(client, "available") == true else { return nil }
        return bool(client, "enabled")
    }

    @discardableResult
    static func setTrueTone(_ on: Bool) -> Bool {
        guard let client = client("CBTrueToneClient"), let (call, selector) = method(client, "setEnabled:", as: BoolSetter.self) else { return false }
        return call(client, selector, on)
    }

    // MARK: - DDC over I2C (Apple silicon)

    private typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVServiceWrite = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias AVServiceRead = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias AVServiceCopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn

    private static let avServiceCreate = symbol(nil, "IOAVServiceCreateWithService", as: AVServiceCreate.self)
    private static let avServiceWrite = symbol(nil, "IOAVServiceWriteI2C", as: AVServiceWrite.self)
    private static let avServiceRead = symbol(nil, "IOAVServiceReadI2C", as: AVServiceRead.self)
    private static let avServiceCopyEDID = symbol(nil, "IOAVServiceCopyEDID", as: AVServiceCopyEDID.self)

    static var canUseDDC: Bool { avServiceCreate != nil && avServiceWrite != nil && avServiceRead != nil }

    static func avService(for service: io_service_t) -> CFTypeRef? {
        avServiceCreate?(kCFAllocatorDefault, service)?.takeRetainedValue()
    }

    /// Writes to a chip on the display's I2C bus. The address of a
    /// display's EDID memory is refused here, whatever the caller asked for:
    /// nothing in ScreenHelm may write to it.
    static func writeI2C(_ service: CFTypeRef, chip: UInt8, address: UInt8, bytes: [UInt8]) -> Bool {
        guard let avServiceWrite, chip != DDCPacket.edidAddress, chip != DDCPacket.edidAddress << 1 else { return false }
        var bytes = bytes
        return bytes.withUnsafeMutableBytes { avServiceWrite(service, UInt32(chip), UInt32(address), $0.baseAddress!, UInt32($0.count)) } == KERN_SUCCESS
    }

    static func readI2C(_ service: CFTypeRef, chip: UInt8, address: UInt8, length: Int) -> [UInt8]? {
        guard let avServiceRead else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        let result = bytes.withUnsafeMutableBytes { avServiceRead(service, UInt32(chip), UInt32(address), $0.baseAddress!, UInt32(length)) }
        return result == KERN_SUCCESS ? bytes : nil
    }

    static func edid(from service: CFTypeRef) -> Data? {
        guard let avServiceCopyEDID else { return nil }
        var data: Unmanaged<CFData>?
        guard avServiceCopyEDID(service, &data) == KERN_SUCCESS else { return nil }
        return data?.takeRetainedValue() as Data?
    }

    // MARK: - Dithering

    /// Whether the framebuffer at a registry path dithers: mixes
    /// neighbouring colours over time to show ones the panel hasn't got,
    /// which some people see as flicker. Nil when it doesn't say.
    static func dithering(at location: String) -> Bool? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, location)
        guard !location.isEmpty, entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, "enableDither" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    /// Lasts until the display is connected again or the Mac restarts.
    @discardableResult
    static func setDithering(_ on: Bool, at location: String) -> Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, location)
        guard !location.isEmpty, entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        return IORegistryEntrySetCFProperty(entry, "enableDither" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == KERN_SUCCESS
    }

    // MARK: - Ambient light

    private typealias CopyALSClient = @convention(c) () -> Unmanaged<AnyObject>?
    private typealias CopyHIDEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias HIDEventFloat = @convention(c) (AnyObject, Int32) -> Double

    nonisolated(unsafe) private static let bezelServices = dlopen("/System/Library/PrivateFrameworks/BezelServices.framework/Versions/A/BezelServices", RTLD_LAZY)
    private static let copyALSClient = symbol(bezelServices, "ALCALSCopyALSServiceClient", as: CopyALSClient.self)
    private static let copyHIDEvent = symbol(nil, "IOHIDServiceClientCopyEvent", as: CopyHIDEvent.self)
    private static let hidEventFloat = symbol(nil, "IOHIDEventGetFloatValue", as: HIDEventFloat.self)
    nonisolated(unsafe) private static let alsClient: AnyObject? = copyALSClient?()?.takeRetainedValue()

    /// The light falling on the Mac's sensor, in lux; nil on a Mac without one.
    static func ambientLux() -> Double? {
        guard let alsClient, let copyHIDEvent, let hidEventFloat,
              let event = copyHIDEvent(alsClient, 12, 0, 0)?.takeRetainedValue() else { return nil } // 12: ambient light sensor
        return hidEventFloat(event, 12 << 16)
    }

    // MARK: - Sidecar

    private static var sidecarManager: NSObject? {
        _ = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY)
        guard let manager = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              manager.responds(to: NSSelectorFromString("sharedManager")) else { return nil }
        return manager.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
    }

    /// The iPads this Mac can use as a display, by name, and whether each is one now.
    static func sidecarDevices() -> [(name: String, connected: Bool)] {
        guard let manager = sidecarManager, let devices = manager.value(forKey: "devices") as? [NSObject] else { return [] }
        let connected = (manager.value(forKey: "connectedDevices") as? [NSObject]) ?? []
        return devices.compactMap { device in
            (device.value(forKey: "name") as? String).map { name in (name, connected.contains { $0 === device }) }
        }
    }

    static func setSidecar(_ name: String, connected: Bool) {
        guard let manager = sidecarManager, let devices = manager.value(forKey: "devices") as? [NSObject],
              let device = devices.first(where: { $0.value(forKey: "name") as? String == name }) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (AnyObject?) -> Void) -> Void
        let selector = connected ? "connectToDevice:completion:" : "disconnectFromDevice:completion:"
        guard let (call, sel) = method(manager, selector, as: Call.self) else { return }
        call(manager, sel, device) { _ in }
    }

    // MARK: - Virtual displays

    /// The vendor ScreenHelm's virtual displays report, to tell them from others.
    static let virtualVendorID: UInt32 = 0xEDC0

    static var canMakeVirtualDisplays: Bool {
        ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplayMode", "CGVirtualDisplaySettings"].allSatisfy { NSClassFromString($0) != nil }
    }

    struct VirtualMode: Equatable {
        /// In points when the display is HiDPI, in pixels otherwise.
        var width: Int
        var height: Int
        var refreshRate: Double
    }

    /// A display that exists only in software. It lasts while the object
    /// returned is kept and goes when it is released or the app ends.
    /// macOS wants a vendor that isn't zero and a serial no other virtual
    /// display has; it remembers the last mode per serial.
    static func makeVirtualDisplay(name: String, serial: UInt32, maxPixels: (width: Int, height: Int), sizeInMillimeters: CGSize,
                                   modes: [VirtualMode], hiDPI: Bool, hdr: Bool = false) -> (object: NSObject, id: CGDirectDisplayID)? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else { return nil }
        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(maxPixels.width, forKey: "maxPixelsWide")
        descriptor.setValue(maxPixels.height, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: sizeInMillimeters), forKey: "sizeInMillimeters")
        descriptor.setValue(virtualVendorID, forKey: "vendorID")
        descriptor.setValue(1, forKey: "productID")
        descriptor.setValue(serial, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        let allocate = NSSelectorFromString("alloc")
        guard let allocated = displayClass.perform(allocate)?.takeUnretainedValue() as? NSObject,
              let display = allocated.perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)?.takeUnretainedValue() as? NSObject
        else { return nil }

        typealias InitMode = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?
        typealias InitHDRMode = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double, AnyObject) -> AnyObject?
        let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let initHDRMode = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")
        guard let implementation = class_getMethodImplementation(modeClass, initMode) else { return nil }
        let makeMode = unsafeBitCast(implementation, to: InitMode.self)
        // An HDR mode names the curve its values follow; PQ is HDR10's.
        let makeHDRMode = hdr && modeClass.instancesRespond(to: initHDRMode)
            ? class_getMethodImplementation(modeClass, initHDRMode).map { unsafeBitCast($0, to: InitHDRMode.self) } : nil
        let modeObjects: [AnyObject] = modes.compactMap { mode in
            guard let allocated = modeClass.perform(allocate)?.takeUnretainedValue() else { return nil }
            if let makeHDRMode {
                return makeHDRMode(allocated, initHDRMode, UInt32(mode.width), UInt32(mode.height), mode.refreshRate, CGColorSpace.itur_2100_PQ)
            }
            return makeMode(allocated, initMode, UInt32(mode.width), UInt32(mode.height), mode.refreshRate)
        }
        let settings = settingsClass.init()
        settings.setValue(modeObjects, forKey: "modes")
        settings.setValue(hiDPI ? 1 : 0, forKey: "hiDPI")
        guard let (apply, selector) = method(display, "applySettings:", as: ObjectSetter.self), apply(display, selector, settings),
              let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else { return nil }
        return (display, id)
    }
}
