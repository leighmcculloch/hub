import Foundation

/// Runs `git` over SSH against an exe.dev VM, so the diff sidebar can inspect
/// the repos cloned into the VM's home directory.
///
/// All calls reuse a single multiplexed SSH connection (ControlMaster). The
/// terminal session opens the connection with the same `ControlPath`, so these
/// per-command SSH invocations are cheap after the terminal has connected.
enum RemoteGit {
    /// SSH options that enable connection multiplexing for `destination`. Shared
    /// with `TerminalSession`'s interactive SSH so they use one connection.
    static func sshControlArgs(for destination: String) -> [String] {
        [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath(for: destination))",
            "-o", "ControlPersist=120",
        ]
    }

    private static func controlPath(for destination: String) -> String {
        let safe = destination.replacingOccurrences(of: "/", with: "_")
        return "\(NSHomeDirectory())/.ssh/cm-\(safe).sock"
    }

    /// Home-relative directories under `$HOME` (depth ≤ 2) that are git repos.
    static func listRepos(destination: String) async -> [String] {
        let command = "cd \"$HOME\" && find . -maxdepth 2 -name .git 2>/dev/null"
            + " | sed 's|/\\.git$||;s|^\\./||' | grep -v '^\\.$' | sort"
        guard let out = await run(destination: destination, remoteCommand: command) else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Changed files (porcelain status) for a home-relative repo.
    static func changes(destination: String, repo: String) async -> [GitFileChange] {
        let command = "git -C \"$HOME/\(repo)\" status --porcelain=v1 2>/dev/null"
        guard let out = await run(destination: destination, remoteCommand: command) else { return [] }
        return out
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let text = String(line)
                guard text.count > 3 else { return nil }
                return GitFileChange(status: String(text.prefix(2)), path: String(text.dropFirst(3)))
            }
    }

    /// Unified diff for a single file within a repo (vs. HEAD).
    static func fileDiff(destination: String, repo: String, file: String) async -> String {
        let command = "git -C \"$HOME/\(repo)\" diff HEAD -- \"\(file)\" 2>/dev/null"
        return await run(destination: destination, remoteCommand: command) ?? ""
    }

    /// Full worktree diff for a repo (vs. HEAD).
    static func repoDiff(destination: String, repo: String) async -> String {
        let command = "git -C \"$HOME/\(repo)\" diff HEAD 2>/dev/null"
        return await run(destination: destination, remoteCommand: command) ?? ""
    }

    /// Run one remote command, returning stdout on success (exit 0), else nil.
    private static func run(destination: String, remoteCommand: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshControlArgs(for: destination)
                + ["-o", "ConnectTimeout=15", "-o", "BatchMode=yes", destination, remoteCommand]

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)
            continuation.resume(returning: process.terminationStatus == 0 ? text : nil)
        }
    }
}
