import XCTest
@testable import ExeDesktopApp

/// Parsing of the combined `status --porcelain=v1` + `diff --numstat HEAD`
/// output that the diff sidebar fetches in one SSH round trip.
final class GitRepoStatusTests: XCTestCase {

    private func output(status: String, numstat: String) -> String {
        "\(status)\n\(GitRepoStatus.separator)\n\(numstat)\n"
    }

    func testParsesChangesAndLineCounts() {
        let parsed = GitRepoStatus.parse(output(
            status: " M Sources/a.swift\n?? new.txt",
            numstat: "12\t3\tSources/a.swift"))

        XCTAssertEqual(parsed.changes.count, 2)
        XCTAssertEqual(parsed.changes[0].status, " M")
        XCTAssertEqual(parsed.changes[0].path, "Sources/a.swift")
        XCTAssertEqual(parsed.stats["Sources/a.swift"], GitLineStat(added: 12, removed: 3))
    }

    /// Untracked files never appear in `git diff`, so they legitimately have no
    /// counts and the row must render without them.
    func testUntrackedFilesHaveNoStats() {
        let parsed = GitRepoStatus.parse(output(status: "?? new.txt", numstat: ""))
        XCTAssertTrue(parsed.changes[0].isUntracked)
        XCTAssertNil(parsed.stats["new.txt"])
    }

    /// git reports "-" counts for binary files.
    func testBinaryFilesParseAsBinary() {
        let parsed = GitRepoStatus.parse(output(status: " M logo.png", numstat: "-\t-\tlogo.png"))
        let stat = parsed.stats["logo.png"]
        XCTAssertEqual(stat, GitLineStat(added: nil, removed: nil))
        XCTAssertTrue(stat?.isBinary ?? false)
    }

    /// Regression: real `git status` quotes paths with spaces while
    /// `--numstat` does not, which silently broke the stat lookup.
    func testQuotedStatusPathsMatchUnquotedNumstatPaths() {
        let parsed = GitRepoStatus.parse(output(
            status: " M \"sub dir/sp ace.txt\"",
            numstat: "1\t0\tsub dir/sp ace.txt"))
        XCTAssertEqual(parsed.changes[0].path, "sub dir/sp ace.txt")
        XCTAssertEqual(parsed.stats[parsed.changes[0].path], GitLineStat(added: 1, removed: 0))
    }

    func testUnquotePathHandlesEscapes() {
        XCTAssertEqual(GitRepoStatus.unquotePath("plain.txt"), "plain.txt")
        XCTAssertEqual(GitRepoStatus.unquotePath("\"a b.txt\""), "a b.txt")
        XCTAssertEqual(GitRepoStatus.unquotePath("\"say \\\"hi\\\".txt\""), "say \"hi\".txt")
    }

    func testPathsContainingSpacesSurvive() {
        let parsed = GitRepoStatus.parse(output(
            status: " M my dir/a b.txt",
            numstat: "1\t0\tmy dir/a b.txt"))
        XCTAssertEqual(parsed.changes[0].path, "my dir/a b.txt")
        XCTAssertEqual(parsed.stats["my dir/a b.txt"], GitLineStat(added: 1, removed: 0))
    }

    /// A clean repo, and a repo where the numstat half is missing entirely,
    /// must both parse rather than trip over the separator.
    func testHandlesEmptyAndSeparatorlessOutput() {
        XCTAssertEqual(GitRepoStatus.parse(""), GitRepoStatus())
        let statusOnly = GitRepoStatus.parse(" M a.swift")
        XCTAssertEqual(statusOnly.changes.count, 1)
        XCTAssertTrue(statusOnly.stats.isEmpty)
    }

    func testIgnoresMalformedNumstatRows() {
        let parsed = GitRepoStatus.parse(output(status: " M a", numstat: "garbage\n1\t2\ta"))
        XCTAssertEqual(parsed.stats.count, 1)
        XCTAssertEqual(parsed.stats["a"], GitLineStat(added: 1, removed: 2))
    }

    // MARK: - The log half

    private func output(status: String, numstat: String, base: String, log: String) -> String {
        "\(status)\n\(GitRepoStatus.separator)\n\(numstat)\n"
            + "\(GitRepoStatus.logSeparator)\n\(base)\n\(log)"
    }

    private func commit(_ sha: String, _ subject: String) -> String {
        [sha, subject, "Ada", "2 days ago"].joined(separator: "\u{1f}")
    }

    func testParsesTheLogAndItsBase() {
        let parsed = GitRepoStatus.parse(output(
            status: " M a.swift",
            numstat: "1\t0\ta.swift",
            base: "origin/main",
            log: [commit("a1b2c3d", "second"), commit("e4f5a6b", "first")].joined(separator: "\n")))

        XCTAssertEqual(parsed.changes.count, 1)
        XCTAssertEqual(parsed.log.base, "origin/main")
        XCTAssertEqual(parsed.log.commits.map(\.subject), ["second", "first"])
    }

    /// No default branch resolved: the base line is legitimately blank, and it
    /// must not be mistaken for the first commit.
    func testAnEmptyBaseLineIsNotReadAsACommit() {
        let parsed = GitRepoStatus.parse(output(
            status: "", numstat: "", base: "", log: commit("a1b2c3d", "only")))

        XCTAssertEqual(parsed.log.base, "")
        XCTAssertEqual(parsed.log.commits.map(\.sha), ["a1b2c3d"])
    }

    /// A branch level with its default branch has a base but no commits.
    func testABranchWithNoCommitsAheadStillReportsItsBase() {
        let parsed = GitRepoStatus.parse(output(status: "", numstat: "", base: "master", log: ""))
        XCTAssertEqual(parsed.log.base, "master")
        XCTAssertTrue(parsed.log.commits.isEmpty)
    }

    /// The local worktree path reuses this parser for status alone, so output
    /// that stops before the log separator must still parse.
    func testOutputWithoutALogSectionParses() {
        let parsed = GitRepoStatus.parse(output(status: " M a.swift", numstat: "1\t0\ta.swift"))
        XCTAssertEqual(parsed.changes.count, 1)
        XCTAssertEqual(parsed.log, GitLog())
    }
}
