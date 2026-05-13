import AppKit
import Combine
import SwiftUI

enum TitlebarControlsStyle: Int, CaseIterable, Identifiable {
    case classic
    case compact
    case roomy
    case pillGroup
    case softButtons

    var id: Int { rawValue }

    var menuTitle: String {
        switch self {
        case .classic:
            return "Classic"
        case .compact:
            return "Compact"
        case .roomy:
            return "Roomy"
        case .pillGroup:
            return "Pill Group"
        case .softButtons:
            return "Soft Buttons"
        }
    }

    var config: TitlebarControlsStyleConfig {
        switch self {
        case .classic:
            return TitlebarControlsStyleConfig(
                spacing: 10,
                iconSize: 15,
                buttonSize: 24,
                badgeSize: 14,
                badgeOffset: CGSize(width: 2, height: -2),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 8,
                hoverBackground: false
            )
        case .compact:
            return TitlebarControlsStyleConfig(
                spacing: 6,
                iconSize: 13,
                buttonSize: 20,
                badgeSize: 12,
                badgeOffset: CGSize(width: 1, height: -1),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 6,
                hoverBackground: false
            )
        case .roomy:
            return TitlebarControlsStyleConfig(
                spacing: 14,
                iconSize: 16,
                buttonSize: 28,
                badgeSize: 16,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 10,
                hoverBackground: false
            )
        case .pillGroup:
            return TitlebarControlsStyleConfig(
                spacing: 8,
                iconSize: 14,
                buttonSize: 24,
                badgeSize: 14,
                badgeOffset: CGSize(width: 2, height: -2),
                groupBackground: false,
                groupPadding: EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4),
                buttonBackground: false,
                buttonCornerRadius: 8,
                hoverBackground: true
            )
        case .softButtons:
            return TitlebarControlsStyleConfig(
                spacing: 8,
                iconSize: 15,
                buttonSize: 26,
                badgeSize: 14,
                badgeOffset: CGSize(width: 2, height: -2),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: true,
                buttonCornerRadius: 8,
                hoverBackground: false
            )
        }
    }
}

struct TitlebarControlsStyleConfig {
    let spacing: CGFloat
    let iconSize: CGFloat
    let buttonSize: CGFloat
    let badgeSize: CGFloat
    let badgeOffset: CGSize
    let groupBackground: Bool
    let groupPadding: EdgeInsets
    let buttonBackground: Bool
    let buttonCornerRadius: CGFloat
    let hoverBackground: Bool
}

final class TitlebarControlsViewModel: ObservableObject {
    weak var notificationsAnchorView: NSView?
}

enum TitlebarControlsVisibilityMode {
    case alwaysVisible
    case onHover
}

struct TitlebarControlsView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject var viewModel: TitlebarControlsViewModel
    let onToggleSidebar: () -> Void
    let onToggleNotifications: () -> Void
    let onNewTab: () -> Void
    var visibilityMode: TitlebarControlsVisibilityMode = .onHover
    @AppStorage("titlebarControlsStyle") private var styleRawValue = TitlebarControlsStyle.classic.rawValue
    @State private var isHovering = false

    private var shouldShowControls: Bool {
        visibilityMode == .alwaysVisible || isHovering
    }

    var body: some View {
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic
        let config = style.config
        HStack(spacing: config.spacing) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: config.iconSize, weight: .medium))
                    .frame(width: config.buttonSize, height: config.buttonSize)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("titlebarControl.toggleSidebar")
            .accessibilityLabel(String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar"))
            .safeHelp(KeyboardShortcutSettings.Action.toggleSidebar.tooltip(String(localized: "titlebar.sidebar.tooltip", defaultValue: "Show or hide the sidebar")))

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: config.iconSize, weight: .medium))
                    .frame(width: config.buttonSize, height: config.buttonSize)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("titlebarControl.newTab")
            .accessibilityLabel(String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace"))
            .safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")))
        }
        .padding(config.groupPadding)
        .opacity(shouldShowControls ? 1 : 0)
        .allowsHitTesting(shouldShowControls)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

struct HiddenTitlebarSidebarControlsView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    let onToggleSidebar: () -> Void
    let onToggleNotifications: (NSView?) -> Void
    let onNewTab: () -> Void
    @StateObject private var viewModel = TitlebarControlsViewModel()
    @State private var isHoveringHost = false
    @State private var isHoveringWindowChrome = false
    @State private var hostWindowNumber: Int?
    @AppStorage("titlebarControlsStyle") private var styleRawValue = TitlebarControlsStyle.classic.rawValue

    private var shouldPinControls: Bool {
        isHoveringHost || isHoveringWindowChrome
    }

    var body: some View {
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic

        ZStack(alignment: .leading) {
            WindowAccessor { window in
                let nextWindowNumber = window.windowNumber
                let nextHoveringWindowChrome = MinimalModeSidebarChromeHoverState.shared.hoveredWindowNumber == nextWindowNumber
                if hostWindowNumber != nextWindowNumber || isHoveringWindowChrome != nextHoveringWindowChrome {
                    DispatchQueue.main.async {
                        if hostWindowNumber != nextWindowNumber {
                            hostWindowNumber = nextWindowNumber
                        }
                        if isHoveringWindowChrome != nextHoveringWindowChrome {
                            isHoveringWindowChrome = nextHoveringWindowChrome
                        }
                    }
                }
            }
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )
            .allowsHitTesting(false)

            TitlebarControlsView(
                notificationStore: notificationStore,
                viewModel: viewModel,
                onToggleSidebar: onToggleSidebar,
                onToggleNotifications: {},
                onNewTab: onNewTab,
                visibilityMode: .alwaysVisible
            )
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight,
                alignment: .leading
            )
            .opacity(shouldPinControls ? 1 : 0)
            .allowsHitTesting(shouldPinControls)
            .accessibilityHidden(true)
            .animation(.easeInOut(duration: 0.14), value: shouldPinControls)

            TitlebarControlsGapDragView(config: style.config)
                .frame(
                    width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                    height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
                )
                .allowsHitTesting(shouldPinControls)
        }
        .frame(
            width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
            height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .onHover { isHoveringHost = $0 }
    }
}

private struct TitlebarControlsGapDragView: NSViewRepresentable {
    let config: TitlebarControlsStyleConfig

    func makeNSView(context: Context) -> GapDragView {
        let view = GapDragView()
        view.config = config
        return view
    }

    func updateNSView(_ nsView: GapDragView, context: Context) {
        nsView.config = config
    }

    final class GapDragView: NSView {
        var config = TitlebarControlsStyle.classic.config

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
            guard bounds.contains(point) else { return nil }
            guard !TitlebarControlsHitRegions.pointFallsInButtonColumn(point, config: config) else {
                return nil
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2, performStandardTitlebarDoubleClick(window: window) != nil {
                return
            }
            guard !isWindowDragSuppressed(window: window) else { return }
            window?.performDrag(with: event)
        }
    }
}

func titlebarShortcutHintHeight(for config: TitlebarControlsStyleConfig) -> CGFloat {
    max(14, config.iconSize + 1)
}

func titlebarShortcutHintVerticalOffset(for config: TitlebarControlsStyleConfig) -> CGFloat {
    max(0, floor(config.buttonSize - titlebarShortcutHintHeight(for: config)))
}

func titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyleConfig) -> Bool {
    config.hoverBackground
}
