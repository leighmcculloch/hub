import SwiftUI

/// The left-hand vertical tab strip: one row per terminal session, plus a button
/// to open a new one.
struct SessionSidebar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(workspace.sessions) { session in
                        SessionTab(
                            session: session,
                            isSelected: session.id == workspace.selectedSessionID,
                            onSelect: { workspace.selectedSessionID = session.id },
                            onClose: { workspace.closeSession(session) }
                        )
                    }
                }
                .padding(6)
            }

            Divider()

            Button(action: { workspace.presentingNewSession = true }) {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(10)
            .keyboardShortcut("t", modifiers: .command)
        }
        // Width is owned by ContentView so the divider can resize it.
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }
}

private struct SessionTab: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if let dir = session.workingDirectory {
                    Text(dir.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}
