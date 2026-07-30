import Foundation

/// What the diff sidebar's scope list has selected: either the repo's whole
/// worktree, or a run of commits diffed together. A file picked in the files
/// pane below is separate view state — it always belongs to the current scope.
///
/// This lives apart from the view so the range arithmetic behind shift-click —
/// which end of a run is which, and what a range is diffed against — can be
/// tested.
enum DiffTarget: Equatable {
    /// Everything uncommitted in the worktree.
    case worktree(repo: String)
    /// A contiguous run of commits, newest first, shown as one combined diff
    /// against `exclusiveBase` — the commit (or default-branch ref) just before
    /// the oldest of them.
    case commits(repo: String, shas: [String], exclusiveBase: String)

    /// The run of commits selected by picking `index` in `log`.
    ///
    /// `anchor` is the last commit picked without shift held; passing it selects
    /// everything between the two, in either direction, which is how a range
    /// gets chosen. Passing nil selects `index` alone.
    static func commits(
        repo: String, log: GitLog, picking index: Int, extendingFrom anchor: Int? = nil
    ) -> DiffTarget {
        let indices = log.commits.indices
        guard indices.contains(index) else { return .commits(repo: repo, shas: [], exclusiveBase: "") }
        let other = anchor.flatMap { indices.contains($0) ? $0 : nil } ?? index
        return range(repo: repo, log: log, min(other, index)...max(other, index))
    }

    /// Every commit in `log` — the branch's whole work against its default
    /// branch.
    static func allCommits(repo: String, log: GitLog) -> DiffTarget {
        guard !log.commits.isEmpty else { return .commits(repo: repo, shas: [], exclusiveBase: "") }
        return range(repo: repo, log: log, log.commits.indices.lowerBound...(log.commits.count - 1))
    }

    private static func range(repo: String, log: GitLog, _ run: ClosedRange<Int>) -> DiffTarget {
        .commits(
            repo: repo,
            shas: run.map { log.commits[$0].sha },
            exclusiveBase: log.exclusiveBase(forOldest: run.upperBound))
    }

    /// The newest commit in the run — the right-hand side of the range diff.
    /// Nil for the worktree scope, which is diffed against HEAD instead.
    var newestSha: String? {
        if case let .commits(_, shas, _) = self { return shas.first }
        return nil
    }

    var repo: String {
        switch self {
        case let .worktree(repo), let .commits(repo, _, _): return repo
        }
    }

    /// The run's endpoints for a range diff; nil for the worktree scope.
    var commitRange: (from: String, to: String)? {
        guard case let .commits(_, _, exclusiveBase) = self, let newest = newestSha else { return nil }
        return (exclusiveBase, newest)
    }

    func selectsWorktree(repo: String) -> Bool {
        if case let .worktree(selectedRepo) = self { return selectedRepo == repo }
        return false
    }

    func selects(repo: String, sha: String) -> Bool {
        if case let .commits(selectedRepo, shas, _) = self {
            return selectedRepo == repo && shas.contains(sha)
        }
        return false
    }

    /// True when the run covers every commit in `log` — what the "all commits"
    /// row highlights on.
    func selectsAll(repo: String, log: GitLog) -> Bool {
        if case let .commits(selectedRepo, shas, _) = self {
            return selectedRepo == repo && !shas.isEmpty && shas.count == log.commits.count
        }
        return false
    }

    /// Names the scope for the files pane's caption and the diff pane's title:
    /// the subject for a single commit, the span for a run of them.
    func label(in log: GitLog) -> String {
        switch self {
        case .worktree:
            return "Working tree"
        case let .commits(_, shas, _):
            guard let newest = shas.first else { return "" }
            if shas.count == 1 {
                let subject = log.commits.first { $0.sha == newest }?.subject ?? ""
                return subject.isEmpty ? newest : "\(newest)  \(subject)"
            }
            return "\(shas.count) commits  \(shas[shas.count - 1])…\(newest)"
        }
    }
}
