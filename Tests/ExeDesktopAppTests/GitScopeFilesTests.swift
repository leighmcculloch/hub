import XCTest
@testable import ExeDesktopApp

/// The file list of a commit scope: the parser behind it, and the remote
/// commands that produce its input, exercised against real `git` through a
/// real shell — asserting on command strings would prove nothing about git's
/// behaviour or the quoting.
final class GitScopeFilesTests: XCTestCase {

    // MARK: - Parsing

    func testParsesNameStatusAndNumstat() {
        let output = "M\tsrc/main.swift\nA\tREADME.md\n"
            + GitScopeFiles.separator + "\n"
            + "12\t2\tsrc/main.swift\n4\t0\tREADME.md\n"

        let files = GitScopeFiles.parse(output)

        XCTAssertEqual(files.changes.map(\.path), ["src/main.swift", "README.md"])
        XCTAssertEqual(files.changes.map(\.status), ["M ", "A "],
                       "a name-status letter occupies the index slot of the porcelain code")
        XCTAssertEqual(files.stats["src/main.swift"], GitLineStat(added: 12, removed: 2))
        XCTAssertEqual(files.stats["README.md"], GitLineStat(added: 4, removed: 0))
    }

    /// Binary files are `-` in both count columns, not a number.
    func testBinaryCountsAreNil() {
        let output = "M\tlogo.png\n" + GitScopeFiles.separator + "\n-\t-\tlogo.png\n"
        let files = GitScopeFiles.parse(output)
        XCTAssertEqual(files.stats["logo.png"], GitLineStat(added: nil, removed: nil))
        XCTAssertTrue(files.stats["logo.png"]?.isBinary ?? false)
    }

    /// `status` quotes paths with specials; the parser unquotes them so the
    /// row's path is one that exists.
    func testAQuotedPathIsUnquoted() {
        let output = "M\t\"spaced name.txt\"\n" + GitScopeFiles.separator + "\n"
            + "1\t1\tspaced name.txt\n"
        let files = GitScopeFiles.parse(output)
        XCTAssertEqual(files.changes.first?.path, "spaced name.txt")
        XCTAssertEqual(files.stats["spaced name.txt"], GitLineStat(added: 1, removed: 1))
    }

    /// An empty range — or an unresolvable one, where git printed nothing —
    /// is a valid, empty result rather than a parse failure.
    func testEmptyOutputParsesAsEmpty() {
        XCTAssertEqual(GitScopeFiles.parse(""), GitScopeFiles())
        XCTAssertEqual(
            GitScopeFiles.parse("\n" + GitScopeFiles.separator + "\n"), GitScopeFiles())
    }

    /// Renames are turned off in the command, but a `R100` line that slips
    /// through must degrade to a readable row, not a crash.
    func testARenameLineDegradesGracefully() {
        let output = "R100\told.txt\tnew.txt\n" + GitScopeFiles.separator + "\n"
        let files = GitScopeFiles.parse(output)
        XCTAssertEqual(files.changes.count, 1)
        XCTAssertEqual(files.changes.first?.status, "R ")
    }

    // MARK: - The commands, against real git

    private var home: URL!
    private let repo = "scope repo"

    override func setUpWithError() throws {
        try XCTSkipIf(Self.git == nil, "git is not available")

        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(repo, isDirectory: true), withIntermediateDirectories: true)

        try run("git init -q . && git config user.email t@example.com && git config user.name Test"
                + " && git branch -M master")
        try write("base.txt", "base\n")
        try run("git add . && git commit -qm init")

        // Two commits ahead of master: the fixture a commit scope is read from.
        try run("git checkout -qb feature")
        try write("first.txt", "one\n")
        try run("git add first.txt && git commit -qm 'first on the branch'")
        try write("first.txt", "one\none more\n")
        try write("second.txt", "two\n")
        try run("git add . && git commit -qm 'second on the branch'")
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    /// The whole branch as one scope: both commits' files, with their letters
    /// and line counts attached.
    func testScopeFilesCoversEveryCommitInTheRange() throws {
        let files = GitScopeFiles.parse(
            try shell(RemoteGit.scopeFilesCommand(repo: repo, from: "master", to: "HEAD")).output)
        let byPath = Dictionary(uniqueKeysWithValues: files.changes.map { ($0.path, $0) })

        XCTAssertEqual(Set(files.changes.map(\.path)), ["first.txt", "second.txt"])
        XCTAssertEqual(byPath["first.txt"]?.status, "A ",
                       "a range diff collapses its endpoints: the file didn't exist at the base")
        XCTAssertEqual(byPath["second.txt"]?.status, "A ")
        XCTAssertEqual(files.stats["first.txt"], GitLineStat(added: 2, removed: 0))
        XCTAssertEqual(files.stats["second.txt"], GitLineStat(added: 1, removed: 0))
    }

    /// A single-commit scope excludes the commit before it.
    func testASingleCommitScopeListsOnlyItsOwnFiles() throws {
        let files = GitScopeFiles.parse(
            try shell(RemoteGit.scopeFilesCommand(repo: repo, from: "HEAD~1", to: "HEAD")).output)
        let byPath = Dictionary(uniqueKeysWithValues: files.changes.map { ($0.path, $0) })

        XCTAssertEqual(byPath["first.txt"]?.status, "M ")
        XCTAssertEqual(byPath["second.txt"]?.status, "A ")
    }

    /// The per-file diff within a range must not leak the range's other files.
    func testARangeFileDiffCoversOnlyThatFile() throws {
        let diff = try shell(RemoteGit.rangeFileDiffCommand(
            repo: repo, from: "master", to: "HEAD", file: "first.txt")).output

        XCTAssertTrue(diff.contains("+one"), diff)
        XCTAssertFalse(diff.contains("second.txt"), "another file leaked in:\n\(diff)")
    }

    /// `run` discards a non-zero exit, so the command has to end at status 0
    /// even when the range can't be resolved.
    func testScopeFilesCommandAlwaysExitsZero() throws {
        for (from, to) in [("master", "HEAD"), ("no-such-ref", "HEAD")] {
            XCTAssertEqual(
                try shell(RemoteGit.scopeFilesCommand(repo: repo, from: from, to: to)).status, 0,
                "a non-zero exit for \(from)..\(to) would be discarded as a failure")
        }
    }

    /// A revision reaches the command as a branch name out of the repo, and
    /// git permits `;` and `>` in one — unquoted, this would end the command
    /// and create a file.
    func testScopeFilesCommandQuotesItsRevisions() throws {
        let result = try shell(RemoteGit.scopeFilesCommand(
            repo: repo, from: "master", to: "odd;>pwned"))
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.appendingPathComponent("pwned").path),
            "the revision escaped its quoting")
    }

    /// The whole-worktree diff behind the worktree scope: untracked files are
    /// in the sidebar's file list, so they must be in the diff too.
    func testRepoDiffIncludesUntrackedFiles() throws {
        try write("untracked.txt", "brand new\n")
        let result = try shell(RemoteGit.repoDiffCommand(repo: repo))

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("+brand new"), result.output)
        XCTAssertTrue(result.output.contains("new file"), result.output)
    }

    /// An untracked file whose name needs quoting must survive the loop as
    /// data, not break it.
    func testRepoDiffIncludesAnUntrackedFileWithASpace() throws {
        try write("spaced name.txt", "has a space\n")
        XCTAssertTrue(try shell(RemoteGit.repoDiffCommand(repo: repo)).output
            .contains("+has a space"))
    }

    /// A missing repo is a normal transient state (the VM is still cloning);
    /// it must produce no output and no error exit.
    func testRepoDiffOfAMissingRepoProducesNoOutput() throws {
        let result = try shell(RemoteGit.repoDiffCommand(repo: "no-such-repo"))
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty, result.output)
    }

    // MARK: - Harness

    private static let git: String? = ["/usr/bin/git", "/opt/homebrew/bin/git", "/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

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
