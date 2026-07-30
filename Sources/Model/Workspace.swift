import Combine
import Foundation
import SwiftUI

/// Top-level app state: the terminal sessions shown as vertical tabs, plus the
/// exe.dev service used to provision VM-backed tabs. Main-actor isolated, like
/// the sessions it owns.
@MainActor
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

    /// Set when the user asks to delete a session (tab ✕ or ⌘D); deleting a VM
    /// is irreversible, so it is confirmed before `deleteSession` runs. Held on
    /// the workspace rather than the sidebar so ⌘D can arm it from the menu and
    /// the confirmation can present even with the sidebar hidden.
    @Published var sessionPendingDeletion: TerminalSession?

    /// VMs that exist on the exe.dev account. Listed in the sidebar at launch so
    /// a previous session can be reopened; none is connected until clicked.
    @Published var availableVMs: [ExeVM] = []
    @Published var loadingVMs = false

    /// The signed-in GitHub account, used to seed git config on new VMs.
    @Published var githubUser: GitHubUser?

    let config = AppConfig.shared
    // Assigned only by the nonisolated init below, as `SessionProvisioner` does,
    // so init doesn't have to cross into the main actor to store them.
    nonisolated(unsafe) let exe: ExeService
    nonisolated(unsafe) private let sessionStore: SessionStore
    /// Forwards each session's changes as a change to the workspace. A session's
    /// tabs come and go on tmux's schedule, and the terminal host — which mounts
    /// the surfaces for *all* sessions — only re-runs when the workspace itself
    /// says something changed.
    private var sessionObservers: [AnyCancellable] = []

    /// Nonisolated so the token closure below isn't inferred main-actor
    /// isolated: `ExeClient` calls it from its request path, off the main actor.
    nonisolated init(sessionStore: SessionStore = .shared) {
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

    // MARK: - Terminal tabs (tmux windows within the selected session)

    func newTerminalTab() {
        selectedSession?.newTab()
    }

    func closeSelectedTerminalTab() {
        guard let session = selectedSession, let tab = session.selectedTab else { return }
        session.closeTab(tab)
    }

    func selectAdjacentTerminalTab(offset: Int) {
        selectedSession?.selectAdjacentTab(offset: offset)
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
    func loadGitHubUser() async {
        githubUser = await GitHubRepos.currentUser()
    }

    /// The commit identity to seed on a VM, if the GitHub user is known.
    var gitIdentity: (name: String, email: String)? {
        githubUser.map { ($0.displayName, $0.noreplyEmail) }
    }

    /// Refresh the list of existing VMs. Deliberately does *not* connect to or
    /// select any of them.
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
        observeSessions()
        selectedSessionID = session.id
        if persist { persistSessions() }
    }

    private func observeSessions() {
        sessionObservers = sessions.map { session in
            session.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    /// The bootstrap run when connecting to an already-provisioned VM. Repos
    /// are already cloned, so it only re-applies the idempotent setup steps.
    ///
    /// Auto-naming isn't armed here — that is a decision made once, when the VM
    /// is created, and the VM has been carrying it ever since. Its wiring is
    /// re-applied regardless, by the bootstrap itself.
    private func reconnectBootstrap() -> String {
        let environment = config.data.selectedEnvironment
        return Bootstrap.command(
            setupScript: environment.setupScript,
            claudeSettings: config.data.claudeSettings,
            repos: [],
            startCommand: environment.startCommand,
            gitIdentity: gitIdentity,
            model: config.data.model
        )
    }

    /// Restore the tabs that were open when the app last quit. VMs that no
    /// longer exist are dropped; see `SessionStore.restorable`.
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
        observeSessions()
        if selectedSessionID == session.id {
            selectedSessionID = sessions[safe: index]?.id ?? sessions.last?.id
        }
        persistSessions()
    }

    /// Destroy a VM that has no tab open, without connecting to it first.
    /// Irreversible — the VM's disk and anything uncommitted on it are lost.
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

    /// Arm the confirmation to delete the selected session (⌘D). A VM-backed
    /// session is irreversible — the VM and its disk go — so it routes through
    /// `sessionPendingDeletion` and the confirmation dialog. A local shell has
    /// nothing to destroy, so it just closes.
    func deleteSelectedSession() {
        guard let selected = selectedSession else { return }
        if selected.vmName != nil {
            sessionPendingDeletion = selected
        } else {
            closeSession(selected)
        }
    }

    /// Run the pending deletion after the confirmation dialog is accepted.
    func confirmPendingDeletion() {
        guard let session = sessionPendingDeletion else { return }
        sessionPendingDeletion = nil
        Task { await deleteSession(session) }
    }

    /// Keep the sidebar and the stored workspace on the names the VMs actually
    /// have. A session created without a name is named by its VM, from the
    /// agent's first prompt (see `AutoName`), and nothing tells the app when.
    ///
    /// Runs for as long as the window is open; each pass is one cheap command
    /// per connected VM over the connection the terminal already holds.
    func followVMRenames() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: RemoteVM.pollInterval)
            if Task.isCancelled { break }
            await adoptVMRenames()
        }
    }

    /// Ask each connected VM its name and take it. A disconnected session is
    /// skipped: its connection is gone, so there is nothing to ask through, and
    /// the name it last had is the best guess for reconnecting.
    private func adoptVMRenames() async {
        var renamed = false
        for session in sessions where !session.isDisconnected {
            guard let destination = session.sshDestination,
                  let name = await RemoteVM.name(destination: destination)
            else { continue }
            if session.adopt(vmName: name) { renamed = true }
        }
        guard renamed else { return }
        persistSessions()
        // The sidebar's list of VMs to reopen still holds the old name.
        await loadAvailableVMs()
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
