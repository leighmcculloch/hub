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

    func testStatusSeesEveryKindOfChange() throws {
        let status = GitRepoStatus.parse(try shell(RemoteGit.statusCommand(repo: repo)).output)
        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })

        XCTAssertEqual(byPath["tracked.txt"]?.isUntracked, false)
        XCTAssertEqual(byPath["untracked.txt"]?.isUntracked, true)
        XCTAssertEqual(byPath["staged.txt"]?.isUntracked, false)
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
