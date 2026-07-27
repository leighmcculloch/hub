import AppKit
import Combine
import Foundation
import SwiftTerm

/// One session: either a local shell, or a VM whose tmux session the app drives
/// itself over tmux's control protocol.
///
/// For a VM there is no tmux *on screen* — the app is the tmux client. Every
/// pane in the session is its own terminal view, shown as a tab in the terminal
/// space, so tmux's windows and splits arrive as native tabs and its status bar
/// and prefix key never come into it. Panes keep running on the VM whichever tab
/// is showing, and a dropped connection reattaches to the same panes.
final class TerminalSession: ObservableObject, Identifiable {
    /// What the session runs when it opens.
    enum Launch {
        /// A local login shell (the plain terminal, no tmux).
        case localShell
        /// SSH into `destination` and run `bootstrap` as the remote command:
        /// the tmux control-mode client, which brings up the session's panes.
        case ssh(destination: String, bootstrap: String)
    }

    let id = UUID()

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
    /// diff sidebar uses this to run git over SSH against the VM.
    let sshDestination: String?

    /// The exe.dev VM backing this session, if any. Needed to delete it.
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
    private var fontObserver: AnyCancellable?

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

    private enum PendingReply {
        case panes
        /// A `capture-pane` whose lines restore this pane's screen.
        case capture(paneID: String)
        /// Nothing to do with the reply; only its place in the queue matters.
        case ignored
    }

    init(title: String = "Terminal", launch: Launch = .localShell, vmName: String? = nil) {
        self.title = title
        self.launch = launch
        self.vmName = vmName
        if case let .ssh(destination, _) = launch {
            sshDestination = destination
        } else {
            sshDestination = nil
        }

        // Track font changes made in Settings or with ⌘+/⌘-.
        fontObserver = AppConfig.shared.$data
            .map { ($0.fontName, $0.fontSize) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in self?.applyFont() }

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

    /// Kill the pane behind a tab. The tab goes when tmux reports the pane gone,
    /// so a refused kill leaves the tab where it was.
    func closeTab(_ tab: TerminalTab) {
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

    private func applyFont() {
        for tab in tabs {
            tab.view.font = Self.configuredFont()
        }
    }

    private static func configuredFont() -> NSFont {
        let data = AppConfig.shared.data
        let size = CGFloat(data.fontSize)
        return NSFont(name: data.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func start() {
        isDisconnected = false
        disconnectReason = nil
        pendingReplies = []
        reportedSize = nil

        switch launch {
        case .localShell:
            let view = LocalProcessTerminalView(frame: .zero)
            view.processDelegate = self
            view.font = Self.configuredFont()
            let tab = TerminalTab(paneID: nil, view: view, title: "Shell")
            tabs = [tab]
            selectedTabID = tab.id

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellName = (shell as NSString).lastPathComponent
            // Leading dash in argv[0] makes it a login shell.
            view.startProcess(executable: shell, execName: "-\(shellName)")

        case let .ssh(destination, bootstrap):
            // Tabs are rebuilt from the pane listing rather than reused: on a
            // reconnect the panes have moved on without us, and each tab
            // restores its pane's screen as it reappears.
            tabs = []
            selectedTabID = nil
            let client = TmuxClient(
                destination: destination,
                remoteCommand: bootstrap,
                onEvents: { [weak self] events in
                    guard let self else { return }
                    for event in events { handle(event) }
                },
                onExit: { [weak self] message in
                    self?.disconnected(reason: message)
                })
            self.client = client
            client.start()
            send(TmuxControl.listPanes(), expecting: .panes)
        }
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
            tab(forPane: pane)?.view.feed(byteArray: bytes[...])
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
            tab.view.feed(byteArray: restore[...])
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
            guard let self else { return }
            self.refreshQueued = false
            guard self.client != nil else { return }
            self.send(TmuxControl.listPanes(), expecting: .panes)
        }
    }

    /// Reconcile the tabs with what tmux says exists: new panes become tabs,
    /// closed ones drop out, and the order follows tmux's windows and panes
    /// rather than the order the app happened to hear about them.
    private func apply(panes: [TmuxPane]) {
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
        tabs = ordered

        if !tabs.contains(where: { $0.id == selectedTabID }) {
            let active = panes.first { $0.isActive }
            selectedTabID = tabs.first { $0.paneID == active?.id }?.id ?? tabs.first?.id
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
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = self
        view.font = Self.configuredFont()
        return TerminalTab(paneID: paneID, view: view, title: title)
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
        let terminal = tab.view.getTerminal()
        report(cols: terminal.cols, rows: terminal.rows)
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

// MARK: - Terminal views

extension TerminalSession: TerminalViewDelegate {
    /// Keystrokes from a pane's view go back to that pane.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let paneID = tabs.first(where: { $0.view === source })?.paneID else { return }
        for command in TmuxControl.sendKeys(pane: paneID, bytes: Array(data)) {
            send(command)
        }
    }

    /// Every view shares the window's terminal area, so only the visible one's
    /// size is worth telling tmux about.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let tab = selectedTab, tab.view === source else { return }
        report(cols: newCols, rows: newRows)
    }

    /// tmux names the tabs. An escape sequence from inside a pane doesn't get
    /// to rename the session.
    func setTerminalTitle(source: TerminalView, title: String) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52, which is how a program on the VM yanks to the clipboard. tmux
    /// passes it through to its client, and the local-process view used to
    /// handle it for these sessions, so the app has to now.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    /// Shared with `LocalProcessTerminalViewDelegate`, which declares the same
    /// method: only a local shell reports a directory this way, because tmux
    /// consumes OSC 7 before it reaches a control client.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        if let url = URL(string: directory), url.isFileURL {
            workingDirectory = URL(fileURLWithPath: url.path)
        } else {
            workingDirectory = URL(fileURLWithPath: directory)
        }
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Prefer an explicit session title (e.g. the session name); fall back to
        // the terminal-reported title only when we don't have one.
        if self.title.isEmpty {
            self.title = title
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        disconnected(reason: nil)
    }
}
