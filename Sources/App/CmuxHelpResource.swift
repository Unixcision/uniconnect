import Foundation

enum CmuxHelpResource {
    case manual
    case menusAndShortcuts
    case githubIssues

    var title: String {
        switch self {
        case .manual:
            return String(localized: "menu.help.manual", defaultValue: "UniConnect Manual")
        case .menusAndShortcuts:
            return String(localized: "menu.help.menusAndShortcuts", defaultValue: "Menus and Keyboard Shortcuts")
        case .githubIssues:
            return String(localized: "menu.help.reportIssue", defaultValue: "Report an Issue")
        }
    }

    var systemImage: String {
        switch self {
        case .manual:
            return "book.closed"
        case .menusAndShortcuts:
            return "command"
        case .githubIssues:
            return "exclamationmark.bubble"
        }
    }

    var url: URL {
        switch self {
        case .manual:
            return URL(string: "https://github.com/Unixcision/uniconnect/blob/uniconnect/docs/UNICONNECT.md")!
        case .menusAndShortcuts:
            return URL(string: "https://github.com/Unixcision/uniconnect/blob/uniconnect/docs/MENUS.md")!
        case .githubIssues:
            return URL(string: "https://github.com/Unixcision/uniconnect/issues")!
        }
    }
}
