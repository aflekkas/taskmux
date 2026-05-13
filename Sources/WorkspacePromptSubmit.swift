import Foundation

enum IMessageModeSettings {
    static let key = "app.iMessageMode"
    static let defaultValue = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        false
    }
}

extension TabManager {
    @discardableResult
    func handlePromptSubmit(
        workspaceId: UUID,
        message: String?,
        iMessageModeEnabled: Bool = false
    ) -> (messageRecorded: Bool, reordered: Bool, index: Int)? {
        handleConversationMessage(
            workspaceId: workspaceId,
            message: message,
            iMessageModeEnabled: iMessageModeEnabled,
            reorderWithoutMessage: true
        )
    }

    @discardableResult
    func handleAssistantFinalMessage(
        workspaceId: UUID,
        message: String?,
        iMessageModeEnabled: Bool = false
    ) -> (messageRecorded: Bool, reordered: Bool, index: Int)? {
        handleConversationMessage(
            workspaceId: workspaceId,
            message: message,
            iMessageModeEnabled: iMessageModeEnabled,
            reorderWithoutMessage: false
        )
    }

    private func handleConversationMessage(
        workspaceId: UUID,
        message: String?,
        iMessageModeEnabled: Bool,
        reorderWithoutMessage: Bool
    ) -> (messageRecorded: Bool, reordered: Bool, index: Int)? {
        guard let originalIndex = tabs.firstIndex(where: { $0.id == workspaceId }) else {
            return nil
        }
        guard iMessageModeEnabled else {
            return (false, false, originalIndex)
        }

        let workspace = tabs[originalIndex]
        let hasMessage = Workspace.conversationMessagePreview(from: message) != nil
        let messageRecorded = workspace.recordConversationMessage(message)
        guard messageRecorded || reorderWithoutMessage || hasMessage else {
            return (messageRecorded, false, originalIndex)
        }
        moveTabToTop(workspaceId)
        let newIndex = tabs.firstIndex(where: { $0.id == workspaceId }) ?? originalIndex
        return (messageRecorded, newIndex != originalIndex, newIndex)
    }
}

extension Workspace {
    static func conversationMessagePreview(from message: String?, maxLength: Int = 240) -> String? {
        guard let message else { return nil }
        let collapsed = message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        return "\(collapsed.prefix(maxLength))..."
    }
}
