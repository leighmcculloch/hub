import XCTest
@testable import ExeDesktopApp

/// Parsing of `git log --pretty=format:…` and the range arithmetic the sidebar
/// uses to turn a run of selected commits into one `git diff`.
final class GitLogTests: XCTestCase {
    private let separator = "\u{1f}"

    private func line(_ sha: String, _ subject: String, _ author: String = "Ada",
                      _ date: String = "2 days ago") -> String {
        [sha, subject, author, date].joined(separator: separator)
    }

    func testParsesCommitFields() {
        let commits = GitLog.parse(line("a1b2c3d", "fix the parser", "Ada", "3 hours ago"))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].sha, "a1b2c3d")
        XCTAssertEqual(commits[0].subject, "fix the parser")
        XCTAssertEqual(commits[0].author, "Ada")
        XCTAssertEqual(commits[0].relativeDate, "3 hours ago")
    }

    /// The whole point of a non-printing field separator: a subject may contain
    /// anything a person can type, including the characters a delimiter like
    /// "|" or tab would be mistaken for.
    func testSubjectsMayContainAnyPrintableCharacter() {
        let awkward = "fix: don't split on | or \t or ›  (100% sure)"
        let commits = GitLog.parse(line("abc1234", awkward))
        XCTAssertEqual(commits.first?.subject, awkward)
    }

    func testSkipsMalformedLines() {
        let text = [line("a1b2c3d", "good"), "garbage", "", line("e4f5a6b", "also good")]
            .joined(separator: "\n")
        XCTAssertEqual(GitLog.parse(text).map(\.sha), ["a1b2c3d", "e4f5a6b"])
    }

    func testEmptyOutputIsNoCommits() {
        XCTAssertTrue(GitLog.parse("").isEmpty)
    }

    // MARK: - Range

    func testRangeStopsAtTheDefaultBranch() {
        XCTAssertEqual(GitLog.range(base: "origin/main"), "origin/main..HEAD")
    }

    /// With no default branch to stop at, the whole history is the log.
    func testRangeWithoutABaseIsPlainHEAD() {
        XCTAssertEqual(GitLog.range(base: ""), "HEAD")
    }

    // MARK: - The left-hand side of a range diff

    private var log: GitLog {
        GitLog(
            commits: [
                GitCommit(sha: "newest", subject: "c", author: "Ada", relativeDate: "1 hour ago"),
                GitCommit(sha: "middle", subject: "b", author: "Ada", relativeDate: "2 hours ago"),
                GitCommit(sha: "oldest", subject: "a", author: "Ada", relativeDate: "3 hours ago"),
            ],
            base: "origin/main")
    }

    /// A selection that stops short of the end diffs against the next commit
    /// down the list.
    func testBaseOfAPartialRangeIsTheNextOlderCommit() {
        XCTAssertEqual(log.exclusiveBase(forOldest: 1), "oldest")
    }

    /// Reaching the end of the list means the branch's whole work, so the base
    /// is the default branch itself. Naming `oldest^` instead would fail on a
    /// branch whose oldest commit is the repository's first.
    func testBaseOfTheWholeBranchIsTheDefaultBranch() {
        XCTAssertEqual(log.exclusiveBase(forOldest: 2), "origin/main")
    }

    /// Without a default branch there is nothing to name but the parent.
    func testBaseFallsBackToTheParentWhenThereIsNoDefaultBranch() {
        var unrooted = log
        unrooted.base = ""
        XCTAssertEqual(unrooted.exclusiveBase(forOldest: 2), "oldest^")
    }
}
