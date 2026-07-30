import AppKit
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

            VStack(spacing: 0) {
                // tmux's windows, as tabs. A local shell has no tmux and so no
                // strip.
                if let session = workspace.selectedSession, session.showsTabBar {
                    TerminalTabBar(session: session)
                    Divider()
                }
                ZStack {
                    TerminalHost(workspace: workspace)
                    if workspace.sessions.isEmpty {
                        EmptyWorkspaceView(workspace: workspace)
                    } else if let session = workspace.selectedSession, session.tabs.isEmpty {
                        ConnectingView(session: session)
                    }
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
        // We don't use the standard macOS window tab bar — the vertical session
        // tabs on the left and the subtabs in the terminal and right sidebar
        // are our own. Disallow native tabbing so the system "Show Tab Bar"
        // menu item (View menu) can't bring up the stock bar.
        .background(DisableNativeTabBar())
        .sheet(isPresented: $workspace.presentingNewSession) {
            NewSessionSheet(workspace: workspace)
        }
        // Populate the sidebar with existing VMs on open, without connecting.
        .task {
            await workspace.loadGitHubUser()
            // Restore after the VM list so tabs whose VM is gone are dropped.
            await workspace.loadAvailableVMs()
            workspace.restoreSessions()
        }
        // A VM that named itself has a new name and a new hostname; both the
        // sidebar and the stored workspace have to follow it.
        .task {
            await workspace.followVMRenames()
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

/// Shown while a VM session has no panes yet: either it is still connecting, or
/// the connection failed and there is something to say about why. Without this
/// a failed attach is an empty black rectangle.
private struct ConnectingView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 8) {
            if session.isDisconnected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
                Text("Disconnected")
                    .font(.system(size: 12, weight: .semibold))
                if let reason = session.disconnectReason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Reconnect") { session.reconnect() }
                    .padding(.top, 4)
            } else {
                ProgressView().controlSize(.small)
                Text("Connecting to \(session.sshDestination ?? "the VM")…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
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

/// Disables macOS native window tabbing for the hosting window. A no-op view
/// whose only job is to grab the `NSWindow` once it's attached and set
/// `tabbingMode` to `.disallowed`, which greys out the system "Show Tab Bar"
/// menu item. Re-applied if the view re-hosts into a different window.
private struct DisableNativeTabBar: NSViewRepresentable {
    func makeNSView(context: Context) -> DisableNativeTabBarView {
        DisableNativeTabBarView()
    }

    func updateNSView(_ nsView: DisableNativeTabBarView, context: Context) {}
}

/// `viewDidMoveToWindow` fires both on attach (window present) and detach
/// (window nil), so guard on the non-nil case and re-apply each time.
private final class DisableNativeTabBarView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.tabbingMode = .disallowed
    }
}
