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
    /// this reflects the remote path (the diff sidebar only tracks local repos).
    @Published var workingDirectory: URL?

    let terminalView: LocalProcessTerminalView

    init(title: String = "Terminal", launch: Launch = .localShell) {
        self.title = title
        terminalView = LocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = self
        start(launch)
    }

    private func start(_ launch: Launch) {
        switch launch {
        case .localShell:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellName = (shell as NSString).lastPathComponent
            // Leading dash in argv[0] makes it a login shell.
            terminalView.startProcess(executable: shell, execName: "-\(shellName)")

        case let .ssh(destination, bootstrap):
            // `-t` forces a remote PTY; accept-new avoids an interactive
            // host-key prompt on first connect. `bootstrap` is passed as the
            // single remote command argument.
            terminalView.startProcess(
                executable: "/usr/bin/ssh",
                args: [
                    "-t",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=15",
                    "-o", "ConnectionAttempts=10", // retry while the VM finishes booting
                    "-o", "ServerAliveInterval=30",
                    destination,
                    bootstrap,
                ]
            )
        }
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
        // Prefer an explicit tab title (e.g. the repo name); fall back to the
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

    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
