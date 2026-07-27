import XCTest
@testable import ExeDesktopApp

/// The local (non-SSH) worktree snapshot, run against a real repository.
///
/// This path had drifted from the remote one — it parsed status with its own
/// copy of the logic and omitted untracked files from the diff — so the checks
/// here deliberately mirror the remote command tests.
final class GitWorktreeStateTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(Self.git == nil, "git is not available")

        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try git("git init -q . && git config user.email t@example.com && git config user.name Test")
        try write("tracked.txt", "original\n")
        try git("git add . && git commit -qm init")
        try write("tracked.txt", "original\nmodified\n")
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    func testFindsTheRepoAndBranch() throws {
        let state = try XCTUnwrap(GitWorktree.state(for: repo))
        XCTAssertEqual(state.repoRoot.lastPathComponent, repo.lastPathComponent)
        XCTAssertNotNil(state.branch)
        XCTAssertFalse(state.isClean)
    }

    func testReportsNilOutsideARepository() throws {
        let plain = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        XCTAssertNil(GitWorktree.state(for: plain))
    }

    /// The defect: an untracked file was listed but had no section in the diff,
    /// so selecting it scrolled to nothing.
    func testUntrackedFileAppearsInTheDiff() throws {
        try write("untracked.txt", "brand new\n")
        let state = try XCTUnwrap(GitWorktree.state(for: repo))

        XCTAssertTrue(state.changes.map(\.path).contains("untracked.txt"))
        XCTAssertTrue(state.diff.contains("untracked.txt"), "no diff section for the new file")
        XCTAssertTrue(state.diff.contains("+brand new"), state.diff)
    }

    /// Tracked changes must still be there — the untracked sections are appended
    /// to the real diff, not substituted for it.
    func testTrackedChangesRemainInTheDiff() throws {
        try write("untracked.txt", "brand new\n")
        let state = try XCTUnwrap(GitWorktree.state(for: repo))

        XCTAssertTrue(state.diff.contains("+modified"), "lost the tracked diff")
        XCTAssertTrue(state.diff.contains("+brand new"), "lost the untracked diff")
    }

    /// Only untracked files get the `/dev/null` treatment. Applying it to
    /// everything would append a second, whole-file section for each tracked
    /// change — the same file listed twice, the second copy claiming every line
    /// was added.
    func testTrackedFilesAreNotAlsoDiffedAgainstDevNull() throws {
        try write("untracked.txt", "brand new\n")
        let diff = try XCTUnwrap(GitWorktree.state(for: repo)).diff

        XCTAssertEqual(occurrences(of: "diff --git a/tracked.txt", in: diff), 1,
                       "tracked file diffed twice:\n\(diff)")
        XCTAssertFalse(diff.contains("+original"),
                       "unchanged line shown as an addition:\n\(diff)")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// git collapses a new directory to a single `?? dir/` entry by default,
    /// which stands in for every file inside it and can't be opened.
    func testANewDirectoryIsListedAsIndividualFiles() throws {
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("newdir"), withIntermediateDirectories: true)
        try write("newdir/nested.txt", "nested\n")

        let paths = try XCTUnwrap(GitWorktree.state(for: repo)).changes.map(\.path)
        XCTAssertTrue(paths.contains("newdir/nested.txt"), "\(paths)")
        XCTAssertFalse(paths.contains("newdir/"), "\(paths)")
    }

    /// The duplicate parser that used to live here left git's quoting on, so a
    /// path with a space showed in the UI wrapped in literal quote marks — and
    /// never matched the diff section it was supposed to scroll to.
    func testPathsWithSpacesAreUnquoted() throws {
        try write("spaced name.txt", "content\n")
        let paths = try XCTUnwrap(GitWorktree.state(for: repo)).changes.map(\.path)

        XCTAssertTrue(paths.contains("spaced name.txt"), "\(paths)")
        XCTAssertFalse(paths.contains("\"spaced name.txt\""), "quoting was left on: \(paths)")
    }

    /// Non-ASCII names are escaped to octal by default, which is unreadable in
    /// the file list.
    func testNonASCIIPathsAreNotEscaped() throws {
        try write("café.txt", "content\n")
        let paths = try XCTUnwrap(GitWorktree.state(for: repo)).changes.map(\.path)
        XCTAssertTrue(paths.contains("café.txt"), "\(paths)")
    }

    /// Untracked-file diffs are gathered by a call that exits non-zero; an
    /// ignored file must still be left out of both lists.
    func testIgnoredFilesAreExcluded() throws {
        try write(".gitignore", "ignored.log\n")
        try write("ignored.log", "noise\n")

        let state = try XCTUnwrap(GitWorktree.state(for: repo))
        XCTAssertFalse(state.changes.map(\.path).contains("ignored.log"))
        // Matched on the diff header, not a bare substring: ".gitignore" is
        // itself untracked, so its contents — the line "ignored.log" — legitimately
        // appear in the diff as an added line.
        XCTAssertFalse(state.diff.contains("b/ignored.log"), state.diff)
    }

    func testACleanRepositoryHasNoChanges() throws {
        try git("git checkout -- tracked.txt")
        let state = try XCTUnwrap(GitWorktree.state(for: repo))
        XCTAssertTrue(state.isClean)
        XCTAssertTrue(state.diff.isEmpty, state.diff)
    }

    /// A subdirectory resolves to the repository root, since the terminal's cwd
    /// is wherever the user happens to be.
    func testASubdirectoryResolvesToTheRepoRoot() throws {
        let sub = repo.appendingPathComponent("deep/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let state = try XCTUnwrap(GitWorktree.state(for: sub))
        XCTAssertEqual(state.repoRoot.lastPathComponent, repo.lastPathComponent)
    }

    // MARK: - Harness

    private static let git: String? = ["/usr/bin/git", "/opt/homebrew/bin/git", "/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func git(_ command: String, line: UInt = #line) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cd \"$0\" && \(command)", repo.path]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture command failed: \(command)",
                       file: #filePath, line: line)
    }

    private func write(_ path: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: repo.appendingPathComponent(path))
    }
}
