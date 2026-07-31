import Foundation

/// The exe.dev transport: `ssh` against a direct hostname, with ControlMaster
/// multiplexing so the diff sidebar's git calls and the rename poll ride on the
/// one connection the terminal opens. A drop-in for the `sprite` CLI on
/// sprites.dev — same `RemoteTransport` shape, different executable.
struct SSHTransport: RemoteTransport {
    let destination: String

    func interactiveSpec(command: String) -> RemoteProcessSpec {
        // No `-t`: the protocol is a byte stream on stdout, and a remote tty
        // would only translate it. (`tmux -CC`, the interactive spelling,
        // insists on one — plain `-C` is the spelling for a program driving
        // tmux.) `ConnectionAttempts` retries while the VM finishes booting.
        RemoteProcessSpec(executable: "/usr/bin/ssh", arguments: controlArgs + [
            "-o", "ConnectTimeout=15",
            "-o", "ConnectionAttempts=10",
            "-o", "ServerAliveInterval=30",
            destination, command,
        ])
    }

    func oneshotSpec(command: String) -> RemoteProcessSpec {
        RemoteProcessSpec(executable: "/usr/bin/ssh", arguments: controlArgs + [
            "-o", "ConnectTimeout=15",
            "-o", "BatchMode=yes",
            destination, command,
        ])
    }

    private var controlArgs: [String] {
        [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(Self.controlPath(for: destination))",
            "-o", "ControlPersist=120",
        ]
    }

    static func controlPath(for destination: String) -> String {
        let safe = destination.replacingOccurrences(of: "/", with: "_")
        return "\(NSHomeDirectory())/.ssh/cm-\(safe).sock"
    }

    func summarize(stderr: String, exit: Int32) -> String {
        Self.summarize(stderr: stderr, exitCode: exit)
    }

    /// Condenses ssh's stderr into one line fit for the sidebar. ssh is chatty
    /// (banners, "Warning: Permanently added…"), so the informative line is
    /// picked out rather than showing the first one. Longest summary kept: the
    /// banner only shows a few lines, and this string is re-compared on every
    /// poll, so an unbounded one isn't worth holding.
    private static let maxSummaryLength = 300

    static func summarize(stderr: String, exitCode: Int32) -> String {
        // Split on CR as well as LF: ssh and remote programs emit bare carriage
        // returns, which would otherwise leave line breaks inside the summary.
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
            .map { $0.count > maxSummaryLength ? String($0.prefix(maxSummaryLength)) + "…" : $0 }

        let notable = ["Permission denied", "Could not resolve", "Connection refused",
                       "Connection timed out", "Connection closed", "No route to host",
                       "Host key verification failed", "Operation timed out"]
        if let match = lines.first(where: { line in
            notable.contains { line.localizedCaseInsensitiveContains($0) }
        }) {
            return match
        }
        return lines.last ?? "ssh exited with status \(exitCode)"
    }
}
