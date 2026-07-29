import Foundation

/// One commit in a repo's log.
struct GitCommit: Identifiable, Equatable {
    var id: String { sha }
    /// Abbreviated hash, as git prints it for `%h`.
    let sha: String
    let subject: String
    let author: String
    /// git's own relative wording, e.g. "2 days ago".
    let relativeDate: String
}

/// The commits a repo has that its default branch doesn't — the branch's own
/// work, newest first — plus the ref that boundary was measured against.
struct GitLog: Equatable {
    /// Newest first.
    var commits: [GitCommit] = []
    /// The default-branch ref the list stops at, e.g. "origin/main". Empty when
    /// the repo has no recognisable default branch, in which case the whole
    /// history is listed instead.
    var base: String = ""

    /// Refs tried, in order, when `refs/remotes/origin/HEAD` isn't set.
    static let baseCandidates = ["origin/main", "origin/master", "main", "master"]

    /// A branch that has run away from its default branch would otherwise send
    /// its whole history over SSH on every poll.
    static let limit = 200

    /// Fields are separated by US (0x1f) rather than a printable character, so a
    /// commit subject can contain anything without breaking the split. `%x1f`
    /// makes git emit the byte itself, which keeps the format shell-safe.
    static let prettyFormat = "%h%x1f%s%x1f%an%x1f%ar"

    private static let fieldSeparator: Character = "\u{1f}"

    /// The revision range for `git log`: the branch's own commits, or the whole
    /// history when no default branch could be resolved.
    static func range(base: String) -> String {
        base.isEmpty ? "HEAD" : "\(base)..HEAD"
    }

    /// Parses lines of `prettyFormat`. Anything with the wrong field count is
    /// skipped rather than guessed at.
    static func parse(_ output: String) -> [GitCommit] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(
                separator: fieldSeparator, maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            return GitCommit(
                sha: String(fields[0]),
                subject: String(fields[1]),
                author: String(fields[2]),
                relativeDate: String(fields[3]))
        }
    }

    /// The left-hand side of the diff for the run of commits at `indices`
    /// (indices into `commits`, so lower means newer).
    ///
    /// It is the commit *before* the oldest selected one: the next older entry
    /// in the list, or — when the selection reaches the end of the list — the
    /// default branch itself. Naming the base ref rather than `<oldest>^` is
    /// what makes "all commits" work on a branch whose oldest commit is the
    /// repo's root, which has no parent to name.
    func exclusiveBase(forOldest index: Int) -> String {
        if index + 1 < commits.count { return commits[index + 1].sha }
        if !base.isEmpty { return base }
        return "\(commits[index].sha)^"
    }
}
