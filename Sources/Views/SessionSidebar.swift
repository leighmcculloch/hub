import SwiftUI

/// The left-hand vertical tab strip: one row per terminal session, plus a button
/// to open a new one.
struct SessionSidebar: View {
    @ObservedObject var workspace: Workspace

    /// Set when the user clicks a tab's ✕; deleting a VM is irreversible so it
    /// is confirmed first.
    @State private var sessionPendingDeletion: TerminalSession?
    @State private var isHoveringNewSession = false

    /// Nothing to show at all. Distinct from "still loading": during the first
    /// VM fetch we keep the EXISTING header on screen so the sidebar doesn't
    /// flash an empty state for an account that does have VMs.
    private var isEmpty: Bool {
        workspace.sessions.isEmpty && workspace.unopenedVMs.isEmpty && !workspace.loadingVMs
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                emptyState
            } else {
                ScrollView { list }
            }

            Divider()

            newSessionButton
        }
        // Width is owned by ContentView so the divider can resize it.
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .confirmationDialog(
            "Delete VM \(sessionPendingDeletion?.vmName ?? "")?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete VM", role: .destructive) {
                if let session = sessionPendingDeletion {
                    sessionPendingDeletion = nil
                    Task { await workspace.deleteSession(session) }
                }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("This destroys the VM and its disk. Anything not pushed is lost.")
        }
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if !workspace.sessions.isEmpty {
                SectionHeader(title: "SESSIONS")
            }

            ForEach(workspace.sessions) { session in
                SessionTab(
                    session: session,
                    isSelected: session.id == workspace.selectedSessionID,
                    onSelect: { workspace.selectedSessionID = session.id },
                    onCloseTab: { workspace.closeSession(session) },
                    onDelete: {
                        if session.vmName != nil {
                            sessionPendingDeletion = session
                        } else {
                            // Local shell: nothing to destroy.
                            workspace.closeSession(session)
                        }
                    }
                )
            }

            // Existing VMs on the account that aren't open yet. Shown so a
            // previous session can be resumed; clicking connects.
            if !workspace.unopenedVMs.isEmpty || workspace.loadingVMs {
                SectionHeader(title: "EXISTING", isLoading: workspace.loadingVMs)
                    .padding(.top, workspace.sessions.isEmpty ? 0 : 10)

                ForEach(workspace.unopenedVMs) { vm in
                    AvailableVMRow(vm: vm) { workspace.reopen(vm: vm) }
                }
            }
        }
        .padding(6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Start one on a fresh VM with ⌘T.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var newSessionButton: some View {
        Button(action: { workspace.presentingNewSession = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("New Session")
                Spacer(minLength: 0)
                // The ⌘T shortcut is otherwise invisible: this button carries it
                // but lives outside any menu.
                Text("⌘T")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHoveringNewSession ? Color.primary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(6)
        .keyboardShortcut("t", modifiers: .command)
        .onHover { isHoveringNewSession = $0 }
        .help("Start a new session on a fresh VM (⌘T)")
    }
}

/// Small uppercase group label separating live sessions from reopenable VMs.
private struct SectionHeader: View {
    let title: String
    var isLoading = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            if isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A VM that exists on the account but has no tab open. Dimmed relative to live
/// sessions, and connects on click.
private struct AvailableVMRow: View {
    let vm: ExeVM
    let onOpen: () -> Void

    @State private var isHovering = false

    private var name: String { vm.vm_name ?? vm.ssh_dest ?? "unknown" }
    private var isRunning: Bool { vm.status == "running" }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                // Same leading width as SessionTab's icon so both lists' labels
                // line up down the sidebar.
                Circle()
                    .fill(isRunning ? Color.green.opacity(0.7) : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .frame(width: 14)

                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if !isRunning, let status = vm.status {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    // Kept in the layout so the name doesn't shift on hover.
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .help("Connect to \(name)")
        .accessibilityLabel(Text("\(name), \(vm.status ?? "unknown status"), not open"))
        .accessibilityHint(Text("Connects to this VM in a new tab"))
    }
}

private struct SessionTab: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    /// Close the tab but leave the VM running.
    let onCloseTab: () -> Void
    /// The ✕ affordance: destroys the VM (after confirmation) for VM-backed
    /// tabs, or just closes a local shell.
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        // The row is a Button so it takes keyboard focus and is announced as
        // one; the trailing controls sit *beside* it rather than nested inside,
        // because buttons within a button's label don't reliably take clicks.
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    icon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(session.isDisconnected ? Color.secondary : Color.primary)
                        subtitle
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.displayName)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            if session.isDisconnected {
                // Reconnection is otherwise only attempted when the app regains
                // focus, so offer it explicitly and permanently (not on hover).
                Button(action: { session.reconnect() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.orange)
                .help("Reconnect")
                .accessibilityLabel(Text("Reconnect \(session.displayName)"))
            }

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Kept in the layout at zero opacity so rows don't reflow on hover;
            // also shown while selected as a hint that the control is there.
            .opacity(isHovering || isSelected ? 1 : 0)
            .help(session.vmName == nil ? "Close tab" : "Delete VM…")
            .accessibilityLabel(Text(session.vmName == nil ? "Close tab" : "Delete VM"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        // A leading bar makes the selected tab readable at a glance even when
        // the accent tint is subtle against the material background.
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 14)
                    .padding(.leading, 1)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            if session.isDisconnected {
                Button("Reconnect") { session.reconnect() }
            }
            // Closing the tab and destroying the VM are very different things;
            // the ✕ only offers the destructive one.
            Button("Close Tab") { onCloseTab() }
            if session.vmName != nil {
                Divider()
                Button("Delete VM…", role: .destructive) { onDelete() }
            }
        }
    }

    private var icon: some View {
        Image(systemName: session.isDisconnected ? "exclamationmark.triangle.fill" : "terminal")
            .font(.system(size: 11))
            .foregroundStyle(iconColor)
            // Fixed slot so names align regardless of which symbol is showing.
            .frame(width: 14)
    }

    private var iconColor: Color {
        if session.isDisconnected { return .orange }
        return isSelected ? .accentColor : .secondary
    }

    /// The process exiting is the more urgent fact, so it displaces the path.
    @ViewBuilder
    private var subtitle: some View {
        if session.isDisconnected {
            Text("Disconnected")
                .font(.system(size: 10))
                .foregroundStyle(Color.orange)
        } else if let dir = session.workingDirectory {
            Text(dir.path)
                .lineLimit(1)
                .truncationMode(.head)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }

    private var accessibilityLabel: String {
        var label = session.displayName
        if session.isDisconnected { label += ", disconnected" }
        if let dir = session.workingDirectory { label += ", \(dir.lastPathComponent)" }
        return label
    }
}
