import AppKit
import SwiftUI

struct DockEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(localized: "dock.empty.title", defaultValue: "No Dock Controls"))
                .font(.system(size: 13, weight: .semibold))
            Text(String(
                localized: "dock.empty.subtitle",
                defaultValue: "Add controls to .cmux/dock.json."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Button {
                    openDockDocs()
                } label: {
                    Label(
                        String(localized: "dock.empty.openDocs", defaultValue: "Docs"),
                        systemImage: "questionmark.circle"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(localized: "dock.empty.openDocs.help", defaultValue: "Open the Dock documentation"))
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openDockDocs() {
        guard let url = URL(string: "https://github.com/aflekkas/taskmux/blob/main/docs/dock.md") else { return }
        NSWorkspace.shared.open(url)
    }
}
