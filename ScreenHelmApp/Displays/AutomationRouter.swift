import AppKit
import ScreenHelmCore
import os

/// What a display command answers with.
struct AutomationReply: Equatable {
    var ok: Bool
    var text: String

    static func done(_ text: String = "ok") -> AutomationReply { AutomationReply(ok: true, text: text) }
    static func failed(_ text: String) -> AutomationReply { AutomationReply(ok: false, text: text) }
}

/// Carries out a `DisplayCommand`, wherever it came from, by calling the
/// same controllers the interface does. Changes that can leave a display
/// unusable still wait to be kept, as they do when made by hand.
@MainActor
enum AutomationRouter {
    private static let log = Logger(subsystem: "com.dangkhoabach.screenhelm", category: "displays")
    private static var settings: AppSettings { SettingsViewModel.shared.settings }

    static func run(_ command: DisplayCommand) -> AutomationReply {
        let displays = targets(of: command.target)
        log.info("command \(command.verb.rawValue, privacy: .public) for \(displays.count) displays")
        switch command.verb {
        case .get:
            return .done(report(command.target == .pointer ? DisplayManager.shared.displays : displays))
        case .set:
            for (name, value) in command.values {
                if let problem = set(name, to: value, on: displays) { return .failed(problem) }
            }
        case .toggle:
            for name in command.names {
                if let problem = toggle(name, on: displays) { return .failed(problem) }
            }
        case .perform:
            for name in command.names {
                if let problem = perform(name, on: displays) { return .failed(problem) }
            }
        }
        return .done()
    }

    /// Reads a command and carries it out; a command that can't be read answers with why.
    static func run(arguments: [String]) -> AutomationReply {
        do { return run(try DisplayCommand(arguments: arguments)) } catch { return .failed(describe(error)) }
    }

    static func run(url: URL) -> AutomationReply {
        do { return run(try DisplayCommand(url: url)) } catch { return .failed(describe(error)) }
    }

    static func describe(_ error: DisplayCommand.ParseError) -> String {
        switch error {
        case .noVerb: "usage: display get|set|toggle|perform [display=…] [name=value…]"
        case .unknownVerb(let verb): "unknown command \"\(verb)\": use get, set, toggle or perform"
        case .unknownSetting(let name): "unknown setting \"\(name)\""
        case .wrongForm(let name): "\"\(name)\" is in the wrong form: set takes name=value, toggle and perform take names"
        case .nothingToDo: "nothing to do: name a setting"
        }
    }

    // MARK: - Targets

    static func targets(of target: DisplayCommand.Target) -> [DisplayInfo] {
        let manager = DisplayManager.shared
        switch target {
        case .main: return manager.displays.filter(\.isMain)
        case .pointer: return manager.displayUnderPointer().map { [$0] } ?? []
        case .builtIn: return manager.displays.filter { $0.kind == .builtIn }
        case .all: return manager.displays
        case .name(let name):
            return manager.displays.filter { manager.name(of: $0).localizedCaseInsensitiveCompare(name) == .orderedSame
                || $0.systemName.localizedCaseInsensitiveCompare(name) == .orderedSame }
        case .key(let key): return manager.displays.filter { $0.key == key }
        case .group(let name):
            guard let group = settings.displayGroups.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return [] }
            return manager.displays.filter { group.displays.contains($0.key) }
        }
    }

    // MARK: - Get

    private static func report(_ displays: [DisplayInfo]) -> String {
        let manager = DisplayManager.shared
        let list: [[String: Any]] = displays.map { display in
            var entry: [String: Any] = [
                "name": manager.name(of: display), "key": display.key, "kind": display.kind.rawValue, "main": display.isMain,
                "rotation": display.rotation, "brightness": (BrightnessController.shared.value(for: display) * 1000).rounded() / 1000,
                "brightnessMethod": BrightnessController.shared.method(for: display).rawValue,
            ]
            if let mode = ModeController.shared.current(of: display.id) {
                entry["resolution"] = "\(mode.width)x\(mode.height)"
                entry["hidpi"] = mode.isHiDPI
                entry["refresh"] = mode.roundedRate
            }
            if let nits = BrightnessController.shared.nits(for: display) { entry["nits"] = Int(nits.rounded()) }
            if let master = display.mirrorOf.flatMap(manager.display) { entry["mirrors"] = manager.name(of: master) }
            if DisplayPrivateAPIs.hasHDRModes(display.id) { entry["hdr"] = DisplayPrivateAPIs.prefersHDR(display.id) ?? false }
            if XDRController.shared.isAvailable(for: display) { entry["xdr"] = XDRController.shared.isEnabled(for: display) }
            return entry
        }
        var result: [String: Any] = ["displays": list]
        let off = ConnectionController.shared.disconnected.map(\.name)
        if !off.isEmpty { result["switchedOff"] = off }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Set

    private static func set(_ name: String, to value: String, on displays: [DisplayInfo]) -> String? {
        // The system-wide switches need no display.
        switch name {
        case "nightshift":
            guard let on = DisplayCommand.flag(value) else { return "nightshift takes on or off" }
            SystemToggles.setNightShift(on)
            return nil
        case "truetone":
            guard let on = DisplayCommand.flag(value) else { return "truetone takes on or off" }
            SystemToggles.setTrueTone(on)
            return nil
        case "darkmode":
            guard let on = DisplayCommand.flag(value) else { return "darkmode takes on or off" }
            SystemToggles.setDarkMode(on)
            return nil
        case "connected" where DisplayCommand.flag(value) == true:
            ConnectionController.shared.reconnectAll()
            return nil
        default: break
        }
        guard !displays.isEmpty else { return "no display matches" }
        for display in displays {
            if let problem = set(name, to: value, on: display) { return problem }
        }
        return nil
    }

    private static func set(_ name: String, to value: String, on display: DisplayInfo) -> String? {
        let modes = ModeController.shared, ddc = DDCController.shared
        switch name {
        case "brightness":
            guard let fraction = DisplayCommand.fraction(value) else { return "brightness takes 0 to 1, or a percentage" }
            BrightnessController.shared.set(fraction, for: display)
        case "volume", "contrast":
            guard let fraction = DisplayCommand.fraction(value), fraction <= 1 else { return "\(name) takes 0 to 1, or a percentage" }
            guard ddc.isAvailable(display) else { return "\(DisplayManager.shared.name(of: display)) has no DDC connection" }
            ddc.setFraction(fraction, for: name == "volume" ? .volume : .contrast, on: display)
        case "mute":
            guard let on = DisplayCommand.flag(value) else { return "mute takes on or off" }
            guard ddc.isAvailable(display) else { return "\(DisplayManager.shared.name(of: display)) has no DDC connection" }
            ddc.set(on ? DDCPacket.muteOn : DDCPacket.muteOff, for: .mute, on: display)
        case "resolution":
            guard let size = DisplayCommand.size(value) else { return "resolution takes a size such as 1920x1080" }
            let all = modes.modes(of: display.id)
            let sharp = modes.current(of: display.id)?.isHiDPI ?? true
            let wanted = [sharp, !sharp].map { DisplayResolution(width: size.width, height: size.height, isHiDPI: $0) }
            guard let resolution = wanted.first(where: { resolution in all.contains { $0.resolution == resolution } })
            else { return "\(DisplayManager.shared.name(of: display)) has no \(value) mode" }
            modes.setResolution(resolution, on: display)
        case "refresh":
            guard let rate = Int(value) else { return "refresh takes a number such as 60" }
            modes.setRefreshRate(rate, on: display)
        case "hidpi":
            guard let on = DisplayCommand.flag(value) else { return "hidpi takes on or off" }
            if modes.current(of: display.id)?.isHiDPI != on { modes.toggleHiDPI(on: display) }
        case "notch":
            guard let on = DisplayCommand.flag(value) else { return "notch takes on or off" }
            if let shows = modes.showsNotch(display), shows != on { modes.toggleNotch(on: display) }
        case "rotation":
            guard let degrees = Int(value), [0, 90, 180, 270].contains(degrees) else { return "rotation takes 0, 90, 180 or 270" }
            guard display.kind != .builtIn || settings.displaysAdvanced else { return "rotating the built-in display is a risky setting, off in ScreenHelm" }
            ConfigurationController.setRotation(degrees, on: display)
        case "hdr":
            guard let on = DisplayCommand.flag(value) else { return "hdr takes on or off" }
            ConfigurationController.setHDR(on, on: display)
        case "xdr":
            guard let on = DisplayCommand.flag(value) else { return "xdr takes on or off" }
            guard XDRController.shared.isAvailable(for: display) else { return "\(DisplayManager.shared.name(of: display)) is not an XDR display" }
            XDRController.shared.setEnabled(on, for: display)
            if !on, BrightnessController.shared.value(for: display) > 1 { BrightnessController.shared.set(1, for: display) }
        case "invert":
            guard let on = DisplayCommand.flag(value) else { return "invert takes on or off" }
            var picture = DisplayManager.shared.profile(for: display).picture
            picture.invert = on
            BrightnessController.shared.setPicture(picture, for: display)
        case "preset":
            let presets = DisplayPrivateAPIs.presets(of: display.id).all
            guard let preset = presets.first(where: { $0.name.localizedCaseInsensitiveContains(value) }) ?? Int(value).flatMap({ index in presets.first { $0.id == index } })
            else { return "no preset matches \"\(value)\"" }
            ConfigurationController.setPreset(preset.id, on: display)
        case "input":
            guard ddc.isAvailable(display) else { return "\(DisplayManager.shared.name(of: display)) has no DDC connection" }
            let names = DisplayManager.shared.profile(for: display).inputNames
            let named = DDCInput.common.first { (names[$0.value] ?? $0.standardName).localizedCaseInsensitiveCompare(value) == .orderedSame }
            guard let input = named ?? UInt16(value).map(DDCInput.init) else { return "no input matches \"\(value)\"" }
            ddc.setInput(input, on: display)
        case "mirror":
            if DisplayCommand.flag(value) == false {
                ConfigurationController.setMirror(of: display, to: nil)
            } else {
                guard let master = targets(of: .name(value)).first, master.id != display.id else { return "no display to mirror matches \"\(value)\"" }
                ConfigurationController.setMirror(of: display, to: master)
            }
        case "connected":
            // Switching on was handled before any display was looked for.
            guard DisplayCommand.flag(value) == false else { return "connected takes on or off" }
            if ConnectionController.shared.refusal(for: display) != nil { return "\(DisplayManager.shared.name(of: display)) can't be switched off" }
            ConnectionController.shared.disconnect(display)
        case "vcp":
            guard let pair = DisplayCommand.vcp(value) else { return "vcp takes code=value, such as 0x10=50" }
            guard settings.displaysAdvanced || DDCPacket.mayWrite(pair.code, allowingAnyCode: false)
            else { return "writing any VCP code is a risky setting, off in ScreenHelm" }
            guard ddc.isAvailable(display) else { return "\(DisplayManager.shared.name(of: display)) has no DDC connection" }
            let id = display.id
            Task { await DDCService.shared.write(pair.code, value: pair.value, to: id, allowingAnyCode: true) }
        default:
            return "unknown setting \"\(name)\""
        }
        return nil
    }

    // MARK: - Toggle and perform

    private static func toggle(_ name: String, on displays: [DisplayInfo]) -> String? {
        switch name {
        case "nightshift": return set(name, to: SystemToggles.nightShift == true ? "off" : "on", on: displays)
        case "truetone": return set(name, to: SystemToggles.trueTone == true ? "off" : "on", on: displays)
        case "darkmode": return set(name, to: SystemToggles.darkMode ? "off" : "on", on: displays)
        default: break
        }
        guard !displays.isEmpty else { return "no display matches" }
        for display in displays {
            let on: Bool
            switch name {
            case "mute": on = DDCController.shared.value(.mute, on: display) == DDCPacket.muteOn
            case "hidpi": on = ModeController.shared.current(of: display.id)?.isHiDPI ?? false
            case "hdr": on = DisplayPrivateAPIs.prefersHDR(display.id) ?? false
            case "xdr": on = XDRController.shared.isEnabled(for: display)
            case "invert": on = DisplayManager.shared.profile(for: display).picture.invert
            case "notch": on = ModeController.shared.showsNotch(display) ?? false
            case "connected": on = true // A display that is listed is on.
            case "pip":
                DisplayShortcuts.perform(.pictureInPicture, on: display)
                continue
            default: return "unknown setting \"\(name)\""
            }
            if let problem = set(name, to: on ? "off" : "on", on: display) { return problem }
        }
        return nil
    }

    private static func perform(_ name: String, on displays: [DisplayInfo]) -> String? {
        switch name {
        case "stoppictures": StreamController.shared.stopAll()
        case "layout": LayoutGuard.shared.applySaved()
        case "keeplayout": LayoutGuard.shared.saveCurrent()
        case "reconnectall": ConnectionController.shared.reconnectAll()
        case "panic": DisplaySafety.shared.panic()
        default:
            guard !displays.isEmpty else { return "no display matches" }
            for display in displays {
                switch name {
                case "main": ConfigurationController.setMain(display)
                case "pip": DisplayShortcuts.perform(.pictureInPicture, on: display)
                case "brightnessup": DisplayShortcuts.perform(.brightnessUp, on: display)
                case "brightnessdown": DisplayShortcuts.perform(.brightnessDown, on: display)
                case "volumeup": DisplayShortcuts.perform(.volumeUp, on: display)
                case "volumedown": DisplayShortcuts.perform(.volumeDown, on: display)
                default: return "unknown action \"\(name)\""
                }
            }
        }
        return nil
    }
}
