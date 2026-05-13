import Foundation

enum MainWindowKeyboardFocusIntent: Equatable {
    case mainPanel(workspaceId: UUID, panelId: UUID)
    case rightSidebar(mode: RightSidebarMode)
}

enum MainWindowFocusToggleDestination: Equatable {
    case terminal
    case rightSidebar
}

enum MainWindowFindShortcutTarget: Equatable {
    case mainPanelFind
    case rightSidebarFileSearch
    case none
}
