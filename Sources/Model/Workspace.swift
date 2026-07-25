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

    /// Sub-tabs of the right sidebar. The diff tab always exists; browser tabs
    /// are added by the user.
    @Published var sidebarTabs: [SidebarTab] = [SidebarTab(kind: .diff, title: "Diff")]
    @Published var selectedSidebarTabID: SidebarTab.ID?

    let config = AppConfig.shared
    let exe: ExeService

    init() {
        exe = ExeService(client: ExeClient(tokenProvider: { AppConfig.shared.effectiveToken }))
        selectedSidebarTabID = sidebarTabs.first?.id
        // Start empty: a new tab provisions a VM, which needs the repo picker.
    }

    var selectedSidebarTab: SidebarTab? {
        sidebarTabs.first { $0.id == selectedSidebarTabID } ?? sidebarTabs.first
    }

    /// The VM's public HTTPS endpoint, which is its SSH host over https. Used as
    /// the landing page for a new browser tab.
    var selectedSessionWebURL: String? {
        selectedSession?.sshDestination.map { "https://\($0)" }
    }

    /// Open a browser sub-tab in the right sidebar, pointed at the current
    /// session's instance by default.
    func newBrowserTab() {
        let address = selectedSessionWebURL ?? "https://exe.dev"
        let browser = BrowserModel(initialAddress: address)
        let host = BrowserModel.url(from: address)?.host ?? "Browser"
        let tab = SidebarTab(kind: .browser, title: host, browser: browser)
        sidebarTabs.append(tab)
        selectedSidebarTabID = tab.id
        // A browser tab is useless behind a hidden sidebar.
        showDiffSidebar = true
    }

    func closeSidebarTab(_ tab: SidebarTab) {
        // The diff tab is permanent; there'd be no way to get it back.
        guard tab.kind != .diff else { return }
        guard let index = sidebarTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        sidebarTabs.remove(at: index)
        if selectedSidebarTabID == tab.id {
            selectedSidebarTabID = sidebarTabs[safe: index]?.id ?? sidebarTabs.last?.id
        }
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
    func addSession(title: String, launch: TerminalSession.Launch, vmName: String? = nil) {
        let session = TerminalSession(title: title, launch: launch, vmName: vmName)
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
            repos: [],
            startCommand: config.data.startCommand
        )
        addSession(
            title: vm.vm_name ?? destination,
            launch: .ssh(destination: destination, bootstrap: bootstrap),
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
