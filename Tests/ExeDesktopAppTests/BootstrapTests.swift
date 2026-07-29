import XCTest
@testable import ExeDesktopApp

/// Covers the pure logic that produces names and remote commands. These rules
/// are enforced server-side by exe.dev, and getting them wrong has already
/// caused real failures (a tag starting with a digit was rejected with HTTP
/// 422), so they're pinned here.
final class BootstrapTests: XCTestCase {

    // MARK: - VM names

    /// exe.dev: "5-52 characters: start with a lowercase letter, then lowercase
    /// letters or digits, with optional single hyphen separators".
    private func assertValidVMName(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(name.count, 5, "\(name) too short", file: file, line: line)
        XCTAssertLessThanOrEqual(name.count, 52, "\(name) too long", file: file, line: line)
        XCTAssertNotNil(name.range(of: "^[a-z]([a-z0-9]|-[a-z0-9])*$", options: .regularExpression),
                        "\(name) violates the VM name pattern", file: file, line: line)
    }

    func testVMNameSlugifiesOrdinaryNames() {
        XCTAssertEqual(Bootstrap.vmName(from: "My Session"), "my-session")
        XCTAssertEqual(Bootstrap.vmName(from: "Feature/ABC-123!"), "feature-abc-123")
        XCTAssertEqual(Bootstrap.vmName(from: "already-fine"), "already-fine")
    }

    /// A leading digit is rejected by exe.dev, so it must be prefixed.
    func testVMNameHandlesLeadingDigit() {
        let name = Bootstrap.vmName(from: "4d63 testmergequeue")
        XCTAssertTrue(name.hasPrefix("vm-"))
        assertValidVMName(name)
    }

    /// Consecutive separators would produce "--", which exe.dev rejects.
    func testVMNameCollapsesHyphenRuns() {
        XCTAssertFalse(Bootstrap.vmName(from: "a  b").contains("--"))
        XCTAssertFalse(Bootstrap.vmName(from: "a???b").contains("--"))
    }

    func testVMNameSatisfiesLengthBounds() {
        assertValidVMName(Bootstrap.vmName(from: "ab"))              // padded up
        assertValidVMName(Bootstrap.vmName(from: ""))                // generated
        assertValidVMName(Bootstrap.vmName(from: "   "))             // generated
        assertValidVMName(Bootstrap.vmName(from: "---"))             // generated
        assertValidVMName(Bootstrap.vmName(from: String(repeating: "x", count: 200)))
    }

    func testVMNameIsAlwaysValidAcrossAwkwardInput() {
        for input in ["", " ", "-", "9", "Ünïcødé nåme", "a/b/c", "..", "UPPER CASE",
                      "trailing-", "-leading", String(repeating: "ab-", count: 40)] {
            assertValidVMName(Bootstrap.vmName(from: input))
        }
    }

    func testGeneratedVMNamesAreDistinct() {
        XCTAssertNotEqual(Bootstrap.vmName(from: ""), Bootstrap.vmName(from: ""))
    }

    // MARK: - Avoiding names already taken

    /// The common case: nothing to dodge, so the name is untouched.
    func testUniqueNameIsTheSlugWhenFree() {
        XCTAssertEqual(Bootstrap.uniqueVMName(from: "My Session", existing: []), "my-session")
        XCTAssertEqual(
            Bootstrap.uniqueVMName(from: "My Session", existing: ["something-else"]),
            "my-session")
    }

    func testUniqueNameNumbersPastACollision() {
        XCTAssertEqual(
            Bootstrap.uniqueVMName(from: "review", existing: ["review"]),
            "review-2")
        XCTAssertEqual(
            Bootstrap.uniqueVMName(from: "review", existing: ["review", "review-2"]),
            "review-3")
    }

    /// Gaps are filled rather than counting past them: deleting "review-2"
    /// should let the next session take that name back.
    func testUniqueNameTakesTheLowestFreeNumber() {
        XCTAssertEqual(
            Bootstrap.uniqueVMName(from: "review", existing: ["review", "review-3"]),
            "review-2")
    }

    /// A name at the limit can't just have "-2" appended — the result would be
    /// rejected for length.
    func testUniqueNameStaysInsideTheLengthLimit() {
        let long = String(repeating: "x", count: 52)
        let taken = Bootstrap.vmName(from: long)
        XCTAssertEqual(taken.count, 52)
        assertValidVMName(Bootstrap.uniqueVMName(from: long, existing: [taken]))
    }

    /// Shortening to make room must not leave the hyphen that was there.
    func testUniqueNameDoesNotProduceADoubledHyphen() {
        // Hyphens on every odd index, so shortening to 50 characters to make
        // room for "-2" cuts exactly on one.
        let base = String(repeating: "a-", count: 26)
        let slug = Bootstrap.vmName(from: base)
        XCTAssertEqual(slug.count, 51)
        XCTAssertEqual(Array(slug)[49], "-", "the truncation point must be a hyphen")

        let result = Bootstrap.uniqueVMName(from: base, existing: [slug])
        XCTAssertFalse(result.contains("--"), result)
        assertValidVMName(result)
    }

    /// Whatever the collision, the result still has to satisfy exe.dev.
    func testUniqueNameIsAlwaysValid() {
        for input in ["", "ab", "9", "trailing-", String(repeating: "q", count: 200)] {
            let slug = Bootstrap.vmName(from: input)
            var taken: Set<String> = [slug]
            for _ in 0..<5 {
                let next = Bootstrap.uniqueVMName(from: input, existing: taken)
                assertValidVMName(next)
                XCTAssertFalse(taken.contains(next), "\(next) collides for input \(input.prefix(20))")
                taken.insert(next)
            }
        }
    }

    /// Past the numbered range it falls back to a random suffix rather than
    /// looping forever or handing back a name that is already taken.
    func testUniqueNameSurvivesExhaustingTheNumbers() {
        var taken: Set<String> = ["review"]
        for counter in 2...99 { taken.insert("review-\(counter)") }
        let result = Bootstrap.uniqueVMName(from: "review", existing: taken)
        XCTAssertFalse(taken.contains(result))
        assertValidVMName(result)
    }

    // MARK: - Shell quoting

    func testShellQuoteWrapsAndEscapes() {
        XCTAssertEqual(Bootstrap.shellQuote("claude"), "'claude'")
        XCTAssertEqual(Bootstrap.shellQuote("hello world"), "'hello world'")
        // The apostrophe must be closed, escaped, and reopened.
        XCTAssertEqual(Bootstrap.shellQuote("it's"), #"'it'\''s'"#)
    }

    // MARK: - Login shell command

    /// Every session goes through tmux so a dropped connection reattaches.
    func testLoginShellAlwaysUsesTmux() {
        let command = Bootstrap.loginShellCommand(startCommand: "")
        XCTAssertTrue(command.contains("tmux new-session -A -s \(Bootstrap.tmuxSession)"))
    }

    /// The start command must reach tmux as a single argument, or a multi-word
    /// command would be parsed as tmux's own flags.
    func testStartCommandIsPassedAsOneQuotedArgument() {
        let command = Bootstrap.loginShellCommand(startCommand: "claude --resume")
        XCTAssertTrue(command.contains(Bootstrap.shellQuote("claude --resume")))
    }

    /// Detaching (or a missing tmux) must leave a usable shell, not end the
    /// session.
    func testLoginShellFallsBackToAShell() {
        for start in ["", "claude"] {
            XCTAssertTrue(Bootstrap.loginShellCommand(startCommand: start)
                .hasSuffix("exec ${SHELL:-bash} -l'") ||
                Bootstrap.loginShellCommand(startCommand: start) == "exec ${SHELL:-bash} -l")
        }
    }

    func testBlankStartCommandIsTreatedAsNone() {
        XCTAssertEqual(Bootstrap.loginShellCommand(startCommand: "   "),
                       Bootstrap.loginShellCommand(startCommand: ""))
    }

    // MARK: - Bootstrap script

    func testScriptClonesEachRepoThroughTheProxy() {
        let script = Bootstrap.script(setupScript: "", claudeSettings: "",
                                      repos: ["owner/one", "owner/two"])
        // Quoted, since repo names can come from the free-text owner/repo field.
        XCTAssertTrue(script.contains(
            "git clone " + Bootstrap.shellQuote("https://github.int.exe.xyz/owner/one.git")))
        XCTAssertTrue(script.contains(
            "git clone " + Bootstrap.shellQuote("https://github.int.exe.xyz/owner/two.git")))
    }

    /// Trust is applied after cloning, or the freshly cloned directories
    /// wouldn't exist yet to be trusted.
    func testTrustStepRunsAfterTheClones() {
        let script = Bootstrap.script(setupScript: "", claudeSettings: "",
                                      repos: ["owner/one"])
        let clone = script.range(of: "git clone")
        let trust = script.range(of: "hasTrustDialogAccepted")
        XCTAssertNotNil(clone)
        XCTAssertNotNil(trust)
        if let clone, let trust {
            XCTAssertTrue(clone.upperBound < trust.lowerBound,
                          "trust must come after the clones")
        }
    }

    /// Existing files on the VM carry real state and must never be clobbered.
    func testSeededFilesAreOnlyWrittenWhenAbsent() {
        let script = Bootstrap.script(setupScript: "", claudeSettings: #"{"a":1}"#, repos: [])
        XCTAssertTrue(script.contains(#"if [ ! -f "$HOME/.claude/settings.json" ]"#))
        XCTAssertTrue(script.contains(#"if [ ! -f "$HOME/.claude.json" ]"#))
    }

    /// libghostty's kitty keyboard protocol needs tmux's extended-keys on, or
    /// modified keys like Shift+Enter never reach the terminal.
    func testScriptEnablesTmuxExtendedKeys() throws {
        let script = Bootstrap.script(setupScript: "", claudeSettings: "", repos: [])
        let output = try runScript(script + "cat \"$HOME/.tmux.conf\"", gitExitCode: 0)
        XCTAssertEqual(output, "set -g extended-keys on\n")
    }

    /// Re-running the bootstrap (e.g. a VM restart) must not duplicate the line.
    func testTmuxExtendedKeysIsNotDuplicatedOnRerun() throws {
        let script = Bootstrap.script(setupScript: "", claudeSettings: "", repos: [])
        let output = try runScript(script + script + "cat \"$HOME/.tmux.conf\"", gitExitCode: 0)
        XCTAssertEqual(output, "set -g extended-keys on\n")
    }

    func testNoClaudeSettingsMeansNoSeeding() {
        let script = Bootstrap.script(setupScript: "", claudeSettings: "  ", repos: [])
        XCTAssertFalse(script.contains(".claude/settings.json"))
    }

    /// A deliberate identity set on the VM must survive reconnects, so the
    /// config is only written when unset.
    func testGitIdentityIsOnlySetWhenUnset() {
        let script = Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: [],
            gitIdentity: (name: "O'Leigh", email: "1+u@users.noreply.github.com"))
        XCTAssertTrue(script.contains("git config --global user.name >/dev/null 2>&1 ||"))
        XCTAssertTrue(script.contains(Bootstrap.shellQuote("O'Leigh")))
        XCTAssertTrue(script.contains("1+u@users.noreply.github.com"))
    }

    func testNoGitIdentityMeansNoGitConfig() {
        let script = Bootstrap.script(setupScript: "", claudeSettings: "", repos: [])
        XCTAssertFalse(script.contains("git config --global user.name"))
    }

    /// The script is base64-encoded so multi-line user content survives the trip
    /// through SSH argument and remote-shell parsing.
    func testCommandRoundTripsTheScriptThroughBase64() {
        let setup = "echo 'quoted'\nexport A=1  # comment\n"
        let command = Bootstrap.command(setupScript: setup, claudeSettings: "", repos: [])
        guard let encoded = command.split(separator: "'").dropFirst().first,
              let decoded = Data(base64Encoded: String(encoded)),
              let text = String(data: decoded, encoding: .utf8)
        else { return XCTFail("no base64 payload in the generated command") }
        XCTAssertTrue(text.contains(setup))
    }

    // MARK: - Model configuration

    /// Claude Code is configured by variables set on the VM host, so the script
    /// only has the two harnesses that read a file.
    func testAGatewayModelConfiguresCodexAndPi() throws {
        let script = Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: [],
            model: GatewayModel(provider: "openai", model: "gpt-5.5"))

        XCTAssertTrue(script.contains("$HOME/.codex/config.toml"))
        XCTAssertTrue(script.contains("~/.pi/agent"))
    }

    func testNoModelMeansNoHarnessConfiguration() {
        let script = Bootstrap.script(setupScript: "", claudeSettings: "", repos: [])
        XCTAssertFalse(script.contains(".codex"))
        XCTAssertFalse(script.contains(".pi/agent"))
    }

    /// Run for real: the generated shell has to produce files the harnesses can
    /// actually read, which reading the script text can't tell you.
    func testTheGeneratedConfigFilesAreWritten() throws {
        let model = GatewayModel(provider: "anthropic", model: "claude-opus-5")
        let home = try runInFreshHome(Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: [], model: model))

        XCTAssertEqual(try text(at: home + "/.codex/config.toml"),
                       LLMGateway.codexConfig(for: model))

        let models = try json(at: home + "/.pi/agent/models.json")
        let providers = try XCTUnwrap(models["providers"] as? [String: Any])
        XCTAssertNotNil(providers["exe-llm"])

        let settings = try json(at: home + "/.pi/agent/settings.json")
        XCTAssertEqual(settings["defaultModel"] as? String, "claude-opus-5")
    }

    /// Reconnecting reruns the bootstrap, and the model can change between
    /// runs, so a second pass has to land on the second choice.
    func testChangingTheModelRewritesTheConfiguration() throws {
        let home = try runInFreshHome(Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: [],
            model: GatewayModel(provider: "openai", model: "gpt-5.5")))
        _ = try runScript(Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: [],
            model: GatewayModel(provider: "openai", model: "gpt-5.6-sol")),
            gitExitCode: 0, home: home)

        XCTAssertTrue(try text(at: home + "/.codex/config.toml").contains("gpt-5.6-sol"))
        XCTAssertEqual(try json(at: home + "/.pi/agent/settings.json")["defaultModel"] as? String,
                       "gpt-5.6-sol")
    }

    /// pi's files hold more than our provider, so they're merged rather than
    /// replaced.
    func testPiConfigurationKeepsWhatWasAlreadyThere() throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(
            atPath: home + "/.pi/agent", withIntermediateDirectories: true)
        try Data(#"{"providers":{"ollama":{"baseUrl":"http://localhost:11434/v1"}}}"#.utf8)
            .write(to: URL(fileURLWithPath: home + "/.pi/agent/models.json"))
        try Data(#"{"theme":"dark"}"#.utf8)
            .write(to: URL(fileURLWithPath: home + "/.pi/agent/settings.json"))

        _ = try runScript(Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: [],
            model: GatewayModel(provider: "openai", model: "gpt-5.5")),
            gitExitCode: 0, home: home)

        let providers = try XCTUnwrap(
            try json(at: home + "/.pi/agent/models.json")["providers"] as? [String: Any])
        XCTAssertNotNil(providers["ollama"], "an unrelated provider was dropped")
        XCTAssertNotNil(providers["exe-llm"])
        XCTAssertEqual(try json(at: home + "/.pi/agent/settings.json")["theme"] as? String, "dark")
    }

    /// A Codex config the user wrote themselves is worth more than a model
    /// selection: it's left alone, and the run says so rather than going quiet.
    func testAForeignCodexConfigIsLeftAlone() throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(
            atPath: home + "/.codex", withIntermediateDirectories: true)
        let existing = "model = \"gpt-5.5\"\nmodel_provider = \"openai\"\n"
        try Data(existing.utf8).write(to: URL(fileURLWithPath: home + "/.codex/config.toml"))

        let output = try runScript(Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: [],
            model: GatewayModel(provider: "anthropic", model: "claude-opus-5")),
            gitExitCode: 0, home: home)

        XCTAssertEqual(try text(at: home + "/.codex/config.toml"), existing)
        XCTAssertTrue(output.contains("left ~/.codex/config.toml alone"), output)
    }

    // MARK: - Cloning repositories

    /// A failed clone used to be swallowed by `|| true`, so the user landed in
    /// a shell with no repo and git's error scrolled away.
    func testAFailedCloneIsReported() throws {
        // Asserted by running the generated script with a `git` that always
        // fails, rather than by looking for "|| true" in the text: the tmux
        // install line uses that deliberately, so a string check matches the
        // wrong thing. Restoring the old behaviour makes this test print
        // nothing, which is exactly what it checks for.
        let script = Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: ["owner/repo"])
        let output = try runScript(script, gitExitCode: 1)
        XCTAssertTrue(output.contains("did not clone"), output)
        XCTAssertTrue(output.contains("owner/repo"), output)
    }

    /// The reverse: a working clone must not produce a scary message.
    func testASuccessfulCloneReportsNothing() throws {
        let script = Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: ["owner/repo"])
        XCTAssertFalse(try runScript(script, gitExitCode: 0).contains("did not clone"))
    }

    /// One bad repo must not stop the others being attempted, nor abort the
    /// rest of the bootstrap.
    func testEveryRepoIsAttemptedAndAllFailuresListed() throws {
        let script = Bootstrap.script(
            setupScript: "", claudeSettings: "", repos: ["a/one", "b/two", "c/three"])
        let output = try runScript(script, gitExitCode: 1)

        for repo in ["a/one", "b/two", "c/three"] {
            XCTAssertTrue(output.contains(repo), "\(repo) missing from: \(output)")
        }
    }

    /// Repo names reach the script from a free-text field that is only checked
    /// for a slash, so they must not be able to run anything.
    func testARepoNameCannotInjectAShellCommand() throws {
        let marker = NSTemporaryDirectory() + "bootstrap-pwned-" + UUID().uuidString
        let script = Bootstrap.script(
            setupScript: "", claudeSettings: "",
            repos: ["a/b; touch \(marker) #", "c/d$(touch \(marker))"])
        _ = try runScript(script, gitExitCode: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "a repo name escaped its quoting and ran a command")
    }

    func testNoCloneMachineryWhenThereAreNoRepos() {
        let script = Bootstrap.script(setupScript: "echo hi", claudeSettings: "", repos: [])
        XCTAssertFalse(script.contains("exe_failed_clones"))
        XCTAssertFalse(script.contains("git clone"))
    }

    // MARK: - Running the script

    /// Temp directories used as `$HOME`, removed once the test has read what
    /// the script wrote into them.
    private var scratchDirectories: [String] = []

    override func tearDownWithError() throws {
        for directory in scratchDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        scratchDirectories = []
    }

    private func makeHome() throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory.path)
        return directory.path
    }

    /// Run `script` in an empty home and hand back the home, for inspection.
    private func runInFreshHome(_ script: String) throws -> String {
        let home = try makeHome()
        _ = try runScript(script, gitExitCode: 0, home: home)
        return home
    }

    private func text(at path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    private func json(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Runs the generated script with a stub `git` on PATH, so the reporting
    /// logic is exercised without touching the network.
    private func runScript(_ script: String, gitExitCode: Int32, home: String? = nil) throws -> String {
        let directory = URL(fileURLWithPath: try home ?? makeHome(), isDirectory: true)

        let stub = directory.appendingPathComponent("git")
        try Data("#!/bin/sh\nexit \(gitExitCode)\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["HOME"] = directory.path
        process.environment = environment
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
