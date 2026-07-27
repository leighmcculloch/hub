import Foundation
import SwiftUI

/// Top-level app state: the terminal sessions shown as vertical tabs, plus the
/// exe.dev service used to provision VM-backed tabs.
final class Workspace: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    /// Persisted on change, so reopening the app lands on the tab you left.
    /// A `didSet` rather than a call at each assignment: the sidebar sets this
    /// directly, so any scheme relying on call sites would miss that one.
    @Published var selectedSessionID: TerminalSession.ID? {
        didSet {
            guard selectedSessionID != oldValue else { return }
            persistSessions()
        }
    }
    @Published var showSessionSidebar: Bool = true
    @Published var showDiffSidebar: Bool = true
    /// Whether the new-session (repo picker) sheet is presented.
    @Published var presentingNewSession: Bool = false

    /// VMs that exist on the exe.dev account. Listed in the sidebar at launch so
    /// a previous session can be reopened; none is connected until clicked.
    @Published var availableVMs: [ExeVM] = []
    @Published var loadingVMs = false

    /// The signed-in GitHub account, used to seed git config on new VMs.
    @Published var githubUser: GitHubUser?

    let config = AppConfig.shared
    let exe: ExeService
    private let sessionStore: SessionStore

    init(sessionStore: SessionStore = .shared) {
        self.sessionStore = sessionStore
        exe = ExeService(client: ExeClient(tokenProvider: { AppConfig.shared.effectiveToken }))
        // Start empty: a new tab provisions a VM, which needs the repo picker.
    }

    /// The VM's public HTTPS endpoint for the selected session.
    var selectedSessionWebURL: String? { selectedSession?.webURL }

    /// Open a browser sub-tab in the selected session's sidebar.
    func newBrowserTab() {
        guard let session = selectedSession else { return }
        session.newBrowserTab()
        // A browser tab is useless behind a hidden sidebar.
        showDiffSidebar = true
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

    /// Look up the GitHub account once, for the VM's commit identity.
    @MainActor
    func loadGitHubUser() async {
        githubUser = await GitHubRepos.currentUser()
    }

    /// The commit identity to seed on a VM, if the GitHub user is known.
    var gitIdentity: (name: String, email: String)? {
        githubUser.map { ($0.displayName, $0.noreplyEmail) }
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
    func addSession(
        title: String,
        launch: TerminalSession.Launch,
        vmName: String? = nil,
        persist: Bool = true
    ) {
        let session = TerminalSession(title: title, launch: launch, vmName: vmName)
        sessions.append(session)
        selectedSessionID = session.id
        if persist { persistSessions() }
    }

    /// The bootstrap run when connecting to an already-provisioned VM. Repos
    /// are already cloned, so it only re-applies the idempotent setup steps.
    private func reconnectBootstrap() -> String {
        Bootstrap.command(
            setupScript: config.data.setupScript,
            claudeSettings: config.data.claudeSettings,
            repos: [],
            startCommand: config.data.startCommand,
            gitIdentity: gitIdentity
        )
    }

    /// Restore the tabs that were open when the app last quit. VMs that no
    /// longer exist are dropped; see `SessionStore.restorable`.
    @MainActor
    func restoreSessions() {
        guard sessions.isEmpty else { return }
        let stored = sessionStore.load()
        let known = Set(availableVMs.compactMap(\.ssh_dest))
        let restorable = SessionStore.restorable(
            persisted: stored.sessions, knownDestinations: known)
        guard !restorable.isEmpty else { return }

        for entry in restorable {
            addSession(
                title: entry.title,
                launch: .ssh(destination: entry.destination, bootstrap: reconnectBootstrap()),
                vmName: entry.vmName,
                persist: false
            )
        }
        let selected = SessionStore.restorableSelection(stored.selected, in: restorable)
        selectedSessionID = sessions.first { $0.sshDestination == selected }?.id
            ?? sessions.first?.id
        persistSessions()
    }

    /// Write the open VM tabs out. Local shells aren't restorable, so they're
    /// left out rather than reopening as something they weren't.
    private func persistSessions() {
        sessionStore.save(PersistedWorkspace(
            sessions: sessions.compactMap { session in
                guard let destination = session.sshDestination else { return nil }
                return PersistedSession(
                    destination: destination, title: session.title, vmName: session.vmName)
            },
            selected: selectedSession?.sshDestination))
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
        addSession(
            title: vm.vm_name ?? destination,
            launch: .ssh(destination: destination, bootstrap: reconnectBootstrap()),
            vmName: vm.vm_name
        )
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
        persistSessions()
    }

    /// Destroy a VM that has no tab open, without connecting to it first.
    /// Irreversible — the VM's disk and anything uncommitted on it are lost.
    @MainActor
    func deleteVM(_ vm: ExeVM) async {
        guard let name = vm.vm_name else { return }
        // Drop it from the sidebar immediately; the refresh below is the
        // authority if the delete actually failed.
        availableVMs.removeAll { $0.vm_name == name }
        try? await exe.deleteVM(name: name)
        await loadAvailableVMs()
    }

    /// Close the tab *and* destroy the backing VM. Irreversible — the VM's disk
    /// and anything uncommitted on it are lost.
    @MainActor
    func deleteSession(_ session: TerminalSession) async {
        let name = session.vmName
        closeSession(session)
        if let name {
            try? await exe.deleteVM(name: name)
            await loadAvailableVMs()
        }
    }

    /// Select the tab bound to ⌘1…⌘9.
    func selectSession(shortcut number: Int) {
        guard let index = TabNavigation.index(forShortcut: number, count: sessions.count)
        else { return }
        selectedSessionID = sessions[index].id
    }

    /// Move the selection forwards or backwards through the tabs, wrapping.
    func selectAdjacentSession(offset: Int) {
        let current = sessions.firstIndex { $0.id == selectedSessionID }
        guard let index = TabNavigation.index(
            from: current, offset: offset, count: sessions.count)
        else { return }
        selectedSessionID = sessions[index].id
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
