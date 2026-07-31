import Combine
import Foundation
import Termini

/// One session: either a local shell, or a VM whose tmux session the app drives
/// itself over tmux's control protocol.
///
/// For a VM there is no tmux *on screen* — the app is the tmux client. Every
/// pane in the session gets its own libghostty surface, shown as a tab in the
/// terminal space, so tmux's windows and splits arrive as native tabs and its
/// status bar and prefix key never come into it. Panes keep running on the VM
/// whichever tab is showing, and a dropped connection reattaches to the same
/// panes.
///
/// Main-actor isolated: the ghostty surfaces and their controllers are, and the
/// rest of this is UI state read straight by the views.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    /// What the session runs when it opens.
    enum Launch {
        /// A local login shell (the plain terminal, no tmux).
        case localShell
        /// Run `bootstrap` on a VM over the provider's transport: `ssh` for
        /// exe.dev, `sprite exec` for sprites.dev. The bootstrap is the tmux
        /// control-mode client, which brings up the session's panes.
        case remote(destination: String, bootstrap: String)
    }

    /// `nonisolated` so `Identifiable` is satisfied off the main actor too.
    nonisolated let id = UUID()

    @Published var title: String
    /// The current working directory. For a local shell it comes from OSC 7;
    /// for a VM from tmux, which swallows OSC 7 and reports the active pane's
    /// path itself.
    @Published var workingDirectory: URL?
    /// True once the session's process has exited (SSH dropped, tmux gone, or
    /// the local shell quit).
    @Published private(set) var isDisconnected = false
    /// What ssh or tmux said on the way out, when they said anything. Without
    /// it a VM that has been deleted, or a tmux that failed to install, looks
    /// exactly like an idle disconnect.
    @Published private(set) var disconnectReason: String?

    /// One tab per tmux pane, in tmux's own window and pane order; exactly one
    /// tab for a local shell.
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var selectedTabID: TerminalTab.ID? {
        didSet {
            guard selectedTabID != oldValue else { return }
            focusSelectedPane()
        }
    }

    /// The SSH destination for VM-backed sessions (nil for local shells). The
    /// diff sidebar uses this to run git over the VM's transport.
    ///
    /// Not fixed for the session's lifetime: a VM that renames itself takes its
    /// hostname with it. See `adopt(vmName:)`.
    @Published private(set) var sshDestination: String?

    /// The provider backing this session — exe.dev or sprites.dev. Drives the
    /// transport, the web/Shelley URLs, and whether rename polling applies.
    /// `nonisolated(unsafe)` because `VMProvider` is a non-Sendable class held
    /// by this main-actor model, read only from the main actor.
    nonisolated(unsafe) let provider: VMProvider

    /// The exe.dev VM backing this session, if any. Needed to delete it.
    @Published private(set) var vmName: String?

    /// The VM's public web URL — the landing page for a new browser tab in this
    /// session. Stored from the VM record at creation rather than derived from
    /// the destination, because a sprites.dev URL carries an org id the
    /// destination alone doesn't.
    @Published private(set) var webURL: String?

    /// True for a session created without a name, whose VM was armed to name
    /// itself from the agent's first prompt. Set once, at creation; a reconnect
    /// leaves it false, the same as arming itself isn't re-decided on reconnect.
    let autoNameArmed: Bool

    /// Right-sidebar sub-tabs belonging to *this* session, so switching
    /// sessions swaps the whole sidebar. The diff tab is permanent.
    @Published var sidebarTabs: [SidebarTab] = [SidebarTab(kind: .diff, title: "Diff")]
    @Published var selectedSidebarTabID: SidebarTab.ID?

    /// Shelley — exe.dev's own web agent — which the default VM image serves on
    /// port 9999. nil for a local shell or a provider that doesn't serve one.
    var shelleyURL: String? {
        guard let destination = sshDestination else { return nil }
        return provider.shelleyURL(forDestination: destination)
    }

    var selectedSidebarTab: SidebarTab? {
        sidebarTabs.first { $0.id == selectedSidebarTabID } ?? sidebarTabs.first
    }

    /// Open a browser sub-tab pointed at this session's instance by default.
    func newBrowserTab() {
        let address = webURL ?? provider.defaultBrowserURL
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

    /// Replaced when the VM is renamed, so a reconnect dials the host that
    /// still exists.
    private var launch: Launch

    /// The local shell's PTY, for `.localShell` sessions.
    private var process: TerminiLocalPTYProcess?
    private var oscScanner = TerminalOSCScanner()

    /// The tmux control-mode client, for VM sessions.
    private var client: TmuxClient?
    /// What each in-flight command's reply is for, oldest first. tmux answers
    /// commands in order and says nothing about which reply is which, so this
    /// queue is what pairs them up.
    private var pendingReplies: [PendingReply] = []
    /// Set while a pane listing is already queued, so a burst of notifications
    /// (one tmux action emits several) costs one `list-panes`, not one each.
    private var refreshQueued = false
    /// The size last reported to tmux. Every report resizes every window in the
    /// session, so an unchanged layout pass must not send one.
    private var reportedSize: (cols: Int, rows: Int)?
    /// The pane tmux last reported as active, so a pane listing that has moved to
    /// a different one — a new window, a split, or a `select-window` run from the
    /// VM — is recognised as a focus change to follow, not a routine refresh.
    private var lastActivePaneID: String?

    private enum PendingReply {
        case panes
        /// A `capture-pane` whose lines restore this pane's screen.
        case capture(paneID: String)
        /// Nothing to do with the reply; only its place in the queue matters.
        case ignored
    }

    init(
        title: String = "Terminal",
        launch: Launch = .localShell,
        provider: VMProvider,
        vmName: String? = nil,
        webURL: String? = nil,
        autoNameArmed: Bool = false
    ) {
        self.title = title
        self.launch = launch
        self.provider = provider
        self.vmName = vmName
        self.autoNameArmed = autoNameArmed
        if case let .remote(destination, _) = launch {
            sshDestination = destination
            self.webURL = webURL ?? provider.webURL(forDestination: destination)
        } else {
            sshDestination = nil
            self.webURL = nil
        }

        start()
    }

    deinit {
        client?.stop()
    }

    // MARK: - Tabs

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// The tab strip is tmux's window list; a local shell has nothing to list.
    var showsTabBar: Bool { sshDestination != nil }

    /// Open another tmux window. tmux announces the new pane, and the tab
    /// appears when it does.
    func newTab() {
        send(TmuxControl.newWindow())
    }

    /// Open a tab showing this VM's Shelley, after the pane tabs. Unlike a pane
    /// tab this one is the app's own, so it appears straight away.
    ///
    /// For a session armed to auto-name, the tab is wired to report its first
    /// prompt back so the VM can name itself — the same rename Claude Code's
    /// hook triggers, since Shelley has no hook of its own.
    func newShelleyTab() {
        guard let address = shelleyURL, let destination = sshDestination else { return }
        let transport = provider.transport(forDestination: destination)
        // `destination` and `transport` are captured by value so the closure
        // need not reach into this main-actor model from WebKit's callback — no
        // `self` to keep alive, no actor to cross.
        let onFirstPrompt: ((String) -> Void)? = autoNameArmed
            ? { prompt in Self.feedRenameScript(transport: transport, prompt: prompt) }
            : nil
        let tab = TerminalTab(
            paneID: nil, title: "Shelley",
            browser: BrowserModel(initialAddress: address, onFirstPrompt: onFirstPrompt))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Feed a Shelley prompt to the on-VM rename script over the terminal's own
    /// transport — the same `{"prompt": …}` payload Claude Code's hook and
    /// Codex's notify deliver. Fire-and-forget: the script forks and detaches,
    /// so this returns at once and never holds up the UI, and its armed/marker
    /// gates still decide whether a rename actually happens.
    private nonisolated static func feedRenameScript(transport: RemoteTransport, prompt: String) {
        Task {
            _ = await RemoteGit.run(
                transport: transport,
                remoteCommand: AutoName.renameCommand(prompt: prompt))
        }
    }

    /// Kill the pane behind a tab. The tab goes when tmux reports the pane gone,
    /// so a refused kill leaves the tab where it was. A Shelley tab has no pane
    /// and is dropped here.
    func closeTab(_ tab: TerminalTab) {
        if tab.isBrowser {
            guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            tabs.remove(at: index)
            if selectedTabID == tab.id {
                // Prefer the tab that took its place, else the last one.
                let next = index < tabs.count ? tabs[index] : tabs.last
                selectedTabID = next?.id
            }
            return
        }
        guard let paneID = tab.paneID else { return }
        send(TmuxControl.killPane(paneID))
    }

    func selectAdjacentTab(offset: Int) {
        let current = tabs.firstIndex { $0.id == selectedTabID }
        guard let index = TabNavigation.index(
            from: current, offset: offset, count: tabs.count)
        else { return }
        selectedTabID = tabs[index].id
    }

    // MARK: - Launching

    private func start() {
        isDisconnected = false
        disconnectReason = nil
        pendingReplies = []
        reportedSize = nil
        lastActivePaneID = nil

        switch launch {
        case .localShell:
            startLocalShell()

        case let .remote(destination, bootstrap):
            // Pane tabs are rebuilt from the pane listing rather than reused: on
            // a reconnect the panes have moved on without us, and each tab
            // restores its pane's screen as it reappears. Shelley tabs aren't
            // tmux's, so a dropped connection is nothing to them.
            tabs = tabs.filter { $0.isBrowser }
            if !tabs.contains(where: { $0.id == selectedTabID }) {
                selectedTabID = nil
            }
            let client = TmuxClient(
                transport: provider.transport(forDestination: destination),
                remoteCommand: bootstrap,
                onEvents: { [weak self] events in
                    // Delivered on the main queue by the client, so this stays
                    // synchronous — hopping again would let a later read's
                    // events overtake an earlier one's.
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        for event in events { self.handle(event) }
                    }
                },
                onExit: { [weak self] message in
                    MainActor.assumeIsolated {
                        self?.disconnected(reason: message)
                    }
                })
            self.client = client
            client.start()
            send(TmuxControl.listPanes(), expecting: .panes)
        }
    }

    /// The plain terminal: one tab whose surface is wired straight to a local
    /// PTY, with no tmux in between.
    private func startLocalShell() {
        // Reuses the existing tab on a restart, so the surface — and with it
        // the scrollback — survives.
        let tab = tabs.first ?? TerminalTab(paneID: nil, title: "Shell")
        tabs = [tab]
        selectedTabID = tab.id

        let process = TerminiLocalPTYProcess()
        process.onOutput = { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
        process.onExit = { [weak self] _ in
            Task { @MainActor in self?.disconnected(reason: nil) }
        }

        // Keystrokes and mouse reports come back out of the surface here, and
        // the PTY is told whenever the surface's cell grid changes size.
        tab.controller.onTransportWrite = { [weak self] data in
            self?.process?.send(data)
        }
        tab.controller.onSizeChange = { [weak self] size in
            self?.process?.resize(to: .init(columns: size.columns, rows: size.rows))
        }

        do {
            try process.start(spec: localShellSpec(), initialSize: initialPTYSize(tab))
            self.process = process
        } catch {
            // Nothing spawned, so nothing will report an exit; say so here.
            self.process = nil
            isDisconnected = true
        }
    }

    /// Local-shell output on its way to the surface, read for the sequences the
    /// UI needs before being handed over untouched. Only a local shell reports
    /// a title or directory this way: tmux consumes OSC before it reaches a
    /// control client.
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
        tabs.first?.controller.processRemoteOutput(data)
    }

    /// OSC 7 reports a `file://host/path` URL; some shells send a bare path.
    private static func directory(from reported: String) -> URL {
        if let url = URL(string: reported), url.isFileURL {
            return URL(fileURLWithPath: url.path)
        }
        return URL(fileURLWithPath: reported)
    }

    private func localShellSpec() -> TerminiProcessSpec {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `-l` makes it a login shell, so the user's profile is sourced.
        return TerminiProcessSpec(
            executableURL: URL(fileURLWithPath: shell),
            arguments: ["-l"],
            environment: Self.inheritedEnvironment,
            workingDirectoryURL: URL(fileURLWithPath: NSHomeDirectory()))
    }

    /// Termini gives the child a PATH of its own choosing; put back the one the
    /// app was launched with so the shell finds the user's tools.
    private static var inheritedEnvironment: [String: String] {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return [:] }
        return ["PATH": path]
    }

    /// The surface's size if it already has one — on reconnect it does, so the
    /// shell starts out matching the pane instead of resizing into it.
    private func initialPTYSize(_ tab: TerminalTab) -> TerminiLocalPTYProcess.Size {
        guard let size = tab.controller.currentSize() else { return .default }
        return .init(columns: size.columns, rows: size.rows)
    }

    /// Follow the VM's own name. A session created without one is named by the
    /// VM itself, from the agent's first prompt (see `AutoName`), and the SSH
    /// host moves with the name.
    ///
    /// The live connection is left running: it is already established, and tmux
    /// is still on the other end of it. Only what a *future* connection needs
    /// changes — along with the title, when the title was the name being
    /// replaced rather than one the user chose.
    ///
    /// Returns whether anything changed, so the workspace persists a real rename
    /// and not every poll.
    @discardableResult
    func adopt(vmName newName: String) -> Bool {
        guard sshDestination != nil, !newName.isEmpty, newName != vmName else { return false }
        let previous = vmName
        vmName = newName
        let destination = provider.destination(forVMName: newName)
        sshDestination = destination
        webURL = provider.webURL(forDestination: destination)
        if case let .remote(_, bootstrap) = launch {
            launch = .remote(destination: destination, bootstrap: bootstrap)
        }
        if title.isEmpty || title == previous {
            title = newName
        }
        return true
    }

    /// Re-run the launch command. Recovers a dropped SSH session without losing
    /// the session tab — the panes are still running on the VM.
    func reconnect() {
        guard isDisconnected else { return }
        start()
    }

    /// A short label for the session strip.
    var displayName: String {
        if !title.isEmpty { return title }
        if let dir = workingDirectory { return dir.lastPathComponent }
        return "Terminal"
    }

    // MARK: - tmux

    private func send(_ command: String, expecting: PendingReply = .ignored) {
        guard let client else { return }
        pendingReplies.append(expecting)
        client.send(command)
    }

    private func handle(_ event: TmuxEvent) {
        switch event {
        case let .output(pane, bytes):
            tab(forPane: pane)?.controller.processRemoteOutput(Data(bytes))
        case .paneListChanged:
            scheduleRefresh()
        case let .reply(reply):
            handle(reply)
        case let .exit(reason):
            client?.stop()
            disconnected(reason: reason)
        }
    }

    private func handle(_ reply: TmuxReply) {
        let expectation: PendingReply = pendingReplies.isEmpty
            ? .ignored : pendingReplies.removeFirst()
        // An error is tmux refusing a command — a pane that died first, say.
        // There is nothing to apply, and its notification will say what is true.
        guard !reply.isError else { return }
        switch expectation {
        case .panes:
            apply(panes: TmuxControl.parsePanes(reply.lines))
        case let .capture(paneID):
            guard let tab = tabs.first(where: { $0.paneID == paneID }) else { return }
            let restore = TmuxControl.restoreScreen(
                lines: reply.lines, cursorX: tab.cursor.x, cursorY: tab.cursor.y)
            tab.controller.processRemoteOutput(Data(restore))
        case .ignored:
            break
        }
    }

    /// Ask for the pane list once per run loop turn: one tmux action emits
    /// several notifications, and they all mean the same thing here.
    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshQueued = false
                guard self.client != nil else { return }
                self.send(TmuxControl.listPanes(), expecting: .panes)
            }
        }
    }

    /// Reconcile the tabs with what tmux says exists: new panes become tabs,
    /// closed ones drop out, and the order follows tmux's windows and panes
    /// rather than the order the app happened to hear about them.
    private func apply(panes: [TmuxPane]) {
        let priorPaneIDs = Set(tabs.compactMap { $0.paneID })
        let existing = Dictionary(tabs.compactMap { tab in tab.paneID.map { ($0, tab) } },
                                  uniquingKeysWith: { first, _ in first })
        var ordered: [TerminalTab] = []
        for pane in panes.sorted(by: { ($0.windowIndex, $0.index) < ($1.windowIndex, $1.index) }) {
            let tab = existing[pane.id] ?? restoredTab(for: pane)
            tab.title = pane.title
            tab.windowID = pane.windowID
            tab.cursor = (pane.cursorX, pane.cursorY)
            ordered.append(tab)
        }
        // The listing can't speak for Shelley tabs, which keep their place after
        // the panes.
        tabs = ordered + tabs.filter { $0.isBrowser }

        let active = panes.first { $0.isActive }?.id
        if !tabs.contains(where: { $0.id == selectedTabID }) {
            // The selected tab dropped out of the listing — its pane was closed,
            // or a reconnect is rebuilding the panes — so fall in behind tmux's
            // active pane. A Shelley tab's pane ID is nil, so it must not stand
            // in for a listing that named no active pane.
            selectedTabID = tabs.first { $0.paneID != nil && $0.paneID == active }?.id
                ?? tabs.first?.id
            lastActivePaneID = active
        } else if let active, !priorPaneIDs.isEmpty, active != lastActivePaneID,
                  let tab = tabs.first(where: { $0.paneID == active }) {
            // tmux moved to a different active pane — a new window, a split, or a
            // `select-window` run from the VM — so follow it: the newly current
            // tab takes focus instead of opening in the background. Skipped on a
            // fresh connect or reconnect (no prior panes), where the branch above
            // — or a surviving Shelley tab — settles the selection.
            selectedTabID = tab.id
            lastActivePaneID = active
        }
        // tmux consumes OSC 7, so the sidebar's idea of the directory can only
        // come from here.
        let selected = selectedTab?.paneID
        if let path = panes.first(where: { $0.id == selected })?.currentPath, !path.isEmpty {
            workingDirectory = URL(fileURLWithPath: path)
        }
    }

    /// A tab for a pane the app hasn't seen before, with its screen restored:
    /// tmux replays nothing on attach, so a pane that was already running would
    /// otherwise show up blank until whatever is in it redrew.
    private func restoredTab(for pane: TmuxPane) -> TerminalTab {
        let tab = makeTab(paneID: pane.id, title: pane.title)
        tab.cursor = (pane.cursorX, pane.cursorY)
        send(TmuxControl.capturePane(pane.id), expecting: .capture(paneID: pane.id))
        return tab
    }

    /// The tab showing `pane`, created on the spot if output arrived before the
    /// listing that describes it. Dropping those bytes would lose the first
    /// thing a new window prints, which is its prompt.
    private func tab(forPane pane: String) -> TerminalTab? {
        if let tab = tabs.first(where: { $0.paneID == pane }) { return tab }
        guard sshDestination != nil else { return nil }
        let tab = makeTab(paneID: pane, title: "")
        tabs.append(tab)
        if selectedTabID == nil { selectedTabID = tab.id }
        scheduleRefresh()
        return tab
    }

    private func makeTab(paneID: String, title: String) -> TerminalTab {
        let tab = TerminalTab(paneID: paneID, title: title)
        // Keystrokes and mouse reports leaving this pane's surface go back to
        // that pane, byte for byte.
        tab.controller.onTransportWrite = { [weak self] data in
            guard let self else { return }
            for command in TmuxControl.sendKeys(pane: paneID, bytes: Array(data)) {
                self.send(command)
            }
        }
        // Every surface shares the window's terminal area, so only the visible
        // one's size is worth telling tmux about.
        tab.controller.onSizeChange = { [weak self, weak tab] size in
            guard let self, let tab, self.selectedTab === tab else { return }
            self.report(cols: size.columns, rows: size.rows)
        }
        return tab
    }

    /// Point tmux at the pane the user just switched to, so another attached
    /// client — and anything that acts on the "current" pane — agrees with
    /// what's on screen.
    private func focusSelectedPane() {
        guard let tab = selectedTab, let paneID = tab.paneID else { return }
        // A tab built from output alone doesn't know its window yet; the next
        // pane listing fills that in.
        if let windowID = tab.windowID {
            for command in TmuxControl.selectPane(window: windowID, pane: paneID) {
                send(command)
            }
        }
        if let size = tab.controller.currentSize() {
            report(cols: size.columns, rows: size.rows)
        }
    }

    /// tmux sizes the session's windows to fit its client, and a control client
    /// has no size at all until it says so.
    private func report(cols: Int, rows: Int) {
        guard client != nil, cols > 0, rows > 0 else { return }
        let size = (cols: cols, rows: rows)
        if let reportedSize, reportedSize == size { return }
        reportedSize = size
        send(TmuxControl.refreshClient(cols: cols, rows: rows))
    }

    private func disconnected(reason: String?) {
        client = nil
        pendingReplies = []
        isDisconnected = true
        disconnectReason = reason
    }
}
