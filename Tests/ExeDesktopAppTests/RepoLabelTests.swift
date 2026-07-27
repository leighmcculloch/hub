import XCTest
@testable import ExeDesktopApp

/// Shortening repo paths for the sidebar.
final class RepoLabelTests: XCTestCase {

    /// An ordinary repo is already short; rewriting it would only lose
    /// information.
    func testAPlainRepoIsUnchanged() {
        XCTAssertEqual(RepoLabel.short("hub"), "hub")
        XCTAssertEqual(RepoLabel.short("some/nested/repo"), "some/nested/repo")
        XCTAssertEqual(RepoLabel.short("spaced repo"), "spaced repo")
    }

    /// The path that motivated this: the middle is boilerplate, and it pushes
    /// the branch name out of a narrow sidebar.
    func testAWorktreeIsShortenedToRepoAndBranch() {
        XCTAssertEqual(
            RepoLabel.short("hub/.claude/worktrees/feature-a"),
            "hub › feature-a")
    }

    /// Branch names contain slashes, and everything after the marker is the
    /// branch — not just the first segment.
    func testABranchNameWithSlashesIsKeptWhole() {
        XCTAssertEqual(
            RepoLabel.short("hub/.claude/worktrees/leigh/fix-thing"),
            "hub › leigh/fix-thing")
    }

    func testTheRepoPartCanItselfBeNested() {
        XCTAssertEqual(
            RepoLabel.short("org/hub/.claude/worktrees/wip"),
            "org/hub › wip")
    }

    /// A path that merely mentions the marker without a branch after it is not
    /// a worktree, and must not be mangled into a dangling label.
    func testAMarkerWithNothingAfterItIsNotAWorktree() {
        for path in ["hub/.claude/worktrees/", "/.claude/worktrees/x"] {
            XCTAssertEqual(RepoLabel.short(path), path, path)
            XCTAssertFalse(RepoLabel.isWorktree(path), path)
        }
    }

    /// `.claude/worktrees` at the very top of the home directory has no owning
    /// repo to name. `listRepos` emits home-relative paths with no leading
    /// slash, so that spelling is the one that can actually turn up.
    func testAMarkerWithNoRepoBeforeItIsNotAWorktree() {
        XCTAssertEqual(RepoLabel.short(".claude/worktrees/x"), ".claude/worktrees/x")
        XCTAssertFalse(RepoLabel.isWorktree(".claude/worktrees/x"))
        XCTAssertFalse(RepoLabel.isWorktree("/.claude/worktrees/x"))
    }

    /// A directory that merely resembles the marker shouldn't trigger it.
    func testASimilarPathIsNotTreatedAsAWorktree() {
        for path in ["hub/.claude/worktree/x", "hub/claude/worktrees/x",
                     "hub/.claude/worktreesx/y"] {
            XCTAssertEqual(RepoLabel.short(path), path, path)
        }
    }

    func testIsWorktreeAgreesWithShort() {
        XCTAssertTrue(RepoLabel.isWorktree("hub/.claude/worktrees/a"))
        XCTAssertFalse(RepoLabel.isWorktree("hub"))
    }

    /// The chevron is silent to a screen reader, so the spoken form has to say
    /// what the relationship is.
    func testTheSpokenFormNamesTheRelationship() {
        XCTAssertEqual(
            RepoLabel.spoken("hub/.claude/worktrees/feature-a"),
            "hub worktree feature-a")
        XCTAssertEqual(RepoLabel.spoken("hub"), "hub")
    }

    /// Two worktrees of different repos must not collapse to the same label —
    /// they are separate rows in the sidebar.
    func testDifferentWorktreesGetDifferentLabels() {
        XCTAssertNotEqual(
            RepoLabel.short("a/.claude/worktrees/fix"),
            RepoLabel.short("b/.claude/worktrees/fix"))
    }

    /// The label is display-only; the original path is what git commands use,
    /// so nothing may depend on being able to reverse it.
    func testTheMarkerMatchesWhatListReposProduces() {
        // `listRepos` returns home-relative paths with no leading slash.
        let produced = "hub/.claude/worktrees/feature-a"
        XCTAssertTrue(produced.contains(RepoLabel.worktreeMarker))
        XCTAssertTrue(RepoLabel.isWorktree(produced))
    }
}
