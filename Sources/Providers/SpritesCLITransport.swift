import Foundation

/// The sprites.dev transport: the `sprite` CLI, spawned as a local process the
/// same way `SSHTransport` spawns `ssh`. The CLI speaks the exec WebSocket; the
/// app only pumps bytes through the process's stdin/stdout, so `tmux -C` runs
/// over it exactly as it does over ssh.
///
/// Non-TTY (`--tty` off): tmux's control protocol is a byte stream on stdout,
/// and a remote PTY would only translate it — the same reason `SSHTransport`
/// passes no `-t`. `--max-run-after-disconnect=0` keeps the tmux session alive
/// if the app's connection drops, so a reconnect reattaches via tmux's `-A`.
struct SpritesCLITransport: RemoteTransport {
    /// The sprite name, used as `-s <name>` to select the sprite.
    let name: String

    func interactiveSpec(command: String) -> RemoteProcessSpec {
        RemoteProcessSpec(executable: "/usr/bin/env", arguments: [
            "sprite", "exec",
            "-s", name,
            "--max-run-after-disconnect=0",
            "--", "bash", "-l", "-c", command,
        ])
    }

    func oneshotSpec(command: String) -> RemoteProcessSpec {
        RemoteProcessSpec(executable: "/usr/bin/env", arguments: [
            "sprite", "exec",
            "-s", name,
            "--", "bash", "-l", "-c", command,
        ])
    }

    func summarize(stderr: String, exit: Int32) -> String {
        // The sprite CLI's own messages; take the last non-empty line, like the
        // ssh summarizer takes the informative line.
        let line = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last
        return line ?? "sprite exited with status \(exit)"
    }
}
