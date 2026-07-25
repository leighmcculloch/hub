import AppKit
import Combine
import Foundation
import SwiftTerm

/// One terminal tab: a SwiftTerm local-process terminal view plus the observable
/// state the UI binds to (its title and current working directory).
final class TerminalSession: ObservableObject, Identifiable {
    /// What the terminal runs when the tab opens.
    enum Launch {
        /// A local login shell (the plain terminal).
        case localShell
        /// SSH into `destination` and run `bootstrap` as the remote command
        /// (setup script + git clone, then an interactive login shell).
        case ssh(destination: String, bootstrap: String)
    }

    let id = UUID()

    @Published var title: String
    /// The shell's current working directory, updated from OSC 7. For SSH tabs
    /// this reflects the remote path.
    @Published var workingDirectory: URL?
    /// True once the underlying process has exited (SSH dropped or shell quit).
    @Published private(set) var isDisconnected = false

    let terminalView: LocalProcessTerminalView

    /// The SSH destination for VM-backed tabs (nil for local shells). The diff
    /// sidebar uses this to run git over SSH against the VM.
    let sshDestination: String?

    private let launch: Launch
    private var fontObserver: AnyCancellable?

    init(title: String = "Terminal", launch: Launch = .localShell) {
        self.title = title
        self.launch = launch
        if case let .ssh(destination, _) = launch {
            sshDestination = destination
        } else {
            sshDestination = nil
        }
        terminalView = LocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = self

        applyFont()
        // Track font changes made in Settings or with ⌘+/⌘-.
        fontObserver = AppConfig.shared.$data
            .map { ($0.fontName, $0.fontSize) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in self?.applyFont() }

        start()
    }

    private func applyFont() {
        let data = AppConfig.shared.data
        let size = CGFloat(data.fontSize)
        let font = NSFont(name: data.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        terminalView.font = font
    }

    private func start() {
        isDisconnected = false
        switch launch {
        case .localShell:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellName = (shell as NSString).lastPathComponent
            // Leading dash in argv[0] makes it a login shell.
            terminalView.startProcess(executable: shell, execName: "-\(shellName)")

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
            terminalView.startProcess(executable: "/usr/bin/ssh", args: args)
        }
    }

    /// Re-run the launch command in this same view. Used to recover a dropped
    /// SSH session without losing the tab.
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

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Prefer an explicit tab title (e.g. the session name); fall back to the
        // terminal-reported title only when we don't have one.
        if self.title.isEmpty {
            self.title = title
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        if let url = URL(string: directory), url.isFileURL {
            workingDirectory = URL(fileURLWithPath: url.path)
        } else {
            workingDirectory = URL(fileURLWithPath: directory)
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isDisconnected = true
    }
}
