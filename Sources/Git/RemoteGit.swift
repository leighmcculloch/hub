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
    static func listRepos(destination: String) async throws -> [String] {
        // Two passes: repos checked out directly in the home dir, plus every
        // worktree under a repo's `.claude/worktrees`. The second is targeted
        // rather than a deeper `-maxdepth`, which would also drag in incidental
        // repos under things like node_modules. `.git` is matched without a type
        // filter because in a worktree it is a file, not a directory.
        let command = "cd \"$HOME\" && {"
            + " find . -maxdepth 2 -name .git 2>/dev/null;"
            + " find . -maxdepth 5 -path './*/.claude/worktrees/*/.git' 2>/dev/null;"
            + " } | sed 's|/\\.git$||;s|^\\./||' | grep -v '^\\.$' | sort -u"
        let out = try await runOrThrow(destination: destination, remoteCommand: command)
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Changed files plus their line counts, in one round trip: status and
    /// numstat are concatenated with a separator rather than run as two SSH
    /// commands, so adding the counts didn't double the per-poll cost.
    static func status(destination: String, repo: String) async -> GitRepoStatus {
        let git = "git -C \"$HOME/\(repo)\" -c core.quotePath=false"
        let command = "\(git) status --porcelain=v1 2>/dev/null;"
            + " echo '\(GitRepoStatus.separator)';"
            + " \(git) diff --numstat HEAD 2>/dev/null"
        guard let out = await run(destination: destination, remoteCommand: command) else {
            return GitRepoStatus()
        }
        return GitRepoStatus.parse(out)
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
        try? await runOrThrow(destination: destination, remoteCommand: remoteCommand)
    }

    /// Same, but surfacing *why* it failed. The distinction matters: an
    /// unreachable VM and an empty home directory both produce no output, and
    /// showing "no repos" for a connection failure is actively misleading.
    private static func runOrThrow(destination: String, remoteCommand: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshControlArgs(for: destination)
                + ["-o", "ConnectTimeout=15", "-o", "BatchMode=yes", destination, remoteCommand]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: RemoteGitError(
                    message: "Couldn't run ssh: \(error.localizedDescription)"))
                return
            }

            // Read before waiting: a full pipe buffer would deadlock the child.
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
            } else {
                continuation.resume(throwing: RemoteGitError(
                    message: summarize(stderr: String(data: errData, encoding: .utf8) ?? "",
                                       exitCode: process.terminationStatus)))
            }
        }
    }

    /// Condenses ssh's stderr into one line fit for the sidebar. ssh is chatty
    /// (banners, "Warning: Permanently added…"), so the informative line is
    /// picked out rather than showing the first one.
    /// Longest summary kept. The banner only shows a few lines, and this string
    /// is re-compared on every poll, so an unbounded one isn't worth holding.
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

struct RemoteGitError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}
