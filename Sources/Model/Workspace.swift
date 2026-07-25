import Foundation
import SwiftUI

/// Top-level app state: the terminal sessions shown as vertical tabs, plus the
/// exe.dev service used to provision VM-backed tabs.
final class Workspace: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedSessionID: TerminalSession.ID?
    @Published var showSessionSidebar: Bool = true
    @Published var showDiffSidebar: Bool = true
    /// Whether the new-session (repo picker) sheet is presented.
    @Published var presentingNewSession: Bool = false

    /// VMs that exist on the exe.dev account. Listed in the sidebar at launch so
    /// a previous session can be reopened; none is connected until clicked.
    @Published var availableVMs: [ExeVM] = []
    @Published var loadingVMs = false

    let config = AppConfig.shared
    let exe: ExeService

    init() {
        exe = ExeService(client: ExeClient(tokenProvider: { AppConfig.shared.effectiveToken }))
        // Start empty: a new tab provisions a VM, which needs the repo picker.
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// Known VMs that aren't already open as a tab.
    var unopenedVMs: [ExeVM] {
        let open = Set(sessions.compactMap(\.sshDestination))
        return availableVMs.filter { vm in
            guard let destination = vm.ssh_dest else { return true }
            return !open.contains(destination)
        }
    }

    /// Refresh the list of existing VMs. Deliberately does *not* connect to or
    /// select any of them.
    @MainActor
    func loadAvailableVMs() async {
        guard !config.effectiveToken.isEmpty else { return }
        loadingVMs = true
        availableVMs = (try? await exe.listVMs()) ?? []
        loadingVMs = false
    }

    func makeProvisioner() -> SessionProvisioner {
        SessionProvisioner(exe: exe, config: config)
    }

    /// Open a new tab from a provisioned launch descriptor.
    func addSession(title: String, launch: TerminalSession.Launch) {
        let session = TerminalSession(title: title, launch: launch)
        sessions.append(session)
        selectedSessionID = session.id
    }

    /// Reconnect to an existing exe.dev VM, running the same bootstrap so the
    /// setup script and clones are re-applied idempotently.
    func reopen(vm: ExeVM) {
        let destination = vm.ssh_dest ?? "\(vm.vm_name ?? "").exe.xyz"
        guard !destination.isEmpty else { return }
        // If this VM already has a tab, just focus it.
        if let existing = sessions.first(where: { $0.sshDestination == destination }) {
            selectedSessionID = existing.id
            return
        }
        let bootstrap = Bootstrap.command(
            setupScript: config.data.setupScript,
            claudeSettings: config.data.claudeSettings,
            repos: []
        )
        addSession(title: vm.vm_name ?? destination, launch: .ssh(destination: destination, bootstrap: bootstrap))
    }

    /// A plain local shell tab (no VM) — handy when offline or without a token.
    func newLocalSession() {
        addSession(title: "Local", launch: .localShell)
    }

    func closeSession(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if selectedSessionID == session.id {
            selectedSessionID = sessions[safe: index]?.id ?? sessions.last?.id
        }
    }

    func closeSelectedSession() {
        if let selected = selectedSession {
            closeSession(selected)
        }
    }

    /// Re-establish any dropped SSH sessions. Called when the app regains focus.
    func reconnectDisconnectedSessions() {
        for session in sessions where session.isDisconnected && session.sshDestination != nil {
            session.reconnect()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
