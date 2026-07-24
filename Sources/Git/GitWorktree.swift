import Foundation

/// A single changed path in the worktree.
struct GitFileChange: Identifiable, Hashable {
    var id: String { path }
    /// Two-character porcelain status code, e.g. " M", "??", "A ".
    let status: String
    let path: String

    var isUntracked: Bool { status == "??" }
}

/// A snapshot of a git worktree: which repo, which branch, what changed, and the
/// unified diff of all uncommitted changes.
struct GitWorktreeState: Equatable {
    let repoRoot: URL
    let branch: String?
    let changes: [GitFileChange]
    let diff: String

    var isClean: Bool { changes.isEmpty }
}

/// Runs `git` against a directory to describe its worktree. Everything here is
/// plain process invocation — independent of the terminal engine — so the diff
/// works for any directory a terminal navigates into.
enum GitWorktree {

    /// Build a worktree snapshot for `directory`, or `nil` if it isn't inside a
    /// git repository.
    static func state(for directory: URL) -> GitWorktreeState? {
        guard let toplevel = run(["rev-parse", "--show-toplevel"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !toplevel.isEmpty
        else { return nil }

        let repoRoot = URL(fileURLWithPath: toplevel)
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let changes = parseStatus(run(["status", "--porcelain=v1"], in: repoRoot) ?? "")

        // `git diff HEAD` covers both staged and unstaged changes to tracked
        // files — the full delta of the worktree against the last commit. On a
        // repo with no commits yet, fall back to the index diff.
        let diff = run(["diff", "HEAD"], in: repoRoot)
            ?? run(["diff"], in: repoRoot)
            ?? ""

        return GitWorktreeState(repoRoot: repoRoot, branch: branch, changes: changes, diff: diff)
    }

    private static func parseStatus(_ output: String) -> [GitFileChange] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let text = String(line)
                guard text.count > 3 else { return nil }
                let status = String(text.prefix(2))
                let path = String(text.dropFirst(3))
                return GitFileChange(status: status, path: path)
            }
    }

    private static func run(_ args: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + args

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // swallow stderr (e.g. "not a git repo")

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
