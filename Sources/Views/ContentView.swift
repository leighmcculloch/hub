import SwiftUI

/// The workspace layout: vertical session tabs on the left, the active terminal
/// in the middle, and a toggleable git worktree diff sidebar on the right.
struct ContentView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            SessionSidebar(workspace: workspace)
            Divider()

            ZStack {
                TerminalHost(workspace: workspace)
                if workspace.sessions.isEmpty {
                    EmptyWorkspaceView(workspace: workspace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if workspace.showDiffSidebar {
                Divider()
                DiffSidebar(workspace: workspace)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .sheet(isPresented: $workspace.presentingNewSession) {
            NewSessionSheet(workspace: workspace)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspace.showDiffSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle worktree diff")
            }
        }
    }
}

private struct EmptyWorkspaceView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No sessions")
                .font(.headline)
            Text("Create a session to provision an exe.dev VM and clone repos into it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Session…") { workspace.presentingNewSession = true }
                .keyboardShortcut("t", modifiers: .command)
        }
        .padding(40)
    }
}
