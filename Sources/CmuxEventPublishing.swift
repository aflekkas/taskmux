import Foundation

extension CmuxEventBus {
    func publishWorkspaceCreated(
        workspaceId: UUID,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        selected: Bool,
        index: Int?,
        tabCount: Int?
    ) {
        publish(
            name: "workspace.created",
            category: "workspace",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            payload: workspacePayload(
                workspaceId: workspaceId,
                title: title,
                customTitle: customTitle,
                currentDirectory: currentDirectory,
                selected: selected,
                index: index,
                tabCount: tabCount
            )
        )
    }

    func publishWorkspaceClosed(
        workspaceId: UUID,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        remainingTabCount: Int?
    ) {
        publish(
            name: "workspace.closed",
            category: "workspace",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            payload: workspacePayload(
                workspaceId: workspaceId,
                title: title,
                customTitle: customTitle,
                currentDirectory: currentDirectory,
                selected: false,
                index: nil,
                tabCount: remainingTabCount
            )
        )
    }

    func publishWorkspaceSelected(
        workspaceId: UUID,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        previousWorkspaceId: UUID?,
        index: Int?,
        tabCount: Int?
    ) {
        publish(
            name: "workspace.selected",
            category: "workspace",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            payload: workspacePayload(
                workspaceId: workspaceId,
                title: title,
                customTitle: customTitle,
                currentDirectory: currentDirectory,
                selected: true,
                previousWorkspaceId: previousWorkspaceId,
                index: index,
                tabCount: tabCount
            )
        )
    }

    func publishWindowLifecycle(
        name: String,
        windowId: UUID,
        workspaceId: UUID?,
        workspaceCount: Int?,
        selectedWorkspaceIndex: Int?,
        isKeyWindow: Bool?,
        isMainWindow: Bool?,
        origin: String
    ) {
        publish(
            name: name,
            category: "window",
            source: "window.lifecycle",
            workspaceId: workspaceId?.uuidString,
            windowId: windowId.uuidString,
            payload: [
                "window_id": windowId.uuidString,
                "workspace_id": workspaceId?.uuidString ?? NSNull(),
                "workspace_count": workspaceCount ?? NSNull(),
                "selected_workspace_index": selectedWorkspaceIndex ?? NSNull(),
                "is_key_window": isKeyWindow ?? NSNull(),
                "is_main_window": isMainWindow ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishPaneCreated(
        workspaceId: UUID,
        paneId: UUID,
        sourcePaneId: UUID?,
        orientation: String,
        surfaceId: UUID?,
        origin: String
    ) {
        publish(
            name: "pane.created",
            category: "pane",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId?.uuidString,
            paneId: paneId.uuidString,
            payload: [
                "pane_id": paneId.uuidString,
                "source_pane_id": sourcePaneId?.uuidString ?? NSNull(),
                "orientation": orientation,
                "surface_id": surfaceId?.uuidString ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishSurfaceCreated(
        workspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {
        publish(
            name: "surface.created",
            category: "surface",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            paneId: paneId?.uuidString,
            payload: [
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId?.uuidString ?? NSNull(),
                "kind": kind,
                "origin": origin,
                "focused": focused
            ]
        )
    }

    func publishSurfaceSelected(
        workspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?,
        kind: String?,
        previousSurfaceId: UUID?,
        focused: Bool,
        origin: String
    ) {
        publish(
            name: "surface.selected",
            category: "surface",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            paneId: paneId?.uuidString,
            payload: [
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId?.uuidString ?? NSNull(),
                "kind": kind ?? NSNull(),
                "previous_surface_id": previousSurfaceId?.uuidString ?? NSNull(),
                "focused": focused,
                "origin": origin
            ]
        )
    }

    func publishSurfaceFocused(workspaceId: UUID, surfaceId: UUID, paneId: UUID?, kind: String?, origin: String) {
        publish(
            name: "surface.focused",
            category: "surface",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            paneId: paneId?.uuidString,
            payload: [
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId?.uuidString ?? NSNull(),
                "kind": kind ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishSurfaceClosed(workspaceId: UUID, surfaceId: UUID, paneId: UUID?, kind: String?, origin: String) {
        publish(
            name: "surface.closed",
            category: "surface",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            paneId: paneId?.uuidString,
            payload: [
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId?.uuidString ?? NSNull(),
                "kind": kind ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishPaneClosed(workspaceId: UUID, paneId: UUID, closedSurfaceIds: [UUID], origin: String) {
        publish(
            name: "pane.closed",
            category: "pane",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            paneId: paneId.uuidString,
            payload: [
                "pane_id": paneId.uuidString,
                "closed_surface_ids": closedSurfaceIds.map(\.uuidString),
                "origin": origin
            ]
        )
    }

    func publishPaneFocused(workspaceId: UUID, paneId: UUID, selectedSurfaceId: UUID?, origin: String) {
        publish(
            name: "pane.focused",
            category: "pane",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: selectedSurfaceId?.uuidString,
            paneId: paneId.uuidString,
            payload: [
                "pane_id": paneId.uuidString,
                "selected_surface_id": selectedSurfaceId?.uuidString ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishNotificationChanges(oldValue: [TerminalNotification], newValue: [TerminalNotification]) {
    }

    func publishNotificationCreated(
        _ notification: TerminalNotification,
        delivery: String,
        replacedNotificationIds: [String]
    ) {
    }

    func publishNotificationRead(ids: [String], workspaceId: UUID?, surfaceId: UUID?) {
    }

    func publishNotificationRemoved(_ notification: TerminalNotification) {
    }

    func publishNotificationCleared(ids: [String], workspaceId: UUID?, surfaceId: UUID?) {
    }

    private func workspacePayload(
        workspaceId: UUID,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        selected: Bool,
        previousWorkspaceId: UUID? = nil,
        index: Int?,
        tabCount: Int?
    ) -> [String: Any] {
        [
            "workspace_id": workspaceId.uuidString,
            "title": title,
            "custom_title": customTitle ?? NSNull(),
            "cwd": currentDirectory,
            "selected": selected,
            "previous_workspace_id": previousWorkspaceId?.uuidString ?? NSNull(),
            "index": index ?? NSNull(),
            "tab_count": tabCount ?? NSNull()
        ]
    }
}
