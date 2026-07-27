import Combine
import Foundation
import Termini

/// One terminal tab: a libghostty surface driven by a local PTY, plus the
/// observable state the UI binds to (its title and current working directory).
///
/// Main-actor isolated: the ghostty surface and its controller are, and the
/// rest of this is UI state read straight by the views.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    /// What the terminal runs when the tab opens.
    enum Launch {
        /// A local login shell (the plain terminal).
        case localShell
        /// SSH into `destination` and run `bootstrap` as the remote command
        /// (setup script + git clone, then an interactive login shell).
        case ssh(destination: String, bootstrap: String)
    }

    /// `nonisolated` so `Identifiable` is satisfied off the main actor too.
    nonisolated let id = UUID()

    @Published var title: String
    /// The shell's current working directory, updated from OSC 7. For SSH tabs
    /// this reflects the remote path.
    @Published var workingDirectory: URL?
    /// True once the underlying process has exited (SSH dropped or shell quit).
    @Published private(set) var isDisconnected = false

    /// The terminal's transport end. `TerminiTerminalView` binds to it to get a
    /// live ghostty surface; `start()` wires the PTY to the other side.
    let controller: TerminiTerminalController

    /// The SSH destination for VM-backed tabs (nil for local shells). The diff
    /// sidebar uses this to run git over SSH against the VM.
    let sshDestination: String?

    /// The exe.dev VM backing this tab, if any. Needed to delete it.
    let vmName: String?

    /// Right-sidebar sub-tabs belonging to *this* session, so switching
    /// sessions swaps the whole sidebar. The diff tab is permanent.
    @Published var sidebarTabs: [SidebarTab] = [SidebarTab(kind: .diff, title: "Diff")]
    @Published var selectedSidebarTabID: SidebarTab.ID?

    /// The VM's public HTTPS endpoint — its SSH host over https. The landing
    /// page for a new browser tab in this session.
    var webURL: String? {
        sshDestination.map { "https://\($0)" }
    }

    var selectedSidebarTab: SidebarTab? {
        sidebarTabs.first { $0.id == selectedSidebarTabID } ?? sidebarTabs.first
    }

    /// Open a browser sub-tab pointed at this session's instance by default.
    func newBrowserTab() {
        let address = webURL ?? "https://exe.dev"
        let browser = BrowserModel(initialAddress: address)
        let host = BrowserModel.url(from: address)?.host ?? "Browser"
        let tab = SidebarTab(kind: .browser, title: host, browser: browser)
        sidebarTabs.append(tab)
        selectedSidebarTabID = tab.id
    }

    func closeSidebarTab(_ tab: SidebarTab) {
        // The diff tab is permanent; there'd be no way to get it back.
        guard tab.kind != .diff else { return }
        guard let index = sidebarTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        sidebarTabs.remove(at: index)
        if selectedSidebarTabID == tab.id {
            // Prefer the tab that took its place, else the last one.
            let next = index < sidebarTabs.count ? sidebarTabs[index] : sidebarTabs.last
            selectedSidebarTabID = next?.id
        }
    }

    private let launch: Launch
    private var process: TerminiLocalPTYProcess?
    private var oscScanner = TerminalOSCScanner()

    init(title: String = "Terminal", launch: Launch = .localShell, vmName: String? = nil) {
        self.title = title
        self.launch = launch
        self.vmName = vmName
        controller = TerminiTerminalController()
        if case let .ssh(destination, _) = launch {
            sshDestination = destination
        } else {
            sshDestination = nil
        }

        // Keystrokes and mouse reports come back out of the surface here, and
        // the PTY is told whenever the surface's cell grid changes size.
        controller.onTransportWrite = { [weak self] data in
            self?.process?.send(data)
        }
        controller.onSizeChange = { [weak self] size in
            self?.process?.resize(to: .init(columns: size.columns, rows: size.rows))
        }

        start()
    }

    private func start() {
        isDisconnected = false

        let process = TerminiLocalPTYProcess()
        process.onOutput = { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
        process.onExit = { [weak self] _ in
            Task { @MainActor in self?.isDisconnected = true }
        }

        do {
            try process.start(spec: processSpec(), initialSize: initialPTYSize())
            self.process = process
        } catch {
            // Nothing spawned, so nothing will report an exit; say so here.
            self.process = nil
            isDisconnected = true
        }
    }

    /// Terminal output on its way to the surface, read for the sequences the UI
    /// needs before being handed over untouched.
    private func receive(_ data: Data) {
        for event in oscScanner.scan(data) {
            switch event {
            case let .title(reported):
                // Prefer an explicit tab title (e.g. the session name); fall
                // back to the terminal-reported one only when we lack one.
                if title.isEmpty { title = reported }
            case let .workingDirectory(reported):
                workingDirectory = Self.directory(from: reported)
            }
        }
        controller.processRemoteOutput(data)
    }

    /// OSC 7 reports a `file://host/path` URL; some shells send a bare path.
    private static func directory(from reported: String) -> URL {
        if let url = URL(string: reported), url.isFileURL {
            return URL(fileURLWithPath: url.path)
        }
        return URL(fileURLWithPath: reported)
    }

    private func processSpec() -> TerminiProcessSpec {
        let home = URL(fileURLWithPath: NSHomeDirectory())

        switch launch {
        case .localShell:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            // `-l` makes it a login shell, so the user's profile is sourced.
            return TerminiProcessSpec(
                executableURL: URL(fileURLWithPath: shell),
                arguments: ["-l"],
                environment: Self.inheritedEnvironment,
                workingDirectoryURL: home)

        case let .ssh(destination, bootstrap):
            // `-t` forces a remote PTY; accept-new avoids an interactive
            // host-key prompt on first connect. The ControlMaster options (shared
            // with RemoteGit) make this the multiplex master, so the diff
            // sidebar's git-over-SSH calls reuse this one connection. `bootstrap`
            // is passed as the single remote command argument.
            var args = RemoteGit.sshControlArgs(for: destination)
            args += [
                "-t",
                "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=10", // retry while the VM finishes booting
                "-o", "ServerAliveInterval=30",
                destination,
                bootstrap,
            ]
            return TerminiProcessSpec(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: args,
                environment: Self.inheritedEnvironment,
                workingDirectoryURL: home)
        }
    }

    /// Termini gives the child a PATH of its own choosing; put back the one the
    /// app was launched with so the shell — and `ssh` — find the user's tools.
    private static var inheritedEnvironment: [String: String] {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return [:] }
        return ["PATH": path]
    }

    /// The surface's size if it already has one — on reconnect it does, so the
    /// remote shell starts out matching the pane instead of resizing into it.
    private func initialPTYSize() -> TerminiLocalPTYProcess.Size {
        guard let size = controller.currentSize() else { return .default }
        return .init(columns: size.columns, rows: size.rows)
    }

    /// Re-run the launch command against this same surface. Used to recover a
    /// dropped SSH session without losing the tab.
    func reconnect() {
        guard isDisconnected else { return }
        start()
    }

    /// A short label for the tab strip.
    var displayName: String {
        if !title.isEmpty { return title }
        if let dir = workingDirectory { return dir.lastPathComponent }
        return "Terminal"
    }
}
