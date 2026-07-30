import XCTest
@testable import ExeDesktopApp

/// What the diff sidebar shows when commits are picked: which commits a click —
/// or a shift-click across a run — selects, and what that run is diffed against.
final class DiffTargetTests: XCTestCase {
    private let repo = "hub"

    /// Newest first, as git and the pane both list them.
    private let log = GitLog(
        commits: [
            GitCommit(sha: "c3", subject: "third", author: "Ada", relativeDate: "1 hour ago"),
            GitCommit(sha: "c2", subject: "second", author: "Ada", relativeDate: "2 hours ago"),
            GitCommit(sha: "c1", subject: "first", author: "Ada", relativeDate: "3 hours ago"),
        ],
        base: "origin/main")

    private func shas(_ target: DiffTarget) -> [String] {
        if case let .commits(_, shas, _) = target { return shas }
        return []
    }

    private func base(_ target: DiffTarget) -> String {
        if case let .commits(_, _, base) = target { return base }
        return ""
    }

    // MARK: - Picking

    func testAPlainPickSelectsOneCommit() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 1)
        XCTAssertEqual(shas(target), ["c2"])
        XCTAssertEqual(base(target), "c1", "a single commit is diffed against the one before it")
        XCTAssertEqual(target.newestSha, "c2")
    }

    func testExtendingDownwardSelectsTheRun() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 2, extendingFrom: 0)
        XCTAssertEqual(shas(target), ["c3", "c2", "c1"])
    }

    /// Shift-clicking upward — an older commit anchored, a newer one clicked —
    /// has to select the same run, not an empty or reversed one.
    func testExtendingUpwardSelectsTheSameRun() {
        let up = DiffTarget.commits(repo: repo, log: log, picking: 0, extendingFrom: 2)
        let down = DiffTarget.commits(repo: repo, log: log, picking: 2, extendingFrom: 0)
        XCTAssertEqual(shas(up), shas(down))
    }

    /// The selection is always ordered newest first, whichever way it was made,
    /// because the newest is the right-hand side of the diff.
    func testASelectionIsAlwaysNewestFirst() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 0, extendingFrom: 2)
        XCTAssertEqual(target.newestSha, "c3")
    }

    /// A run that stops short of the end diffs against the next commit down.
    func testAPartialRunIsDiffedAgainstTheNextOlderCommit() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 1, extendingFrom: 0)
        XCTAssertEqual(shas(target), ["c3", "c2"])
        XCTAssertEqual(base(target), "c1")
    }

    /// A run reaching the oldest listed commit is the branch's whole work, so it
    /// is diffed against the default branch — `c1^` would fail if c1 were the
    /// repository's first commit.
    func testARunReachingTheEndIsDiffedAgainstTheDefaultBranch() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 2, extendingFrom: 0)
        XCTAssertEqual(base(target), "origin/main")
    }

    /// A stale anchor — the log reloaded under the selection — must not index
    /// out of bounds; it degrades to selecting the clicked commit alone.
    func testAnOutOfRangeAnchorIsIgnored() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 1, extendingFrom: 99)
        XCTAssertEqual(shas(target), ["c2"])
    }

    func testPickingOutOfRangeSelectsNothing() {
        XCTAssertEqual(shas(.commits(repo: repo, log: log, picking: 9)), [])
        XCTAssertEqual(shas(.commits(repo: repo, log: GitLog(), picking: 0)), [])
    }

    // MARK: - All commits

    func testAllCommitsCoversTheWholeLog() {
        let target = DiffTarget.allCommits(repo: repo, log: log)
        XCTAssertEqual(shas(target), ["c3", "c2", "c1"])
        XCTAssertEqual(base(target), "origin/main")
        XCTAssertTrue(target.selectsAll(repo: repo, log: log))
    }

    func testAllCommitsOfAnEmptyLogSelectsNothing() {
        XCTAssertEqual(shas(.allCommits(repo: repo, log: GitLog())), [])
    }

    // MARK: - Highlighting

    func testEveryCommitInTheRunIsHighlighted() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 1, extendingFrom: 0)
        XCTAssertTrue(target.selects(repo: repo, sha: "c3"))
        XCTAssertTrue(target.selects(repo: repo, sha: "c2"))
        XCTAssertFalse(target.selects(repo: repo, sha: "c1"))
    }

    /// Two repos are listed at once under "All repos", so the same commit in a
    /// different one must not light up.
    func testAnotherRepoIsNotHighlighted() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 0)
        XCTAssertFalse(target.selects(repo: "other", sha: "c3"))
        XCTAssertFalse(target.selectsAll(repo: "other", log: log))
    }

    /// A partial run must not light up the "all commits" row.
    func testAPartialRunIsNotAllCommits() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 1, extendingFrom: 0)
        XCTAssertFalse(target.selectsAll(repo: repo, log: log))
    }

    func testWorktreeAndCommitScopesDoNotCrossOver() {
        let worktree = DiffTarget.worktree(repo: repo)
        XCTAssertTrue(worktree.selectsWorktree(repo: repo))
        XCTAssertFalse(worktree.selectsWorktree(repo: "other"))
        XCTAssertFalse(worktree.selects(repo: repo, sha: "c3"))
        XCTAssertFalse(worktree.selectsAll(repo: repo, log: log))
        XCTAssertNil(worktree.newestSha)
        XCTAssertNil(worktree.commitRange)

        let commits = DiffTarget.commits(repo: repo, log: log, picking: 0)
        XCTAssertFalse(commits.selectsWorktree(repo: repo))
        XCTAssertEqual(commits.repo, repo)
    }

    // MARK: - Labels

    func testASingleCommitIsLabelledWithItsSubject() {
        let label = DiffTarget.commits(repo: repo, log: log, picking: 1).label(in: log)
        XCTAssertTrue(label.contains("c2"), label)
        XCTAssertTrue(label.contains("second"), label)
    }

    func testARunIsLabelledWithItsSpan() {
        let label = DiffTarget.commits(repo: repo, log: log, picking: 2, extendingFrom: 0)
            .label(in: log)
        XCTAssertTrue(label.contains("3 commits"), label)
        XCTAssertTrue(label.contains("c1"), label)
        XCTAssertTrue(label.contains("c3"), label)
    }

    func testTheWorktreeScopeIsLabelled() {
        XCTAssertEqual(DiffTarget.worktree(repo: repo).label(in: log), "Working tree")
    }

    func testACommitRangeExposesItsEndpoints() {
        let target = DiffTarget.commits(repo: repo, log: log, picking: 1, extendingFrom: 0)
        XCTAssertEqual(target.commitRange?.from, "c1")
        XCTAssertEqual(target.commitRange?.to, "c3")
    }
}
