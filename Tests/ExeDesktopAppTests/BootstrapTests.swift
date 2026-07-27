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
        XCTAssertTrue(script.contains("git clone https://github.int.exe.xyz/owner/one.git"))
        XCTAssertTrue(script.contains("git clone https://github.int.exe.xyz/owner/two.git"))
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
}
