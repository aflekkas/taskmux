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
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
