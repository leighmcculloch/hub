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

/// One repo's changed files, their line counts, and its commit log, parsed from
/// a single remote command so all three cost one SSH round trip rather than
/// three.
struct GitRepoStatus: Equatable {
    var changes: [GitFileChange] = []
    /// Keyed by path. Untracked files are absent — they aren't in `git diff`.
    var stats: [String: GitLineStat] = [:]
    /// The commits this repo has that its default branch doesn't.
    var log = GitLog()

    /// Separates the porcelain status from the numstat in the combined output.
    static let separator = "---exe-numstat---"

    /// Separates the numstat from the log half.
    static let logSeparator = "---exe-log---"

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

    /// Parses `git status --porcelain=v1`, the separator, `git diff --numstat
    /// HEAD`, the log separator, then the base ref and `git log`. Each half is
    /// optional: the local path reuses this parser for status alone.
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
        let tail = sections[1].components(separatedBy: logSeparator)
        for line in tail[0].split(separator: "\n", omittingEmptySubsequences: true) {
            // "<added>\t<removed>\t<path>", with "-" counts for binary files.
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            result.stats[String(fields[2])] = GitLineStat(
                added: Int(fields[0]), removed: Int(fields[1]))
        }

        guard tail.count > 1 else { return result }
        result.log = parseLog(tail[1])
        return result
    }

    /// The log half is "<base>\n<commits…>". The base line is taken positionally
    /// rather than by skipping blanks, because an unresolvable default branch
    /// legitimately prints an empty one.
    private static func parseLog(_ section: String) -> GitLog {
        var lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.isEmpty == true { lines.removeFirst() } // newline after the separator
        guard !lines.isEmpty else { return GitLog() }
        let base = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        return GitLog(commits: GitLog.parse(lines.joined(separator: "\n")), base: base)
    }
}

/// A snapshot of a git worktree: which repo, which branch, what changed, the
/// unified diff of all uncommitted changes, and the commits the branch has that
/// its default branch doesn't.
struct GitWorktreeState: Equatable {
    let repoRoot: URL
    let branch: String?
    let changes: [GitFileChange]
    let diff: String
    let log: GitLog

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
        // Rename detection off: it reports `R old.txt -> new.txt`, which becomes
        // one unreadable row whose diff is empty, because that string is not a
        // path. Off, git reports the plain delete and add instead. Set as config
        // so a git too old to know the option ignores it rather than failing.
        let status = run(
            ["-c", "core.quotePath=false", "-c", "status.renames=false",
             "status", "--porcelain=v1", "--untracked-files=all"],
            in: repoRoot) ?? ""
        // Parsed by the same routine as the remote sidebar rather than a second
        // copy: the duplicate that used to live here had drifted, and was
        // leaving git's quoting on paths containing spaces.
        let changes = GitRepoStatus.parse(status + "\n" + GitRepoStatus.separator).changes

        // `git diff HEAD` covers both staged and unstaged changes to tracked
        // files — the full delta of the worktree against the last commit. On a
        // repo with no commits yet, fall back to the index diff.
        // Renames off here too, to stay consistent with the file list above.
        // With detection on, a rename is one section covering both paths, and an
        // otherwise-unchanged file has no content lines at all — so two rows in
        // the list share one section and neither shows anything. Off, each path
        // gets its own section with its own content.
        let noRenames = ["-c", "diff.renames=false"]
        let tracked = run(noRenames + ["diff", "HEAD"], in: repoRoot)
            ?? run(noRenames + ["diff"], in: repoRoot)
            ?? ""

        return GitWorktreeState(
            repoRoot: repoRoot,
            branch: branch,
            changes: changes,
            diff: tracked + untrackedDiff(for: changes, in: repoRoot),
            log: log(in: repoRoot))
    }

    /// The branch's own commits, newest first. Stopping at the default branch
    /// keeps the list to the work in progress instead of the repo's history.
    static func log(in repoRoot: URL) -> GitLog {
        let base = defaultBase(in: repoRoot)
        let out = run(
            ["log", "-n", String(GitLog.limit),
             "--pretty=format:\(GitLog.prettyFormat)", GitLog.range(base: base)],
            in: repoRoot) ?? ""
        return GitLog(commits: GitLog.parse(out), base: base)
    }

    /// The ref the log stops at. `refs/remotes/origin/HEAD` is what a clone
    /// records, so it is asked first; the named candidates cover repos where it
    /// was never set. Empty when none of them exist.
    private static func defaultBase(in repoRoot: URL) -> String {
        let recorded = run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for candidate in [recorded].filter({ !$0.isEmpty }) + GitLog.baseCandidates {
            if run(["rev-parse", "--verify", "-q", candidate], in: repoRoot) != nil { return candidate }
        }
        return ""
    }

    /// The combined diff of a run of commits: everything between `from`
    /// (exclusive) and `to` (inclusive).
    static func rangeDiff(in repoRoot: URL, from: String, to: String) -> String {
        run(["diff", from, to], in: repoRoot) ?? ""
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
