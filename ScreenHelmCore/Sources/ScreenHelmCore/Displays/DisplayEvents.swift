import Foundation

/// Something done when a display connects, disconnects, or the displays
/// sleep or wake: a Shortcut run, or an app or file opened.
public struct DisplayEventAction: Codable, Equatable, Identifiable, Sendable {
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        case connected, disconnected, sleep, wake
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// `target` is the Shortcut's name.
        case shortcut
        /// `target` is the path of an app or a file.
        case open
    }

    public var id: UUID
    public var trigger: Trigger
    /// The identity key of the display it is for; empty for any display.
    public var display: String
    public var kind: Kind
    public var target: String

    public init(id: UUID = UUID(), trigger: Trigger, display: String = "", kind: Kind, target: String) {
        self.id = id
        self.trigger = trigger
        self.display = display
        self.kind = kind
        self.target = target
    }

    /// The actions to run for an event; `display` is nil for sleep and wake.
    public static func matching(_ actions: [DisplayEventAction], trigger: Trigger, display: String?) -> [DisplayEventAction] {
        actions.filter { action in
            action.trigger == trigger && !action.target.isEmpty && (action.display.isEmpty || display == nil || action.display == display)
        }
    }

    public static func decode(_ text: String) -> [DisplayEventAction] {
        (try? JSONDecoder().decode([DisplayEventAction].self, from: Data(text.utf8))) ?? []
    }

    public static func encode(_ actions: [DisplayEventAction]) -> String {
        (try? JSONEncoder().encode(actions)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
