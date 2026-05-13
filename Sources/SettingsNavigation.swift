import SwiftUI

enum SettingsNavigationTarget: String, CaseIterable, Identifiable {
    case account
    case app
    case terminal
    case sidebarAppearance
    case betaFeatures
    case automation
    case browser
    case browserImport
    case globalHotkey
    case keyboardShortcuts
    case workspaceColors
    case settingsJSON
    case reset

    var id: Self { self }

    var title: String {
        switch self {
        case .account:
            return String(localized: "settings.section.account", defaultValue: "Account")
        case .app:
            return String(localized: "settings.section.app", defaultValue: "App")
        case .terminal:
            return String(localized: "settings.section.terminal", defaultValue: "Terminal")
        case .workspaceColors:
            return String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors")
        case .sidebarAppearance:
            return String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        case .betaFeatures:
            return String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features")
        case .automation:
            return String(localized: "settings.section.automation", defaultValue: "Automation")
        case .browser:
            return String(localized: "settings.section.browser", defaultValue: "Browser")
        case .browserImport:
            return String(localized: "settings.browser.import", defaultValue: "Import Browser Data")
        case .globalHotkey:
            return String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey")
        case .keyboardShortcuts:
            return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .settingsJSON:
            return String(localized: "settings.section.settingsJSON", defaultValue: "cmux.json")
        case .reset:
            return String(localized: "settings.section.reset", defaultValue: "Reset")
        }
    }

    var symbolName: String {
        switch self {
        case .account:
            return "person.crop.circle"
        case .app:
            return "gearshape"
        case .terminal:
            return "terminal"
        case .workspaceColors:
            return "paintpalette"
        case .sidebarAppearance:
            return "sidebar.left"
        case .betaFeatures:
            return "exclamationmark.triangle"
        case .automation:
            return "wand.and.sparkles"
        case .browser:
            return "globe"
        case .browserImport:
            return "square.and.arrow.down"
        case .globalHotkey:
            return "keyboard.badge.ellipsis"
        case .keyboardShortcuts:
            return "keyboard"
        case .settingsJSON:
            return "doc.text"
        case .reset:
            return "arrow.counterclockwise"
        }
    }

    var searchText: String {
        switch self {
        case .account:
            return "\(title) sign in team sync"
        case .app:
            return "\(title) appearance language workspace menu bar"
        case .terminal:
            return "\(title) scrollbar restore reopen relaunch quit toggle"
        case .workspaceColors:
            return "\(title) palette tabs"
        case .sidebarAppearance:
            return "\(title) sidebar details branches badges material terminal background"
        case .betaFeatures:
            return "\(title) beta experimental unstable dock right sidebar"
        case .automation:
            return "\(title) socket ports"
        case .browser:
            return "\(title) search engine links history theme"
        case .browserImport:
            return "\(title) browser import data bookmarks history cookies"
        case .globalHotkey:
            return "\(title) system wide shortcut"
        case .keyboardShortcuts:
            return "\(title) keybindings commands chords"
        case .settingsJSON:
            return "\(title) config file preferences editor documentation schema jsonc reload"
        case .reset:
            return "\(title) defaults"
        }
    }
}

enum SettingsNavigationRequest {
    static let notificationName = Notification.Name("cmux.settings.navigate")
    private static let targetKey = "target"
    private static let anchorKey = "anchor"
    private static let highlightKey = "highlight"

    static func post(_ target: SettingsNavigationTarget, anchorID: String? = nil, highlight: Bool = false) {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [
                targetKey: target.rawValue,
                anchorKey: anchorID ?? SettingsSearchIndex.sectionID(for: target),
                highlightKey: highlight
            ]
        )
    }

    static func target(from notification: Notification) -> SettingsNavigationTarget? {
        destination(from: notification)?.target
    }

    static func destination(from notification: Notification) -> SettingsNavigationDestination? {
        guard
            let rawValue = notification.userInfo?[targetKey] as? String,
            let target = SettingsNavigationTarget(rawValue: rawValue)
        else {
            return nil
        }
        let anchorID = notification.userInfo?[anchorKey] as? String
        let shouldHighlight = notification.userInfo?[highlightKey] as? Bool ?? false
        return SettingsNavigationDestination(
            target: target,
            anchorID: anchorID ?? SettingsSearchIndex.sectionID(for: target),
            shouldHighlight: shouldHighlight
        )
    }
}

struct SettingsNavigationDestination {
    let target: SettingsNavigationTarget
    let anchorID: String
    let shouldHighlight: Bool
}

struct SettingsSearchHighlightState: Equatable {
    let anchorID: String?
    let token: Int
    let startedAt: Date?
}

private struct SettingsSearchHighlightStateKey: EnvironmentKey {
    static let defaultValue = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)
}

extension EnvironmentValues {
    var settingsSearchHighlightState: SettingsSearchHighlightState {
        get { self[SettingsSearchHighlightStateKey.self] }
        set { self[SettingsSearchHighlightStateKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func settingsSearchAnchor(_ anchorID: String?) -> some View {
        if let anchorID {
            settingsSearchAnchors([anchorID])
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsSearchAnchors(_ anchorIDs: [String]) -> some View {
        let filteredAnchorIDs = anchorIDs.filter { !$0.isEmpty }
        if let primaryAnchorID = filteredAnchorIDs.first {
            self
                .id(primaryAnchorID)
                .modifier(SettingsSearchHighlightModifier(anchorIDs: filteredAnchorIDs))
        } else {
            self
        }
    }
}

private struct SettingsSearchHighlightModifier: ViewModifier {
    @Environment(\.settingsSearchHighlightState) private var highlightState
    let anchorIDs: [String]

    private func matches(_ state: SettingsSearchHighlightState) -> Bool {
        guard let anchorID = state.anchorID else { return false }
        return anchorIDs.contains(anchorID)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if matches(highlightState) {
                    TimelineView(.animation) { context in
                        let opacity = highlightOpacity(at: context.date, for: highlightState)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(opacity * 0.24))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.accentColor.opacity(opacity), lineWidth: 2.5)
                            )
                            .shadow(color: Color.accentColor.opacity(opacity * 0.24), radius: 8, x: 0, y: 0)
                    }
                }
            }
    }

    private func highlightOpacity(at date: Date, for state: SettingsSearchHighlightState) -> Double {
        guard matches(state), let startedAt = state.startedAt else { return 0 }
        let elapsed = date.timeIntervalSince(startedAt)
        if elapsed < 0.14 {
            return max(0, min(1, elapsed / 0.14))
        }
        if elapsed < 5 {
            return 1
        }
        if elapsed < 5.9 {
            return max(0, 1 - ((elapsed - 5) / 0.9))
        }
        return 0
    }
}

enum SettingsSearchEntryKind {
    case section
    case setting
}

struct SettingsSearchEntry: Identifiable {
    let id: String
    let kind: SettingsSearchEntryKind
    let target: SettingsNavigationTarget
    let title: String
    let subtitle: String?
    let symbolName: String
    let normalizedSearchText: String

    init(
        id: String,
        kind: SettingsSearchEntryKind,
        target: SettingsNavigationTarget,
        title: String,
        subtitle: String?,
        symbolName: String,
        searchText: String
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        normalizedSearchText = SettingsSearchIndex.normalized("\(title) \(subtitle ?? "") \(searchText)")
    }
}

enum SettingsSearchIndex {
    static let defaultSelectionID = sectionID(for: .account)

    private static let sectionEntries: [SettingsSearchEntry] = SettingsNavigationTarget.allCases.map { target in
        SettingsSearchEntry(
            id: sectionID(for: target),
            kind: .section,
            target: target,
            title: target.title,
            subtitle: nil,
            symbolName: target.symbolName,
            searchText: "\(target.rawValue) \(target.searchText) \(SettingsSearchAliasIndex.sectionAliases(for: target))"
        )
    }

    private static let settingEntries: [SettingsSearchEntry] = [
        setting(.account, "account", String(localized: "settings.section.account", defaultValue: "Account"), "sign in login team sync user profile"),
        setting(.app, "language", String(localized: "settings.app.language", defaultValue: "Language"), "locale translation japanese english restart"),
        setting(.app, "appearance", String(localized: "settings.app.appearance", defaultValue: "Appearance"), "theme light dark system"),
        setting(.app, "app-icon", String(localized: "settings.app.appIcon", defaultValue: "App Icon"), "dock icon alternate"),
        setting(.app, "new-workspace-placement", String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"), "workspace order position"),
        setting(.app, "workspace-inherit-working-directory", String(localized: "settings.app.workspaceInheritWorkingDirectory", defaultValue: "Inherit Workspace Working Directory"), "workspace cwd directory current ghostty working-directory"),
        setting(.app, "minimal-mode", String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"), "presentation compact chrome"),
        setting(.app, "keep-workspace-open", String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut", defaultValue: "Keep Workspace Open When Closing Last Surface"), "close last surface shortcut"),
        setting(.app, "focus-pane-first-click", String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click"), "mouse click focus"),
        setting(.app, "file-drops", String(localized: "settings.app.fileDrop.defaultBehavior", defaultValue: "File Drops"), "drag drop files finder path text terminal editor split preview shift"),
        setting(.app, "preferred-editor", String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"), "editor code zed subl cmd click file"),
        setting(.app, "supported-file-previews", String(localized: "settings.app.openSupportedFilesInCmux", defaultValue: "Open Supported Files in cmux"), "cmd click file preview pdf image audio video quick look editor"),
        setting(.app, "terminal-config", String(localized: "settings.app.configWindow", defaultValue: "Terminal Config"), "ghostty config merged preview"),
        setting(.app, "markdown-viewer", String(localized: "settings.app.openMarkdownInCmuxViewer", defaultValue: "Open Markdown in cmux Viewer"), "md markdown viewer"),
        setting(.app, "menu-bar-only", String(localized: "settings.app.menuBarOnly", defaultValue: "Menu Bar Only"), "dock icon cmd tab"),
        setting(.app, "show-menu-bar", String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"), "menu extra status item"),
        setting(.app, "warn-before-quit", String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"), "cmd q confirmation"),
        setting(.app, "warn-before-closing-tab", String(localized: "settings.app.warnBeforeClosingTab", defaultValue: "Warn Before Closing Tab"), "cmd w close tab confirmation"),
        setting(.app, "rename-selects-name", String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name"), "command palette rename text selection"),
        setting(.app, "palette-search-all", String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"), "cmd p search terminal browser markdown"),
        setting(.terminal, "scrollbar", String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar"), "terminal shell scrollback"),
        setting(.sidebarAppearance, "match-terminal", String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"), "sidebar material transparency"),
        setting(.sidebarAppearance, "hide-sidebar-details", String(localized: "settings.app.hideAllSidebarDetails", defaultValue: "Hide All Sidebar Details"), "workspace sidebar compact"),
        setting(.sidebarAppearance, "show-workspace-description", String(localized: "settings.app.showWorkspaceDescription", defaultValue: "Show Workspace Description in Sidebar"), "workspace description notes markdown"),
        setting(.sidebarAppearance, "sidebar-branch-layout", String(localized: "settings.app.sidebarBranchLayout", defaultValue: "Sidebar Branch Layout"), "branch directory vertical inline"),
        setting(.sidebarAppearance, "show-branch-directory", String(localized: "settings.app.showBranchDirectory", defaultValue: "Show Branch + Directory in Sidebar"), "git cwd path"),
        setting(.sidebarAppearance, "show-pull-requests", String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"), "review pr mr link"),
        setting(.sidebarAppearance, "make-pr-clickable", String(localized: "settings.app.makeSidebarPullRequestClickable", defaultValue: "Make Sidebar PR Clickable"), "pull requests pull request pr mr review clickable links select workspace row"),
        setting(.sidebarAppearance, "open-pr-links", String(localized: "settings.app.openSidebarPRLinks", defaultValue: "Open Sidebar PR Links in cmux Browser"), "pull request link browser"),
        setting(.sidebarAppearance, "open-port-links", String(localized: "settings.app.openSidebarPortLinks", defaultValue: "Open Sidebar Port Links in cmux Browser"), "port link browser"),
        setting(.sidebarAppearance, "show-ports", String(localized: "settings.app.showPorts", defaultValue: "Show Listening Ports in Sidebar"), "localhost port"),
        setting(.sidebarAppearance, "show-log", String(localized: "settings.app.showLog", defaultValue: "Show Latest Log in Sidebar"), "status message"),
        setting(.sidebarAppearance, "show-progress", String(localized: "settings.app.showProgress", defaultValue: "Show Progress in Sidebar"), "progress bar"),
        setting(.sidebarAppearance, "show-metadata", String(localized: "settings.app.showMetadata", defaultValue: "Show Custom Metadata in Sidebar"), "report meta status block"),
        setting(.betaFeatures, "dock", String(localized: "settings.betaFeatures.dock", defaultValue: "Dock"), "dock right sidebar terminal controls tui"),
        setting(.automation, "socket-mode", String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"), "unix socket api access password auth"),
        setting(.automation, "socket-password", String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"), "socket auth credential"),
        setting(.automation, "port-base", String(localized: "settings.automation.portBase", defaultValue: "Port Base"), "CMUX_PORT start"),
        setting(.automation, "port-range", String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"), "CMUX_PORT_END workspace ports"),
        setting(.browser, "search-engine", String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"), "address bar query google duckduckgo"),
        setting(.browser, "enable-browser", String(localized: "settings.browser.enabled", defaultValue: "Enable cmux Browser"), "webview tabs links"),
        setting(.browser, "search-suggestions", String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions"), "browser address bar suggestions"),
        setting(.browser, "theme", String(localized: "settings.browser.theme", defaultValue: "Browser Theme"), "web appearance light dark system"),
        setting(.browser, "terminal-links", String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"), "click links browser"),
        setting(.browser, "intercept-open", String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"), "open command urls"),
        setting(.browser, "host-whitelist", String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"), "hosts wildcard terminal links"),
        setting(.browser, "external-patterns", String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"), "regex url rules default browser"),
        setting(.browser, "http-allowlist", String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"), "localhost non https warning"),
        setting(.browserImport, "import-data", String(localized: "settings.browser.import", defaultValue: "Import Browser Data"), "bookmarks history cookies profiles"),
        setting(.browserImport, "import-hint", String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser tabs"), "blank tab browser import"),
        setting(.browser, "react-grab", String(localized: "settings.browser.reactGrabVersion", defaultValue: "React Grab Version"), "npm react grab toolbar"),
        setting(.browser, "history", String(localized: "settings.browser.history", defaultValue: "Browsing History"), "clear visited suggestions"),
        setting(.globalHotkey, "enable-hotkey", String(localized: "settings.globalHotkey.enable", defaultValue: "Enable System-Wide Hotkey"), "global shortcut show hide windows"),
        setting(.globalHotkey, "shortcut", String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey"), "keyboard recorder command option control"),
        setting(.keyboardShortcuts, "shortcut-chords", String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"), "tmux multi step keybindings"),
        setting(.keyboardShortcuts, "reset-defaults", String(localized: "settings.shortcuts.resetDefaults", defaultValue: "Reset Default Shortcuts"), "restore built in builtin defaults keybindings hotkeys chords commands"),
        setting(.keyboardShortcuts, "shortcuts", String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"), "keybindings commands"),
        setting(.workspaceColors, "indicator", String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"), "tab color indicator"),
        setting(.workspaceColors, "selection", String(localized: "settings.workspaceColors.selectionColor", defaultValue: "Selection Highlight"), "selected workspace background"),
        setting(.workspaceColors, "palette", String(localized: "settings.workspaceColors.resetPalette", defaultValue: "Reset Palette"), "named colors palette"),
        setting(.settingsJSON, "open-file", String(localized: "settings.settingsJSON.openFile", defaultValue: "Open cmux.json"), "config json file editor dotfiles"),
        setting(.reset, "reset-all", String(localized: "settings.reset.resetAll", defaultValue: "Reset All Settings"), "restore defaults")
    ]

    private static let allEntries = sectionEntries + settingEntries

    private static let entriesByID: [String: SettingsSearchEntry] = Dictionary(
        uniqueKeysWithValues: allEntries.map { ($0.id, $0) }
    )

    private static let settingsPathAnchorIDs: [String: String] = [
        "rightSidebar.beta.dock.enabled": settingID(for: .betaFeatures, idSuffix: "dock"),
        "app.language": settingID(for: .app, idSuffix: "language"),
        "app.appearance": settingID(for: .app, idSuffix: "appearance"),
        "app.appIcon": settingID(for: .app, idSuffix: "app-icon"),
        "app.newWorkspacePlacement": settingID(for: .app, idSuffix: "new-workspace-placement"),
        "app.workspaceInheritWorkingDirectory": settingID(for: .app, idSuffix: "workspace-inherit-working-directory"),
        "app.minimalMode": settingID(for: .app, idSuffix: "minimal-mode"),
        "app.keepWorkspaceOpenWhenClosingLastSurface": settingID(for: .app, idSuffix: "keep-workspace-open"),
        "app.focusPaneOnFirstClick": settingID(for: .app, idSuffix: "focus-pane-first-click"),
        "fileDrop.defaultBehavior": settingID(for: .app, idSuffix: "file-drops"),
        "app.fileDropDefaultBehavior": settingID(for: .app, idSuffix: "file-drops"),
        "app.preferredEditor": settingID(for: .app, idSuffix: "preferred-editor"),
        "app.openSupportedFilesInCmux": settingID(for: .app, idSuffix: "supported-file-previews"),
        "app.openMarkdownInCmuxViewer": settingID(for: .app, idSuffix: "markdown-viewer"),
        "app.menuBarOnly": settingID(for: .app, idSuffix: "menu-bar-only"),
        "app.warnBeforeQuit": settingID(for: .app, idSuffix: "warn-before-quit"),
        "app.warnBeforeClosingTab": settingID(for: .app, idSuffix: "warn-before-closing-tab"),
        "app.renameSelectsExistingName": settingID(for: .app, idSuffix: "rename-selects-name"),
        "app.commandPaletteSearchesAllSurfaces": settingID(for: .app, idSuffix: "palette-search-all"),
        "sidebar.hideAllDetails": settingID(for: .sidebarAppearance, idSuffix: "hide-sidebar-details"),
        "sidebar.showWorkspaceDescription": settingID(for: .sidebarAppearance, idSuffix: "show-workspace-description"),
        "sidebar.branchLayout": settingID(for: .sidebarAppearance, idSuffix: "sidebar-branch-layout"),
        "sidebar.showBranchDirectory": settingID(for: .sidebarAppearance, idSuffix: "show-branch-directory"),
        "sidebar.showPullRequests": settingID(for: .sidebarAppearance, idSuffix: "show-pull-requests"),
        "sidebar.makePullRequestsClickable": settingID(for: .sidebarAppearance, idSuffix: "make-pr-clickable"),
        "sidebar.openPullRequestLinksInCmuxBrowser": settingID(for: .sidebarAppearance, idSuffix: "open-pr-links"),
        "sidebar.openPortLinksInCmuxBrowser": settingID(for: .sidebarAppearance, idSuffix: "open-port-links"),
        "sidebar.showSSH": settingID(for: .sidebarAppearance, idSuffix: "show-ssh"),
        "sidebar.showPorts": settingID(for: .sidebarAppearance, idSuffix: "show-ports"),
        "sidebar.showLog": settingID(for: .sidebarAppearance, idSuffix: "show-log"),
        "sidebar.showProgress": settingID(for: .sidebarAppearance, idSuffix: "show-progress"),
        "sidebar.showCustomMetadata": settingID(for: .sidebarAppearance, idSuffix: "show-metadata"),
        "terminal.showScrollBar": settingID(for: .terminal, idSuffix: "scrollbar"),
        "workspaceColors.indicatorStyle": settingID(for: .workspaceColors, idSuffix: "indicator"),
        "workspaceColors.selectionColor": settingID(for: .workspaceColors, idSuffix: "selection"),
        "sidebarAppearance.matchTerminalBackground": settingID(for: .sidebarAppearance, idSuffix: "match-terminal"),
        "automation.socketControlMode": settingID(for: .automation, idSuffix: "socket-mode"),
        "automation.socketPassword": settingID(for: .automation, idSuffix: "socket-password"),
        "automation.portBase": settingID(for: .automation, idSuffix: "port-base"),
        "automation.portRange": settingID(for: .automation, idSuffix: "port-range"),
        "browser.enabled": settingID(for: .browser, idSuffix: "enable-browser"),
        "browser.defaultSearchEngine": settingID(for: .browser, idSuffix: "search-engine"),
        "browser.showSearchSuggestions": settingID(for: .browser, idSuffix: "search-suggestions"),
        "browser.theme": settingID(for: .browser, idSuffix: "theme"),
        "browser.openTerminalLinksInCmuxBrowser": settingID(for: .browser, idSuffix: "terminal-links"),
        "browser.interceptTerminalOpenCommandInCmuxBrowser": settingID(for: .browser, idSuffix: "intercept-open"),
        "browser.hostsToOpenInEmbeddedBrowser": settingID(for: .browser, idSuffix: "host-whitelist"),
        "browser.urlsToAlwaysOpenExternally": settingID(for: .browser, idSuffix: "external-patterns"),
        "browser.insecureHttpHostsAllowedInEmbeddedBrowser": settingID(for: .browser, idSuffix: "http-allowlist"),
        "browser.showImportHintOnBlankTabs": settingID(for: .browserImport, idSuffix: "import-hint"),
        "browser.reactGrabVersion": settingID(for: .browser, idSuffix: "react-grab"),
        "shortcuts.bindings": settingID(for: .keyboardShortcuts, idSuffix: "shortcuts")
    ]

    static func entries(matching query: String) -> [SettingsSearchEntry] {
        let tokens = normalizedTokens(for: query)
        guard !tokens.isEmpty else { return sectionEntries }
        return allEntries.filter { entry in
            tokens.allSatisfy { token in entry.normalizedSearchText.contains(token) }
        }
    }

    static func entry(withID id: String) -> SettingsSearchEntry? {
        entriesByID[id]
    }

    static func sectionEntry(for target: SettingsNavigationTarget) -> SettingsSearchEntry {
        entriesByID[sectionID(for: target)] ?? sectionEntries[0]
    }

    static func sectionID(for target: SettingsNavigationTarget) -> String { "section:\(target.rawValue)" }
    static func settingID(for target: SettingsNavigationTarget, idSuffix: String) -> String { "setting:\(target.rawValue):\(idSuffix)" }

    static func anchorID(forSettingsPath path: String) -> String? {
        settingsPathAnchorIDs[path]
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func setting(
        _ target: SettingsNavigationTarget,
        _ idSuffix: String,
        _ title: String,
        _ searchText: String
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: settingID(for: target, idSuffix: idSuffix),
            kind: .setting,
            target: target,
            title: title,
            subtitle: target.title,
            symbolName: target.symbolName,
            searchText: "\(target.rawValue) \(idSuffix) \(target.searchText) \(searchText) \(SettingsSearchAliasIndex.aliases(target: target, idSuffix: idSuffix))"
        )
    }

    private static func normalizedTokens(for query: String) -> [String] {
        normalized(query)
            .split { character in
                character.unicodeScalars.allSatisfy { scalar in
                    CharacterSet.whitespacesAndNewlines.contains(scalar)
                        || CharacterSet.punctuationCharacters.contains(scalar)
                }
            }
            .map(String.init)
    }
}
