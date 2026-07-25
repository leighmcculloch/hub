import SwiftUI

/// The left-hand vertical tab strip: one row per terminal session, plus a button
/// to open a new one.
struct SessionSidebar: View {
    @ObservedObject var workspace: Workspace

    /// Set when the user clicks a tab's ✕; deleting a VM is irreversible so it
    /// is confirmed first.
    @State private var sessionPendingDeletion: TerminalSession?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.sessions) { session in
                        SessionTab(
                            session: session,
                            isSelected: session.id == workspace.selectedSessionID,
                            onSelect: { workspace.selectedSessionID = session.id },
                            onClose: {
                                if session.vmName != nil {
                                    sessionPendingDeletion = session
                                } else {
                                    // Local shell: nothing to destroy.
                                    workspace.closeSession(session)
                                }
                            }
                        )
                    }

                    // Existing VMs on the account that aren't open yet. Shown so
                    // a previous session can be resumed; clicking connects.
                    if !workspace.unopenedVMs.isEmpty {
                        HStack(spacing: 4) {
                            Text("EXISTING")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            if workspace.loadingVMs {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(.top, workspace.sessions.isEmpty ? 2 : 10)
                        .padding(.horizontal, 8)

                        ForEach(workspace.unopenedVMs) { vm in
                            AvailableVMRow(vm: vm) { workspace.reopen(vm: vm) }
                        }
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
}

/// A VM that exists on the account but has no tab open. Dimmed relative to live
/// sessions, and connects on click.
private struct AvailableVMRow: View {
    let vm: ExeVM
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.status == "running" ? Color.green.opacity(0.7) : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .padding(.leading, 3)

            Text(vm.vm_name ?? vm.ssh_dest ?? "unknown")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isHovering {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .help("Connect to \(vm.vm_name ?? "this VM")")
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
