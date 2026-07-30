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

    /// Changed files, their line counts, and the repo's log, in one round trip:
    /// the three are concatenated with separators rather than run as separate
    /// SSH commands, so neither the counts nor the log multiplied the per-poll
    /// cost.
    static func status(destination: String, repo: String) async -> GitRepoStatus {
        guard let out = await run(destination: destination,
                                  remoteCommand: statusCommand(repo: repo)) else {
            return GitRepoStatus()
        }
        return GitRepoStatus.parse(out)
    }

    /// `--untracked-files=all` because the default collapses a whole new
    /// directory into a single `?? dir/` entry — one unopenable row standing in
    /// for every file in it.
    ///
    /// Rename detection is turned off on both halves. With it on, a rename is
    /// reported as `R old.txt -> new.txt`, and everything downstream treats that
    /// whole string as a filename: the row is unreadable and its diff is empty.
    /// The two halves don't even agree on the spelling — `status` writes
    /// `old -> new` while `--numstat` writes `{old => new}/file` — so line counts
    /// never attach either. Off, git reports the plain delete and add, and every
    /// path is one that exists.
    ///
    /// Set as config rather than `--no-renames` so a git too old to know the
    /// option ignores it instead of failing the whole command.
    static func statusCommand(repo: String) -> String {
        let git = "git -C \"$HOME\"/\(Bootstrap.shellQuote(repo))"
            + " -c core.quotePath=false -c status.renames=false -c diff.renames=false"
        return "\(git) status --porcelain=v1 --untracked-files=all 2>/dev/null;"
            + " echo '\(GitRepoStatus.separator)';"
            + " \(git) diff --numstat HEAD 2>/dev/null;"
            + " echo '\(GitRepoStatus.logSeparator)';"
            + " \(logCommand(git: git));"
            // `run` discards a non-zero exit, and the halves above legitimately
            // fail on a repo with no commits yet — where `status` still has
            // untracked files to report. Without this the whole list blanks.
            + " exit 0"
    }

    /// Resolves the repo's default branch, prints it, then lists the commits
    /// HEAD has beyond it.
    ///
    /// The base is printed even though the caller could guess, because the log
    /// alone doesn't say what it stopped at — and when nothing resolves, the
    /// blank line is what tells the sidebar it is showing plain history rather
    /// than a branch's own work.
    private static func logCommand(git: String) -> String {
        "base=;"
            + " for ref in $(\(git) symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
            + " \(GitLog.baseCandidates.joined(separator: " ")); do"
            + " \(git) rev-parse --verify -q \"$ref\" >/dev/null 2>&1 && base=$ref && break;"
            + " done;"
            + " echo \"$base\";"
            + " \(git) log -n \(GitLog.limit) --pretty=format:'\(GitLog.prettyFormat)'"
            + " \"${base:+$base..}HEAD\" 2>/dev/null"
    }

    /// The combined diff of a run of commits: everything between `from`
    /// (exclusive) and `to` (inclusive).
    static func rangeDiff(destination: String, repo: String, from: String, to: String) async -> String {
        await run(destination: destination,
                  remoteCommand: rangeDiffCommand(repo: repo, from: from, to: to)) ?? ""
    }

    /// Both revisions come from git's own output, but they are quoted anyway:
    /// the base can be a ref name from the repo, and a branch may be named
    /// anything a filesystem accepts.
    static func rangeDiffCommand(repo: String, from: String, to: String) -> String {
        "git -C \"$HOME\"/\(Bootstrap.shellQuote(repo)) diff"
            + " \(Bootstrap.shellQuote(from)) \(Bootstrap.shellQuote(to)) 2>/dev/null"
    }

    /// The files changed between `from` (exclusive) and `to`, with line counts —
    /// the file list for a commit scope, in one round trip.
    static func scopeFiles(destination: String, repo: String, from: String, to: String) async
        -> GitScopeFiles
    {
        guard let out = await run(
            destination: destination,
            remoteCommand: scopeFilesCommand(repo: repo, from: from, to: to))
        else { return GitScopeFiles() }
        return GitScopeFiles.parse(out)
    }

    /// The trailing `exit 0` serves the same purpose as in `statusCommand`: an
    /// unresolvable range fails the diffs, and a non-zero exit would make `run`
    /// discard whatever did print.
    static func scopeFilesCommand(repo: String, from: String, to: String) -> String {
        let git = "git -C \"$HOME\"/\(Bootstrap.shellQuote(repo)) -c diff.renames=false"
        return GitScopeFiles.command(
            git: git,
            from: Bootstrap.shellQuote(from),
            to: Bootstrap.shellQuote(to))
            + "; exit 0"
    }

    /// The diff of one file within a commit range.
    static func rangeFileDiff(
        destination: String, repo: String, from: String, to: String, file: String
    ) async -> String {
        await run(destination: destination,
                  remoteCommand: rangeFileDiffCommand(repo: repo, from: from, to: to, file: file))
            ?? ""
    }

    static func rangeFileDiffCommand(repo: String, from: String, to: String, file: String) -> String {
        "git -C \"$HOME\"/\(Bootstrap.shellQuote(repo)) diff"
            + " \(Bootstrap.shellQuote(from)) \(Bootstrap.shellQuote(to))"
            + " -- \(Bootstrap.shellQuote(file)) 2>/dev/null"
    }

    /// Unified diff for a single file within a repo.
    static func fileDiff(destination: String, repo: String, file: String) async -> String {
        await run(destination: destination,
                  remoteCommand: fileDiffCommand(repo: repo, file: file)) ?? ""
    }

    /// An untracked file has no blob in HEAD, so `git diff HEAD` says nothing
    /// about it — the sidebar listed the file and then showed an empty pane.
    /// `--no-index` renders it as an addition against `/dev/null` instead.
    ///
    /// The choice between the two has to be "is this file untracked", which is
    /// what `ls-files --others` answers. Asking whether it is *in the index*
    /// instead gets deletions wrong: `git rm` takes the file out of the index,
    /// so a staged deletion would be sent down the untracked path and diffed
    /// against a file that is no longer on disk, producing nothing.
    ///
    /// The trailing `exit 0` is load-bearing: `--no-index` exits 1 whenever the
    /// inputs differ, which is every time it produces output, and a non-zero
    /// exit makes `run` discard it.
    static func fileDiffCommand(repo: String, file: String) -> String {
        let path = Bootstrap.shellQuote(file)
        return "cd \"$HOME\" && cd \(Bootstrap.shellQuote(repo)) 2>/dev/null || exit 0;"
            + " if [ -n \"$(git ls-files --others --exclude-standard -- \(path) 2>/dev/null)\" ];"
            + " then git diff --no-index -- /dev/null \(path) 2>/dev/null;"
            + " else git diff HEAD -- \(path) 2>/dev/null; fi;"
            + " exit 0"
    }

    /// Full worktree diff for a repo (vs. HEAD), untracked files included.
    ///
    /// `git diff HEAD` says nothing about untracked files — the sidebar lists
    /// them from the status, so a whole-worktree diff missing them would be
    /// wrong. Each is appended as an addition against `/dev/null`, the same
    /// trick as the local side and `fileDiffCommand`. The trailing `exit 0` is
    /// load-bearing: `--no-index` exits 1 whenever the inputs differ, and a
    /// non-zero exit makes `run` discard the output.
    static func repoDiff(destination: String, repo: String) async -> String {
        await run(destination: destination, remoteCommand: repoDiffCommand(repo: repo)) ?? ""
    }

    /// The untracked loop reads newline-separated paths, which only a filename
    /// containing a newline can break — the trade `read -d ''` makes is
    /// requiring bash, and the remote shell isn't guaranteed to be one.
    static func repoDiffCommand(repo: String) -> String {
        let quoted = Bootstrap.shellQuote(repo)
        return "cd \"$HOME\" && cd \(quoted) 2>/dev/null || exit 0;"
            + " git -c core.quotePath=false -c diff.renames=false diff HEAD 2>/dev/null;"
            + " git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null"
            + " | while IFS= read -r f; do git diff --no-index -- /dev/null \"$f\" 2>/dev/null; done;"
            + " exit 0"
    }

    /// Run one remote command, returning stdout on success (exit 0), else nil.
    ///
    /// Not private because this is the app's one way of running something on a
    /// VM over the terminal's connection; `RemoteVM` asks the VM its name with
    /// it.
    static func run(destination: String, remoteCommand: String) async -> String? {
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
