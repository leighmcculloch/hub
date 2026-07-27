import Foundation

/// A single changed path in the worktree.
struct GitFileChange: Identifiable, Hashable {
    var id: String { path }
    /// Two-character porcelain status code, e.g. " M", "??", "A ".
    let status: String
    let path: String

    var isUntracked: Bool { status == "??" }
}

/// Lines added/removed for one file. `nil` counts mean git reported `-`, which
/// it does for binary files.
struct GitLineStat: Equatable {
    let added: Int?
    let removed: Int?

    var isBinary: Bool { added == nil && removed == nil }
}

/// One repo's changed files and their line counts, parsed from a single remote
/// command so status and numstat cost one SSH round trip rather than two.
struct GitRepoStatus: Equatable {
    var changes: [GitFileChange] = []
    /// Keyed by path. Untracked files are absent — they aren't in `git diff`.
    var stats: [String: GitLineStat] = [:]

    /// Separates the porcelain status from the numstat in the combined output.
    static let separator = "---exe-numstat---"

    /// Strips git's C-style quoting from a status path. Paths with spaces or
    /// special characters come back as `"a b.txt"` with escapes; `--numstat`
    /// emits them raw, so both sides have to agree for the lookup to work.
    static func unquotePath(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var result = ""
        var escaped = false
        for character in path.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character) // \" and \\ are literal
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Parses `git status --porcelain=v1`, the separator, then
    /// `git diff --numstat HEAD`.
    static func parse(_ output: String) -> GitRepoStatus {
        let sections = output.components(separatedBy: separator)
        var result = GitRepoStatus()

        for line in (sections.first ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            guard text.count > 3 else { continue }
            // `status` quotes paths containing spaces or specials while
            // `--numstat` does not, so unquote here or the stat lookup misses.
            result.changes.append(
                GitFileChange(status: String(text.prefix(2)),
                              path: unquotePath(String(text.dropFirst(3)))))
        }

        guard sections.count > 1 else { return result }
        for line in sections[1].split(separator: "\n", omittingEmptySubsequences: true) {
            // "<added>\t<removed>\t<path>", with "-" counts for binary files.
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            result.stats[String(fields[2])] = GitLineStat(
                added: Int(fields[0]), removed: Int(fields[1]))
        }
        return result
    }
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
        // `--untracked-files=all` so a new directory lists its files instead of
        // collapsing to one `?? dir/` row that nothing can be shown for.
        let status = run(
            ["-c", "core.quotePath=false", "status", "--porcelain=v1", "--untracked-files=all"],
            in: repoRoot) ?? ""
        // Parsed by the same routine as the remote sidebar rather than a second
        // copy: the duplicate that used to live here had drifted, and was
        // leaving git's quoting on paths containing spaces.
        let changes = GitRepoStatus.parse(status + "\n" + GitRepoStatus.separator).changes

        // `git diff HEAD` covers both staged and unstaged changes to tracked
        // files — the full delta of the worktree against the last commit. On a
        // repo with no commits yet, fall back to the index diff.
        let tracked = run(["diff", "HEAD"], in: repoRoot)
            ?? run(["diff"], in: repoRoot)
            ?? ""

        return GitWorktreeState(
            repoRoot: repoRoot,
            branch: branch,
            changes: changes,
            diff: tracked + untrackedDiff(for: changes, in: repoRoot))
    }

    /// Untracked files have no blob in HEAD, so `git diff HEAD` omits them
    /// entirely — clicking a newly created file scrolled to nothing. Diffing
    /// each against `/dev/null` appends a normal "new file" section, which is
    /// what the diff view already knows how to render and scroll to.
    private static func untrackedDiff(for changes: [GitFileChange], in repoRoot: URL) -> String {
        changes
            .filter(\.isUntracked)
            .compactMap {
                // `--no-index` exits 1 whenever it finds a difference, which is
                // every time it has anything to say.
                run(["diff", "--no-index", "--", "/dev/null", $0.path],
                    in: repoRoot, acceptNonZeroExit: true)
            }
            .joined()
    }

    private static func run(
        _ args: [String],
        in directory: URL,
        acceptNonZeroExit: Bool = false
    ) -> String? {
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

        guard acceptNonZeroExit || process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
