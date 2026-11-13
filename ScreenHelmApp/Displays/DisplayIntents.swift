import AppIntents
import ScreenHelmCore

/// Display actions for the Shortcuts app. Each builds the same command
/// the command line would and hands it to the router.
private func target(named name: String?) -> DisplayCommand.Target {
    guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return .main }
    return name.lowercased() == "all" ? .all : .name(name)
}

@MainActor
private func run(_ command: DisplayCommand) throws -> String {
    let reply = AutomationRouter.run(command)
    guard reply.ok else { throw DisplayIntentError.failed(reply.text) }
    return reply.text
}

enum DisplayIntentError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let text): "\(text)"
        }
    }
}

struct SetDisplayBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Brightness"
    static let description = IntentDescription("Sets the brightness of a display through ScreenHelm.")

    @Parameter(title: "Display", description: "A display's name, or \"all\". The main display when empty.")
    var display: String?
    @Parameter(title: "Brightness", description: "In percent.", inclusiveRange: (0, 200))
    var percent: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try run(DisplayCommand(verb: .set, target: target(named: display), values: [("brightness", "\(percent)%")]))
        return .result()
    }
}

struct SetDisplayResolutionIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Resolution"
    static let description = IntentDescription("Switches a display to a resolution it has. The change has to be kept in ScreenHelm's prompt the first time.")

    @Parameter(title: "Display") var display: String?
    @Parameter(title: "Width") var width: Int
    @Parameter(title: "Height") var height: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try run(DisplayCommand(verb: .set, target: target(named: display), values: [("resolution", "\(width)x\(height)")]))
        return .result()
    }
}

enum DisplayToggleSetting: String, AppEnum {
    case hdr, xdr, hidpi, notch, invert, mute, pip, nightshift, truetone, darkmode

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display Setting"
    static let caseDisplayRepresentations: [DisplayToggleSetting: DisplayRepresentation] = [
        .hdr: "HDR", .xdr: "XDR Brightness", .hidpi: "HiDPI", .notch: "Area Beside the Camera Housing", .invert: "Inverted Colors",
        .mute: "Mute", .pip: "Picture in Picture", .nightshift: "Night Shift", .truetone: "True Tone", .darkmode: "Dark Mode",
    ]
}

struct ToggleDisplaySettingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Display Setting"
    static let description = IntentDescription("Turns a display setting on if it is off, and off if it is on.")

    @Parameter(title: "Setting") var setting: DisplayToggleSetting
    @Parameter(title: "Display") var display: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try run(DisplayCommand(verb: .toggle, target: target(named: display), names: [setting.rawValue]))
        return .result()
    }
}

struct SwitchDisplayInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Display Input"
    static let description = IntentDescription("Switches a monitor to another input over DDC.")

    @Parameter(title: "Display") var display: String?
    @Parameter(title: "Input", description: "An input's name as shown in ScreenHelm, such as \"HDMI 1\", or its DDC number.")
    var input: String

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try run(DisplayCommand(verb: .set, target: target(named: display), values: [("input", input)]))
        return .result()
    }
}

enum DisplayActionChoice: String, AppEnum {
    case main, layout, keeplayout, reconnectall, stoppictures, panic

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display Action"
    static let caseDisplayRepresentations: [DisplayActionChoice: DisplayRepresentation] = [
        .main: "Make It the Main Display", .layout: "Put the Kept Arrangement Back", .keeplayout: "Keep the Current Arrangement",
        .reconnectall: "Switch Every Display Back On", .stoppictures: "Close Every Picture", .panic: "Undo Everything on Displays",
    ]
}

struct PerformDisplayActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Perform Display Action"
    static let description = IntentDescription("Does one of ScreenHelm's display actions.")

    @Parameter(title: "Action") var action: DisplayActionChoice
    @Parameter(title: "Display") var display: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try run(DisplayCommand(verb: .perform, target: target(named: display), names: [action.rawValue]))
        return .result()
    }
}

struct SwitchDisplayOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Display Off"
    static let description = IntentDescription("Switches a display off without unplugging it. \"Perform Display Action\" switches every display back on.")

    @Parameter(title: "Display") var display: String

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try run(DisplayCommand(verb: .set, target: .name(display), values: [("connected", "off")]))
        return .result()
    }
}

struct GetDisplaysIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Displays"
    static let description = IntentDescription("Lists the connected displays with their resolution, brightness and other settings, as JSON.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try run(DisplayCommand(verb: .get, target: .all)))
    }
}
