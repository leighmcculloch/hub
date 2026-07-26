import SwiftUI

/// The workspace layout: vertical session tabs on the left, the active terminal
/// in the middle, and a git worktree diff sidebar on the right. Both sidebars
/// are resizable (drag the divider) and hideable (⌘S / ⌘R).
struct ContentView: View {
    @ObservedObject var workspace: Workspace

    // Persisted widths. Dragging updates the @State copies only; writing
    // UserDefaults on every drag frame re-rendered the whole window (terminal
    // included) and made the divider stutter, so storage is written on release.
    @AppStorage("sessionSidebarWidth") private var storedSessionSidebarWidth: Double = 220
    @AppStorage("diffSidebarWidth") private var storedDiffSidebarWidth: Double = 380
    @State private var sessionSidebarWidth: Double = 220
    @State private var diffSidebarWidth: Double = 380

    var body: some View {
        HStack(spacing: 0) {
            if workspace.showSessionSidebar {
                SessionSidebar(workspace: workspace)
                    .frame(width: sessionSidebarWidth)
                ResizeHandle(width: $sessionSidebarWidth, range: 160...460, direction: 1,
                             onCommit: { storedSessionSidebarWidth = sessionSidebarWidth })
            }

            ZStack {
                TerminalHost(workspace: workspace)
                if workspace.sessions.isEmpty {
                    EmptyWorkspaceView(workspace: workspace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if workspace.showDiffSidebar {
                ResizeHandle(width: $diffSidebarWidth, range: 260...760, direction: -1,
                             onCommit: { storedDiffSidebarWidth = diffSidebarWidth })
                RightSidebar(workspace: workspace)
                    .frame(width: diffSidebarWidth)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .navigationTitle(windowTitle)
        .sheet(isPresented: $workspace.presentingNewSession) {
            NewSessionSheet(workspace: workspace)
        }
        // Populate the sidebar with existing VMs on open, without connecting.
        .task {
            await workspace.loadGitHubUser()
            await workspace.loadAvailableVMs()
        }
        .onAppear {
            sessionSidebarWidth = storedSessionSidebarWidth
            diffSidebarWidth = storedDiffSidebarWidth
        }
        // Recover SSH tabs that dropped while the app was in the background.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            workspace.reconnectDisconnectedSessions()
            Task { await workspace.loadAvailableVMs() }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    workspace.showSessionSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle sessions sidebar (⌘S)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspace.showDiffSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle worktree diff (⌘R)")
            }
        }
    }

    /// "Exe Desktop App — <session>", so the current session is visible in the
    /// title bar alongside the app name.
    private var windowTitle: String {
        guard let session = workspace.selectedSession else { return "Exe Desktop App" }
        return "Exe Desktop App — \(session.displayName)"
    }
}

private struct EmptyWorkspaceView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        // Nothing is auto-selected at launch, so this is just the entry point to
        // a new session; existing VMs are listed in the sidebar.
        Button("New Session…") { workspace.presentingNewSession = true }
            .keyboardShortcut("t", modifiers: .command)
            .padding(40)
    }
}
