import SwiftUI

/// The sidebar: each connected display first, then the pages about all of
/// them, then Settings, which the app menu (⌘,) and the menu bar also open.
enum SidebarSection: Hashable {
    /// By the display's identity key.
    case display(String)
    case arrangement, virtualScreens, pictureInPicture, shortcuts, automation, settings

    /// The pages after the displays, in order.
    static let pages: [SidebarSection] = [.arrangement, .virtualScreens, .pictureInPicture, .shortcuts, .automation]

    /// `LocalizedStringKey`, not `String`: only that overload of `Text` reads
    /// the String Catalog. A display's page has the display's own name.
    var title: LocalizedStringKey {
        switch self {
        case .display: ""
        case .arrangement: "Arrangement"
        case .virtualScreens: "Virtual Screens"
        case .pictureInPicture: "Picture in Picture"
        case .shortcuts: "Shortcuts"
        case .automation: "Automation"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .display: "display"
        case .arrangement: "rectangle.3.group"
        case .virtualScreens: "rectangle.dashed"
        case .pictureInPicture: "pip"
        case .shortcuts: "keyboard"
        case .automation: "gearshape.2"
        case .settings: "gearshape"
        }
    }
}
