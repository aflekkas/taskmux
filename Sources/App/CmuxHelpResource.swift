import Foundation

enum CmuxHelpResource {
    case gettingStarted
    case concepts
    case configuration
    case dock
    case keyboardShortcuts
    case browserAutomation
    case githubIssues

    var title: String {
        switch self {
        case .gettingStarted:
            return String(localized: "menu.help.gettingStarted", defaultValue: "Getting Started")
        case .concepts:
            return String(localized: "menu.help.concepts", defaultValue: "Concepts")
        case .configuration:
            return String(localized: "menu.help.configuration", defaultValue: "Configuration")
        case .dock:
            return String(localized: "menu.help.dock", defaultValue: "Dock")
        case .keyboardShortcuts:
            return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .browserAutomation:
            return String(localized: "menu.help.browserAutomation", defaultValue: "Browser Automation")
        case .githubIssues:
            return String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues")
        }
    }

    var url: URL {
        switch self {
        case .gettingStarted:
            return URL(string: "https://github.com/aflekkas/taskmux#readme")!
        case .concepts:
            return URL(string: "https://github.com/aflekkas/taskmux#readme")!
        case .configuration:
            return URL(string: "https://github.com/aflekkas/taskmux#readme")!
        case .dock:
            return URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/dock.md")!
        case .keyboardShortcuts:
            return URL(string: "https://github.com/aflekkas/taskmux/tree/main/docs")!
        case .browserAutomation:
            return URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/browser-automation-surface-spec.md")!
        case .githubIssues:
            return URL(string: "https://github.com/aflekkas/taskmux/issues")!
        }
    }
}
