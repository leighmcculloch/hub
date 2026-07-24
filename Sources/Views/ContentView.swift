import SwiftUI

/// The workspace layout: vertical session tabs on the left, the active terminal
/// in the middle, and a toggleable git worktree diff sidebar on the right.
struct ContentView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            SessionSidebar(workspace: workspace)
            Divider()

            TerminalHost(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if workspace.showDiffSidebar {
                Divider()
                DiffSidebar(workspace: workspace)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
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
