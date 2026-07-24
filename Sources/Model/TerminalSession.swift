import Foundation
import SwiftTerm

/// One terminal tab: a SwiftTerm local-process terminal view plus the observable
/// state the UI binds to (its title and current working directory).
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published var title: String = "Terminal"
    /// The shell's current working directory, updated from OSC 7.
    @Published var workingDirectory: URL?

    let terminalView: LocalProcessTerminalView

    init() {
        terminalView = LocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = self
        startShell()
    }

    private func startShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        // Leading dash in argv[0] makes it a login shell, so the user's profile
        // (and its shell integration, e.g. OSC 7 cwd reporting) is sourced.
        terminalView.startProcess(executable: shell, execName: "-\(shellName)")
    }

    /// A short label for the tab strip.
    var displayName: String {
        if let dir = workingDirectory {
            return dir.lastPathComponent
        }
        return title
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        // OSC 7 reports either a `file://host/path` URL or a bare path.
        if let url = URL(string: directory), url.isFileURL {
            workingDirectory = URL(fileURLWithPath: url.path)
        } else {
            workingDirectory = URL(fileURLWithPath: directory)
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
