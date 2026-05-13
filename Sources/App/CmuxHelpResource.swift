import Foundation

enum CmuxHelpResource {
    case gettingStarted
    case concepts
    case configuration
    case customCommands
    case dock
    case keyboardShortcuts
    case apiReference
    case browserAutomation
    case notifications
    case ssh
    case skills
    case claudeCodeTeams
    case ohMyOpenCode
    case ohMyCodex
    case ohMyClaudeCode
    case githubIssues

    var title: String {
        switch self {
        case .gettingStarted:
            return String(localized: "menu.help.gettingStarted", defaultValue: "Getting Started")
        case .concepts:
            return String(localized: "menu.help.concepts", defaultValue: "Concepts")
        case .configuration:
            return String(localized: "menu.help.configuration", defaultValue: "Configuration")
        case .customCommands:
            return String(localized: "menu.help.customCommands", defaultValue: "Custom Commands")
        case .dock:
            return String(localized: "menu.help.dock", defaultValue: "Dock")
        case .keyboardShortcuts:
            return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .apiReference:
            return String(localized: "menu.help.apiReference", defaultValue: "API Reference")
        case .browserAutomation:
            return String(localized: "menu.help.browserAutomation", defaultValue: "Browser Automation")
        case .notifications:
            return String(localized: "menu.help.notifications", defaultValue: "Notifications")
        case .ssh:
            return String(localized: "menu.help.ssh", defaultValue: "SSH")
        case .skills:
            return String(localized: "menu.help.skills", defaultValue: "Skills")
        case .claudeCodeTeams:
            return String(localized: "menu.help.claudeCodeTeams", defaultValue: "Claude Code Teams")
        case .ohMyOpenCode:
            return String(localized: "menu.help.ohMyOpenCode", defaultValue: "oh-my-opencode")
        case .ohMyCodex:
            return String(localized: "menu.help.ohMyCodex", defaultValue: "oh-my-codex")
        case .ohMyClaudeCode:
            return String(localized: "menu.help.ohMyClaudeCode", defaultValue: "oh-my-claudecode")
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
            return URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/cli-contract.md")!
        case .customCommands:
            return URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/cli-contract.md")!
        case .dock:
            return URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/dock.md")!
        case .keyboardShortcuts:
            return URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/cli-contract.md")!
        case .apiReference:
            return URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/cli-contract.md")!
        case .browserAutomation:
            return URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/browser-automation-surface-spec.md")!
        case .notifications:
            return URL(string: "https://github.com/aflekkas/taskmux#readme")!
        case .ssh:
            return URL(string: "https://github.com/aflekkas/taskmux#readme")!
        case .skills:
            return URL(string: "https://github.com/aflekkas/taskmux/tree/main/skills")!
        case .claudeCodeTeams:
            return URL(string: "https://github.com/aflekkas/taskmux/tree/main/skills")!
        case .ohMyOpenCode:
            return URL(string: "https://github.com/aflekkas/taskmux/tree/main/skills")!
        case .ohMyCodex:
            return URL(string: "https://github.com/aflekkas/taskmux/tree/main/skills")!
        case .ohMyClaudeCode:
            return URL(string: "https://github.com/aflekkas/taskmux/tree/main/skills")!
        case .githubIssues:
            return URL(string: "https://github.com/aflekkas/taskmux/issues")!
        }
    }
}
