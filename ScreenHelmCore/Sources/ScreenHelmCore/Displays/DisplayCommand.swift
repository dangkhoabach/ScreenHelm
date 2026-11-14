import Foundation

/// One instruction about displays, the same whether it arrives from the
/// command line, a URL, the local HTTP server or the Shortcuts app:
///
///     set name=Studio brightness=0.6
///     toggle display=pointer hdr
///     perform display=main pip
///     get display=all
public struct DisplayCommand: Equatable, Sendable {
    public enum Verb: String, Sendable, CaseIterable {
        /// Reports what is asked for, or everything.
        case get
        /// Gives settings the values that follow.
        case set
        /// Flips the on/off settings named.
        case toggle
        /// Does the actions named.
        case perform
    }

    public enum Target: Equatable, Sendable {
        case main
        /// The display the pointer is on.
        case pointer
        case builtIn
        case all
        /// By the name shown in ScreenHelm, ignoring case.
        case name(String)
        /// By ScreenHelm's identity key.
        case key(String)
        /// Every display of a group the user made.
        case group(String)
    }

    public var verb: Verb
    public var target: Target
    /// Settings and their values, lowercased names, in the order given.
    public var values: [(name: String, value: String)]
    /// Names given without a value: what to toggle, perform or get.
    public var names: [String]

    public static func == (a: DisplayCommand, b: DisplayCommand) -> Bool {
        a.verb == b.verb && a.target == b.target && a.names == b.names
            && a.values.map(\.name) == b.values.map(\.name) && a.values.map(\.value) == b.values.map(\.value)
    }

    public init(verb: Verb, target: Target = .pointer, values: [(name: String, value: String)] = [], names: [String] = []) {
        self.verb = verb
        self.target = target
        self.values = values
        self.names = names
    }

    public enum ParseError: Error, Equatable, Sendable {
        case noVerb
        case unknownVerb(String)
        case unknownSetting(String)
        /// `set` with a name and no value, or `toggle` with a value.
        case wrongForm(String)
        case nothingToDo
    }

    /// What can be set to a value.
    public static let settings: Set<String> = [
        "brightness", "volume", "contrast", "mute", "resolution", "refresh", "hidpi", "rotation", "hdr", "xdr", "invert", "preset", "input",
        "mirror", "connected", "notch", "nightshift", "truetone", "darkmode", "vcp",
    ]
    /// What `toggle` flips.
    public static let toggles: Set<String> = ["mute", "hidpi", "hdr", "xdr", "invert", "notch", "connected", "nightshift", "truetone", "darkmode", "pip"]
    /// What `perform` does.
    public static let actions: Set<String> = [
        "main", "pip", "stoppictures", "layout", "keeplayout", "reconnectall", "panic", "brightnessup", "brightnessdown", "volumeup", "volumedown",
    ]
    private static let targets: Set<String> = ["display", "name", "key", "group"]

    /// From words as typed on a command line, the verb first.
    public init(arguments: [String]) throws(ParseError) {
        guard let first = arguments.first else { throw .noVerb }
        guard let verb = Verb(rawValue: first.lowercased()) else { throw .unknownVerb(first) }
        var target = Target.pointer
        var values: [(name: String, value: String)] = []
        var names: [String] = []
        for word in arguments.dropFirst() {
            guard let separator = word.firstIndex(of: "=") else {
                names.append(word.lowercased())
                continue
            }
            let name = word[..<separator].lowercased(), value = String(word[word.index(after: separator)...])
            if Self.targets.contains(name) {
                target = Self.target(name: name, value: value)
            } else {
                values.append((name, value))
            }
        }
        try self.init(verb: verb, target: target, values: values, names: names, checked: ())
    }

    /// From a URL such as `screenhelm://display/set?name=Studio&brightness=0.6`
    /// or the path and query of an HTTP request, `/display/toggle?display=main&hdr`.
    public init(url: URL) throws(ParseError) {
        var parts = url.pathComponents.filter { $0 != "/" }
        // In `screenhelm://display/set` the host is "display"; in an HTTP path it is the first part.
        if url.host?.lowercased() == "display" { parts.insert("display", at: 0) }
        guard parts.first?.lowercased() == "display", parts.count >= 2 else { throw .noVerb }
        var arguments = [parts[1]]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where item.name.lowercased() != "token" {
            arguments.append(item.value.map { "\(item.name)=\($0)" } ?? item.name)
        }
        try self.init(arguments: arguments)
    }

    private init(verb: Verb, target: Target, values: [(name: String, value: String)], names: [String], checked: Void) throws(ParseError) {
        for (name, _) in values where !Self.settings.contains(name) { throw .unknownSetting(name) }
        switch verb {
        case .set:
            if let name = names.first { throw .wrongForm(name) }
            if values.isEmpty { throw .nothingToDo }
        case .toggle:
            if let value = values.first { throw .wrongForm(value.name) }
            for name in names where !Self.toggles.contains(name) { throw .unknownSetting(name) }
            if names.isEmpty { throw .nothingToDo }
        case .perform:
            if let value = values.first { throw .wrongForm(value.name) }
            for name in names where !Self.actions.contains(name) { throw .unknownSetting(name) }
            if names.isEmpty { throw .nothingToDo }
        case .get:
            if let value = values.first { throw .wrongForm(value.name) }
        }
        self.init(verb: verb, target: target, values: values, names: names)
    }

    private static func target(name: String, value: String) -> Target {
        switch name {
        case "name": return .name(value)
        case "key": return .key(value)
        case "group": return .group(value)
        default:
            switch value.lowercased() {
            case "main": return .main
            case "pointer": return .pointer
            case "builtin", "built-in": return .builtIn
            case "all": return .all
            default: return .name(value)
            }
        }
    }

    // MARK: Values

    /// "0.6", "60%" or "60" as a fraction; nil for anything else or out of range.
    public static func fraction(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { return Double(trimmed.dropLast()).flatMap { (0...200).contains($0) ? $0 / 100 : nil } }
        guard let number = Double(trimmed), number >= 0 else { return nil }
        // A bare number above 2 is a percentage: nobody means 6000% by "60".
        return number > 2 ? (number <= 200 ? number / 100 : nil) : number
    }

    /// "on", "true", "1", "yes" and their opposites.
    public static func flag(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "on", "true", "1", "yes": true
        case "off", "false", "0", "no": false
        default: nil
        }
    }

    /// "1920x1080" or "1920×1080".
    public static func size(_ text: String) -> (width: Int, height: Int)? {
        let parts = text.lowercased().split(whereSeparator: { "x×".contains($0) }).compactMap { Int($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : nil
    }

    /// "0x10=50" or "16=50": a VCP code and the value to write to it.
    public static func vcp(_ text: String) -> (code: UInt8, value: UInt16)? {
        let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
        func number(_ text: String) -> Int? {
            text.lowercased().hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
        }
        guard parts.count == 2, let code = number(parts[0]), let value = number(parts[1]), (0...255).contains(code), (0...65535).contains(value)
        else { return nil }
        return (UInt8(code), UInt16(value))
    }
}

/// Displays the user put together under a name, to address as one.
/// Being a member is not the same as the group being active: what the
/// group does by itself, such as matching text size, waits for its rule.
public struct DisplayGroup: Codable, Equatable, Identifiable, Sendable {
    /// When a group is active.
    public enum Activation: String, Codable, Sendable, CaseIterable {
        /// Every member chosen is connected.
        case allConnected
        case anyConnected
        case atLeastTwoConnected
    }

    public var id: UUID
    public var name: String
    /// Identity keys.
    public var displays: [String]
    public var activation: Activation
    /// Not active while a display outside the group is connected.
    public var onlyMembers: Bool
    /// When a member's resolution changes, the others take the one at which
    /// things look as big.
    public var matchTextSize: Bool

    public init(id: UUID = UUID(), name: String, displays: [String] = [], activation: Activation = .allConnected,
                onlyMembers: Bool = false, matchTextSize: Bool = false) {
        self.id = id
        self.name = name
        self.displays = displays
        self.activation = activation
        self.onlyMembers = onlyMembers
        self.matchTextSize = matchTextSize
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, displays, activation, onlyMembers, matchTextSize
    }

    /// A group saved before a setting existed reads with that setting's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        displays = try c.decode([String].self, forKey: .displays)
        activation = try c.decodeIfPresent(Activation.self, forKey: .activation) ?? .allConnected
        onlyMembers = try c.decodeIfPresent(Bool.self, forKey: .onlyMembers) ?? false
        matchTextSize = try c.decodeIfPresent(Bool.self, forKey: .matchTextSize) ?? false
    }

    /// Whether the group's rule holds for the displays connected now, by identity key.
    public func isActive(connected: [String]) -> Bool {
        let members = Set(displays)
        let present = members.intersection(connected).count
        let ruleHolds = switch activation {
        case .allConnected: present > 0 && present == members.count
        case .anyConnected: present > 0
        case .atLeastTwoConnected: present >= 2
        }
        return ruleHolds && !(onlyMembers && connected.contains { !members.contains($0) })
    }

    public static func decode(_ text: String) -> [DisplayGroup] {
        (try? JSONDecoder().decode([DisplayGroup].self, from: Data(text.utf8))) ?? []
    }

    public static func encode(_ groups: [DisplayGroup]) -> String {
        (try? JSONEncoder().encode(groups)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

/// Comparing a secret without telling, by how long it took, how much of it was right.
public enum ConstantTime {
    public static func equal(_ a: String, _ b: String) -> Bool {
        let first = Array(a.utf8), second = Array(b.utf8)
        var difference = UInt8(first.count == second.count ? 0 : 1)
        for index in 0..<max(first.count, second.count) {
            difference |= (index < first.count ? first[index] : 0) ^ (index < second.count ? second[index] : 0)
        }
        return difference == 0
    }
}
