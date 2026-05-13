import AppKit
import Combine
import SwiftUI

@MainActor
final class RightSidebarToolPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .rightSidebarTool
    let mode: RightSidebarMode

    private weak var workspace: Workspace?
    private weak var fileExplorerContainerView: FileExplorerContainerView?
    private var fileExplorerStoreStorage: FileExplorerStore?
    private var fileExplorerStateStorage: FileExplorerState?
    private var workspaceObservationCancellable: AnyCancellable?

    init(workspace: Workspace, mode: RightSidebarMode) {
        self.id = UUID()
        self.mode = mode
        reattach(to: workspace)
    }

    deinit {
        // Explicit no-op so future teardown has a single home.
    }

    var fileExplorerStore: FileExplorerStore {
        if let store = fileExplorerStoreStorage { return store }
        let store = FileExplorerStore()
        store.showHiddenFiles = true
        fileExplorerStoreStorage = store
        if let workspace {
            syncFileExplorerRoot(from: workspace, store: store)
        }
        return store
    }

    var fileExplorerState: FileExplorerState {
        if let state = fileExplorerStateStorage { return state }
        let state = FileExplorerState()
        fileExplorerStateStorage = state
        return state
    }

    var displayTitle: String { mode.label }
    var displayIcon: String? { mode.symbolName }

    func reattach(to workspace: Workspace) {
        self.workspace = workspace
        observeWorkspaceRootChanges(workspace)
        syncWorkspaceRoot(from: workspace)
    }

    func attachFileExplorerContainer(_ container: FileExplorerContainerView?) {
        fileExplorerContainerView = container
    }

    func syncWorkspaceRoot(from workspace: Workspace) {
        switch mode {
        case .files, .find:
            guard let store = fileExplorerStoreStorage else { return }
            syncFileExplorerRoot(from: workspace, store: store)
        case .sessions, .feed, .dock:
            break
        }
    }

    func openFilePreview(_ filePath: String) {
        guard let workspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        _ = workspace.openOrFocusFilePreviewSurface(inPane: paneId, filePath: filePath)
    }

    var isFocusedInWorkspace: Bool {
        workspace?.focusedPanelId == id
    }

    func close() {
        fileExplorerContainerView = nil
        fileExplorerStoreStorage?.applyWorkspaceRoot(.none)
        workspaceObservationCancellable = nil
    }

    func focus() {
        switch mode {
        case .files:
            _ = fileExplorerContainerView?.focusOutline()
        case .find:
            _ = fileExplorerContainerView?.focusSearchField()
        case .sessions, .feed, .dock:
            break
        }
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        switch mode {
        case .files, .find:
            guard fileExplorerContainerView?.ownsKeyboardFocus(responder) == true else { return nil }
            return .panel
        case .sessions, .feed, .dock:
            return nil
        }
    }

    private func observeWorkspaceRootChanges(_ workspace: Workspace) {
        workspaceObservationCancellable = workspace.$currentDirectory
            .map { _ in () }
            .eraseToAnyPublisher()
        .sink { [weak self, weak workspace] _ in
            Task { @MainActor in
                guard let self, let workspace else { return }
                self.syncWorkspaceRoot(from: workspace)
            }
        }
    }

    private func syncFileExplorerRoot(from workspace: Workspace, store: FileExplorerStore) {
        store.showHiddenFiles = true

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            store.applyWorkspaceRoot(.none)
            return
        }

        store.applyWorkspaceRoot(.local(path: directory))
    }

}

struct RightSidebarToolPanelView: View {
    @ObservedObject var panel: RightSidebarToolPanel
    @EnvironmentObject private var tabManager: TabManager
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: appearance.backgroundColor))
            .simultaneousGesture(TapGesture().onEnded { requestPanelFocusIfNeeded() })
    }

    @ViewBuilder
    private var content: some View {
        switch panel.mode {
        case .files:
            FileExplorerPanelView(
                store: panel.fileExplorerStore,
                state: panel.fileExplorerState,
                onOpenFilePreview: panel.openFilePreview,
                presentation: .files,
                placement: .pane,
                onFocus: requestPanelFocusIfNeeded,
                onContainerChange: panel.attachFileExplorerContainer
            )
        case .find:
            FileExplorerPanelView(
                store: panel.fileExplorerStore,
                state: panel.fileExplorerState,
                onOpenFilePreview: panel.openFilePreview,
                presentation: .find,
                placement: .pane,
                onFocus: requestPanelFocusIfNeeded,
                onContainerChange: panel.attachFileExplorerContainer
            )
        case .sessions:
            EmptyView()
        case .feed, .dock:
            EmptyView()
        }
    }

    private func requestPanelFocusIfNeeded() {
        guard !panel.isFocusedInWorkspace else { return }
        onRequestPanelFocus()
    }

}
