import XCTest
@testable import ExeDesktopApp

/// Covers the auto-naming installed on a VM: the shell that wires it up, and —
/// by running `python3` — the script itself.
///
/// The script is the part with no other safety net. It runs on a VM, inside a
/// hook, with its output going nowhere, so a syntax error or a name exe.dev
/// rejects would show up as nothing happening. Both are checked here instead.
final class AutoNameTests: XCTestCase {

    // MARK: - Bootstrap fragments

    /// Everything is gated on the armed flag, which only a session created
    /// without a name gets. Without this gate a reconnect would install the
    /// hooks on a VM whose name the user typed.
    func testInstallIsGatedOnTheArmedFlag() {
        XCTAssertTrue(AutoName.install.contains("if [ -e \"$HOME/\(AutoName.armedName)\" ]; then"))
        XCTAssertTrue(AutoName.install.contains("\nfi\n"))
        XCTAssertTrue(AutoName.arm.contains(": > \"$HOME/\(AutoName.armedName)\""))
    }

    func testInstallWritesTheScriptAndLetsItWireItself() {
        let install = AutoName.install
        XCTAssertTrue(install.contains("base64 -d > \"$HOME/\(AutoName.scriptName)\""))
        // Executable because the hook runs it directly, by path.
        XCTAssertTrue(install.contains("chmod +x \"$HOME/\(AutoName.scriptName)\""))
        XCTAssertTrue(install.contains(
            "python3 \"$HOME/\(AutoName.scriptName)\" \(AutoName.installFlag)"))
        // A VM without python3 must not fail the whole bootstrap over naming.
        XCTAssertTrue(install.contains("|| true"))
    }

    /// One script wired into both harnesses — the file it merges into and the
    /// key it merges are what each of them reads.
    func testScriptWiresBothHarnesses() {
        XCTAssertTrue(AutoName.script.contains("~/.claude/settings.json"))
        XCTAssertTrue(AutoName.script.contains("UserPromptSubmit"))
        XCTAssertTrue(AutoName.script.contains("~/.codex/config.toml"))
        XCTAssertTrue(AutoName.script.contains("notify = "))
    }

    // MARK: - The rename-only token

    func testMintCommandAsksForRenameAlone() {
        let command = AutoName.mintTokenCommand
        XCTAssertTrue(command.hasPrefix("ssh-key generate-api-key "))
        XCTAssertTrue(command.contains("--cmds=rename"))
        XCTAssertTrue(command.contains("--exp=\(AutoName.tokenLifetime)"))
        XCTAssertTrue(command.contains("--json"))
    }

    func testTokenIsStaleWhenUnmintedOrOld() {
        let now = Date()
        XCTAssertTrue(AutoName.tokenIsStale(minted: nil, now: now))
        XCTAssertFalse(AutoName.tokenIsStale(minted: now, now: now))
        XCTAssertFalse(AutoName.tokenIsStale(
            minted: now.addingTimeInterval(-AutoName.tokenMaxAge + 60), now: now))
        XCTAssertTrue(AutoName.tokenIsStale(
            minted: now.addingTimeInterval(-AutoName.tokenMaxAge - 60), now: now))
    }

    /// A clock that jumped forward would otherwise leave a token looking fresh
    /// until the date it was "minted" comes around.
    func testTokenMintedInTheFutureIsStale() {
        let now = Date()
        XCTAssertTrue(AutoName.tokenIsStale(minted: now.addingTimeInterval(3600), now: now))
    }

    // MARK: - The script, run by python3

    /// A syntax error in the script would only show up on a VM, inside a hook
    /// whose output goes nowhere.
    func testGeneratedPythonCompiles() throws {
        let path = try write(AutoName.script)
        guard let output = try python(
            "import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True)",
            arguments: [path])
        else { throw XCTSkip("no python3 to check the generated script with") }
        XCTAssertEqual(output, "")
    }

    /// The name the model suggests is turned into one exe.dev accepts — 5-52
    /// characters, starting with a lowercase letter, single hyphens — or into
    /// nothing at all, which leaves the VM's generated name alone.
    func testScriptSanitizesSuggestedNames() throws {
        let results = try scriptResults()
        XCTAssertEqual(results["clean"], "fix-login-redirect")
        XCTAssertEqual(results["sentence"], "fix-the-login-bug")
        XCTAssertEqual(results["quoted"], "add-oauth-login")
        XCTAssertEqual(results["trailingStop"], "add-oauth-login")
        // A name has to start with a letter, so a leading digit is prefixed
        // rather than dropped — "3d-render" is not "d-render".
        XCTAssertEqual(results["leadingDigit"], "vm-3d-render-pipeline")
        // Too short to be a valid name: better no rename than a rejected one.
        XCTAssertEqual(results["short"], "")
        XCTAssertEqual(results["empty"], "")
        XCTAssertEqual(results["punctuation"], "")
        XCTAssertEqual(results["long"], String(repeating: "x", count: 52))
    }

    /// One script, two harnesses: Claude Code's hook payload has the prompt
    /// under `prompt`, Codex's notify has it in `input-messages`.
    func testScriptReadsBothHarnessPayloads() throws {
        let results = try scriptResults()
        XCTAssertEqual(results["hook"], "Fix the flaky test")
        XCTAssertEqual(results["notify"], "add a dark mode")
        XCTAssertEqual(results["notifyUnderscored"], "port to swift 6")
        XCTAssertEqual(results["junk"], "")
        XCTAssertEqual(results["empty payload"], "")
    }

    // MARK: - Helpers

    /// `sanitize` and `task` applied to a spread of inputs, in one python3 run.
    private func scriptResults() throws -> [String: String] {
        let path = try write(AutoName.script)
        let program = """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("autoname", sys.argv[1])
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        print(json.dumps({
            "clean": module.sanitize("fix-login-redirect"),
            "sentence": module.sanitize("Fix the LOGIN bug!!"),
            "quoted": module.sanitize('"add-oauth-login"'),
            "trailingStop": module.sanitize("Add OAuth login."),
            "leadingDigit": module.sanitize("3d-render-pipeline"),
            "short": module.sanitize("hi"),
            "empty": module.sanitize(""),
            "punctuation": module.sanitize("!!! ???"),
            "long": module.sanitize("x" * 80),
            "hook": module.task(json.dumps({"prompt": "  Fix the flaky test  "})),
            "notify": module.task(json.dumps({"input-messages": ["add a dark mode"]})),
            "notifyUnderscored": module.task(json.dumps({"input_messages": ["port to swift 6"]})),
            "junk": module.task("not json"),
            "empty payload": module.task(""),
        }))
        """
        guard let output = try python(program, arguments: [path]) else {
            throw XCTSkip("no python3 to run the generated script with")
        }
        return try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
    }

    private func write(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoname-\(UUID().uuidString).py")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// Run `program` under python3, returning its stdout — or nil when there is
    /// no python3 on the machine, which is a skip rather than a failure.
    private func python(_ program: String, arguments: [String]) throws -> String? {
        let process = Process()
        // Via `env` so it is found on PATH: python3 lives in different places on
        // a Mac and on the Linux runner.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", program] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // `env` exits 127 when it can't find python3 at all.
        if process.terminationStatus == 127 { return nil }
        XCTAssertEqual(process.terminationStatus, 0,
                       String(data: error, encoding: .utf8) ?? "python3 failed")
        return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
