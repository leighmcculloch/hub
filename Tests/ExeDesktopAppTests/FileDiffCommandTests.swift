import XCTest
@testable import ExeDesktopApp

/// The remote command behind the sidebar's diff pane, exercised against real
/// `git` through a real shell.
///
/// Asserting on the command *string* would prove nothing here: the failures
/// that matter are git's behaviour (an untracked file has no HEAD blob to diff
/// against) and shell quoting (a path with a space or a quote in it). Both only
/// show up when the thing actually runs.
final class FileDiffCommandTests: XCTestCase {
    private var home: URL!
    private let repo = "work repo"

    override func setUpWithError() throws {
        try XCTSkipIf(Self.git == nil, "git is not available")

        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = home.appendingPathComponent(repo, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A repo name with a space is deliberate: an unquoted interpolation
        // would silently diff the wrong path.
        try run("git init -q . && git config user.email t@example.com && git config user.name Test")
        try write("tracked.txt", "original\n")
        try run("git add . && git commit -qm init")

        try write("tracked.txt", "original\nmodified\n")
        try write("untracked.txt", "brand new\n")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("newdir"), withIntermediateDirectories: true)
        try write("newdir/nested.txt", "in a new directory\n")
        try write("spaced name.txt", "has a space\n")
        try write("quo'te.txt", "has a quote\n")
        try write("staged.txt", "staged addition\n")
        try run("git add staged.txt")
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    /// The bug this fixes: an untracked file was listed in the sidebar and then
    /// showed an empty pane, because `git diff HEAD` has nothing to say about it.
    func testUntrackedFileProducesADiff() throws {
        let diff = try diff(of: "untracked.txt")
        XCTAssertFalse(diff.isEmpty, "an untracked file must not render as an empty diff")
        XCTAssertTrue(diff.contains("+brand new"), diff)
        XCTAssertTrue(diff.contains("new file"), diff)
    }

    func testUntrackedFileInANewDirectoryProducesADiff() throws {
        let diff = try diff(of: "newdir/nested.txt")
        XCTAssertTrue(diff.contains("+in a new directory"), diff)
    }

    func testModifiedTrackedFileStillProducesADiff() throws {
        let diff = try diff(of: "tracked.txt")
        XCTAssertTrue(diff.contains("+modified"), diff)
        XCTAssertFalse(diff.contains("+original"), "unchanged lines are context, not additions")
    }

    /// Staged-but-uncommitted files are tracked, so they take the HEAD path even
    /// though they are new.
    func testStagedNewFileProducesADiff() throws {
        XCTAssertTrue(try diff(of: "staged.txt").contains("+staged addition"))
    }

    /// Deleting from the worktree only — the file is still in the index.
    func testUnstagedDeletionProducesADiff() throws {
        try FileManager.default.removeItem(
            at: home.appendingPathComponent(repo).appendingPathComponent("tracked.txt"))
        XCTAssertTrue(try diff(of: "tracked.txt").contains("-original"))
    }

    /// `git rm` also drops the file from the index, so asking whether a path is
    /// *in the index* would misroute this to the untracked path and show
    /// nothing. The predicate has to be "is it untracked".
    func testStagedDeletionProducesADiff() throws {
        // -f because the fixture leaves local modifications on this file.
        try run("git rm -qf tracked.txt")
        let diff = try diff(of: "tracked.txt")
        XCTAssertTrue(diff.contains("-original"), diff)
    }

    /// An ignored file is untracked as far as the worktree goes, but git won't
    /// list it and neither should the pane.
    func testIgnoredFileProducesNoOutput() throws {
        try write(".gitignore", "ignored.log\n")
        try write("ignored.log", "noise\n")
        XCTAssertTrue(try diff(of: "ignored.log").isEmpty)
    }

    // MARK: - Quoting

    /// Both the repo directory and these filenames contain characters a bare
    /// `"$HOME/\(path)"` interpolation would mangle.
    func testPathsWithSpacesAreDiffed() throws {
        XCTAssertTrue(try diff(of: "spaced name.txt").contains("+has a space"))
    }

    func testPathsWithQuotesAreDiffed() throws {
        XCTAssertTrue(try diff(of: "quo'te.txt").contains("+has a quote"))
    }

    /// A hostile path must not be able to run anything: the command is built
    /// from `git status` output, which a cloned repo controls.
    ///
    /// Each of these breaks out of a *different* quoting style, which is the
    /// point — wrapping the path in double quotes passes the `;` case, because
    /// `;` and `#` are inert there, while `$(…)` and backticks still execute.
    func testAPathCannotInjectAShellCommand() throws {
        let hostile = [
            "x'; touch %@ #",
            "x$(touch %@)",
            "x`touch %@`",
            "x\"; touch %@ #",
        ]
        for (index, template) in hostile.enumerated() {
            let marker = home.appendingPathComponent("pwned-\(index)").path
            _ = try diff(of: template.replacingOccurrences(of: "%@", with: marker))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                           "path escaped its quoting and ran a command: \(template)")
        }
    }

    /// The same characters have to survive as *data* — a real file named with a
    /// dollar sign should still diff, not come back blank.
    func testPathsWithShellMetacharactersAreDiffed() throws {
        for name in ["dollar $VAR.txt", "back`tick.txt", "sub$(x).txt"] {
            try write(name, "content of \(name)\n")
            XCTAssertTrue(try diff(of: name).contains("+content of \(name)"),
                          "did not diff \(name)")
        }
    }

    /// A file that simply isn't there should come back blank rather than
    /// leaking git's error text into the diff pane.
    func testAMissingFileProducesNoOutput() throws {
        XCTAssertTrue(try diff(of: "does-not-exist.txt").isEmpty)
    }

    /// `run` discards any non-zero exit, and `--no-index` exits 1 whenever it
    /// prints a diff — so the command has to end up at status 0 regardless.
    func testTheCommandAlwaysExitsZero() throws {
        for file in ["untracked.txt", "tracked.txt", "does-not-exist.txt"] {
            XCTAssertEqual(try shell(RemoteGit.fileDiffCommand(repo: repo, file: file)).status, 0,
                           "non-zero exit for \(file) would be discarded as a failure")
        }
    }

    /// A repo that isn't there is a normal transient state (the VM is still
    /// cloning); it must not surface as an error in the pane.
    func testAMissingRepoProducesNoOutput() throws {
        let result = try shell(RemoteGit.fileDiffCommand(repo: "no-such-repo", file: "a.txt"))
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty, result.output)
    }

    // MARK: - The status command feeding the file list

    /// The other half of the same bug: by default git reports a new directory
    /// as one `?? newdir/` entry, so ten new files showed as a single row that
    /// no diff could be opened for.
    func testANewDirectoryIsListedAsIndividualFiles() throws {
        let status = GitRepoStatus.parse(try shell(RemoteGit.statusCommand(repo: repo)).output)
        let paths = status.changes.map(\.path)

        XCTAssertTrue(paths.contains("newdir/nested.txt"), "\(paths)")
        XCTAssertFalse(paths.contains("newdir/"), "the directory itself must not be a row: \(paths)")
    }

    /// The status and numstat halves must agree on how a path is spelled, or the
    /// line counts silently fail to attach.
    func testStatusAndNumstatAgreeOnAPathWithASpace() throws {
        try run("git add 'spaced name.txt' && git commit -qm add")
        try write("spaced name.txt", "has a space\nand another line\n")

        let status = GitRepoStatus.parse(try shell(RemoteGit.statusCommand(repo: repo)).output)
        XCTAssertTrue(status.changes.map(\.path).contains("spaced name.txt"))
        XCTAssertEqual(status.stats["spaced name.txt"]?.added, 1)
    }

    /// With rename detection on, status writes `old -> new` while `--numstat`
    /// writes `{old => new}/file`. Neither is a path, and the two never match
    /// each other, so the row is unopenable *and* its line counts go missing.
    func testARenameYieldsRealPathsWithAttachedStats() throws {
        try run("git add . && git commit -qm base")
        try run("git mv tracked.txt renamed.txt")
        try write("renamed.txt", "original\nmodified\nand more\n")

        let status = GitRepoStatus.parse(try shell(RemoteGit.statusCommand(repo: repo)).output)
        let paths = status.changes.map(\.path)

        XCTAssertTrue(paths.contains("renamed.txt"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.contains("->") || $0.contains("=>") }, "\(paths)")
        XCTAssertNotNil(status.stats["renamed.txt"], "line counts did not attach: \(status.stats)")
    }

    /// The rename target is tracked, so its diff must come from HEAD rather than
    /// the untracked `/dev/null` path.
    func testARenamedFileProducesADiff() throws {
        try run("git add . && git commit -qm base")
        try run("git mv tracked.txt renamed.txt")
        XCTAssertFalse(try diff(of: "renamed.txt").isEmpty)
    }

    func testStatusSeesEveryKindOfChange() throws {
        let status = GitRepoStatus.parse(try shell(RemoteGit.statusCommand(repo: repo)).output)
        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })

        XCTAssertEqual(byPath["tracked.txt"]?.isUntracked, false)
        XCTAssertEqual(byPath["untracked.txt"]?.isUntracked, true)
        XCTAssertEqual(byPath["staged.txt"]?.isUntracked, false)
    }

    // MARK: - The log half of the status command

    /// The fixture's default branch is whatever `git init` chose, so it is
    /// renamed to a known one — the log's whole job is to stop at that branch.
    private func branchAhead() throws {
        try run("git branch -M master && git checkout -qb feature")
        try write("first.txt", "one\n")
        try run("git add first.txt && git commit -qm 'first on the branch'")
        try write("second.txt", "two\n")
        try run("git add second.txt && git commit -qm 'second on the branch'")
    }

    private func log() throws -> GitLog {
        GitRepoStatus.parse(try shell(RemoteGit.statusCommand(repo: repo)).output).log
    }

    func testListsOnlyTheCommitsAheadOfTheDefaultBranch() throws {
        try branchAhead()
        let log = try log()

        XCTAssertEqual(log.base, "master")
        XCTAssertEqual(log.commits.map(\.subject),
                       ["second on the branch", "first on the branch"],
                       "newest first, and the default branch's own commits excluded")
    }

    func testCommitFieldsAreFilledIn() throws {
        try branchAhead()
        let newest = try XCTUnwrap(try log().commits.first)

        // Not compared to the fixture's configured name: `GIT_AUTHOR_NAME` in
        // the environment outranks it, and which field landed where is what
        // matters here.
        XCTAssertFalse(newest.sha.isEmpty)
        XCTAssertFalse(newest.author.isEmpty)
        XCTAssertTrue(newest.relativeDate.hasSuffix("ago"), newest.relativeDate)
    }

    /// On the default branch there is nothing ahead of it — the list is empty
    /// rather than the repo's whole history.
    func testTheDefaultBranchItselfHasNoCommitsAhead() throws {
        try run("git branch -M master")
        let log = try log()

        XCTAssertEqual(log.base, "master")
        XCTAssertTrue(log.commits.isEmpty, "\(log.commits.map(\.subject))")
    }

    /// The format has to survive whatever a subject contains, including the
    /// shell metacharacters the command is assembled from.
    func testASubjectWithMetacharactersSurvives() throws {
        try run("git branch -M master && git checkout -qb feature")
        try run("git commit --allow-empty -qm \"don't \\$break; 100% \\`ok\\`\"")

        XCTAssertEqual(try log().commits.first?.subject, "don't $break; 100% `ok`")
    }

    /// With no `main` or `master` anywhere there is nothing to stop at, so the
    /// whole history is listed and the blank base says so.
    func testWithoutADefaultBranchTheWholeHistoryIsListed() throws {
        try run("git branch -M some-other-name")
        let log = try log()

        XCTAssertEqual(log.base, "")
        XCTAssertEqual(log.commits.map(\.subject), ["init"])
    }

    /// A repo with no commits at all still has untracked files worth listing.
    /// `run` throws away a non-zero exit, and both `diff HEAD` and `log` fail
    /// here, so the command has to end at status 0 regardless.
    func testAnEmptyRepositoryStillReportsItsUntrackedFiles() throws {
        let fresh = "fresh repo"
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(fresh), withIntermediateDirectories: true)
        let result = try shell("cd \"$HOME\"/'\(fresh)' && git init -q . && echo hi > new.txt")
        XCTAssertEqual(result.status, 0)

        let status = try shell(RemoteGit.statusCommand(repo: fresh))
        XCTAssertEqual(status.status, 0, "a non-zero exit is discarded, blanking the file list")
        XCTAssertTrue(GitRepoStatus.parse(status.output).changes.map(\.path).contains("new.txt"))
    }

    // MARK: - Range diffs

    func testARangeDiffCoversEveryCommitInIt() throws {
        try branchAhead()
        let log = try log()
        // The whole branch: from the default branch to its newest commit.
        let diff = try shell(RemoteGit.rangeDiffCommand(
            repo: repo, from: log.exclusiveBase(forOldest: 1), to: log.commits[0].sha)).output

        XCTAssertTrue(diff.contains("+one"), diff)
        XCTAssertTrue(diff.contains("+two"), diff)
    }

    /// A single commit is a range of one: the commit before it, to it.
    func testASingleCommitDiffExcludesTheOneBeforeIt() throws {
        try branchAhead()
        let log = try log()
        let diff = try shell(RemoteGit.rangeDiffCommand(
            repo: repo, from: log.exclusiveBase(forOldest: 0), to: log.commits[0].sha)).output

        XCTAssertTrue(diff.contains("+two"), diff)
        XCTAssertFalse(diff.contains("+one"), "the earlier commit leaked into the range:\n\(diff)")
    }

    /// A revision reaches the command as a branch name out of the repo, and git
    /// permits `;` and `>` in one. Unquoted, this branch would end the command
    /// and create a file.
    func testARangeDiffQuotesItsRevisions() throws {
        let hostile = "odd;>pwned"
        try run("git branch -M master && git checkout -qb '\(hostile)'")
        try write("first.txt", "one\n")
        try run("git add first.txt && git commit -qm 'on the odd branch'")

        let diff = try shell(RemoteGit.rangeDiffCommand(
            repo: repo, from: "master", to: hostile)).output
        XCTAssertTrue(diff.contains("+one"), diff)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.appendingPathComponent("pwned").path),
            "the revision escaped its quoting")
    }

    // MARK: - Harness

    private static let git: String? = ["/usr/bin/git", "/opt/homebrew/bin/git", "/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func diff(of file: String) throws -> String {
        try shell(RemoteGit.fileDiffCommand(repo: repo, file: file)).output
    }

    /// Run inside the repo, for fixture setup. Fails the test on a non-zero
    /// exit — a setup command that quietly does nothing would leave the
    /// assertions below passing against a fixture that isn't what it claims.
    private func run(_ command: String, line: UInt = #line) throws {
        let result = try shell("cd \"$HOME\"/'\(repo)' && \(command)")
        XCTAssertEqual(result.status, 0, "fixture command failed: \(command)",
                       file: #filePath, line: line)
    }

    /// Runs `command` under `/bin/sh` with `HOME` pointed at the fixture, which
    /// is what the real remote shell provides.
    private func shell(_ command: String) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        // Keep a developer's own git config out of the fixture's behaviour.
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    private func write(_ path: String, _ contents: String) throws {
        try Data(contents.utf8).write(
            to: home.appendingPathComponent(repo).appendingPathComponent(path))
    }
}
