import XCTest
@testable import ExeDesktopApp

/// Reading whatever gets typed or pasted into the "owner/repo" field.
final class RepoReferenceTests: XCTestCase {

    // MARK: - What the field always asked for

    func testAPlainOwnerRepoIsKept() {
        XCTAssertEqual(RepoReference.normalize("apple/swift"), "apple/swift")
        XCTAssertEqual(RepoReference.normalize("leighmcculloch/hub"), "leighmcculloch/hub")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(RepoReference.normalize("  apple/swift \n"), "apple/swift")
    }

    // MARK: - Pasting from the browser

    /// The case that motivated this: the old check was only "contains a slash",
    /// so a pasted URL became the clone path verbatim and failed.
    func testAGitHubURLBecomesOwnerRepo() {
        for url in [
            "https://github.com/apple/swift",
            "http://github.com/apple/swift",
            "https://github.com/apple/swift/",
            "https://github.com/apple/swift.git",
            "https://www.github.com/apple/swift",
            "github.com/apple/swift",
        ] {
            XCTAssertEqual(RepoReference.normalize(url), "apple/swift", url)
        }
    }

    /// Deep links are what you actually have in the clipboard mid-task.
    func testADeepLinkIsReducedToTheRepository() {
        for url in [
            "https://github.com/apple/swift/tree/main/stdlib",
            "https://github.com/apple/swift/pull/1234",
            "https://github.com/apple/swift/blob/main/README.md",
            "https://github.com/apple/swift/issues",
        ] {
            XCTAssertEqual(RepoReference.normalize(url), "apple/swift", url)
        }
    }

    func testAnSSHRemoteBecomesOwnerRepo() {
        XCTAssertEqual(RepoReference.normalize("git@github.com:apple/swift.git"), "apple/swift")
        XCTAssertEqual(RepoReference.normalize("git@github.com:apple/swift"), "apple/swift")
        XCTAssertEqual(RepoReference.normalize("ssh://git@github.com/apple/swift.git"),
                       "apple/swift")
    }

    func testATrailingGitSuffixIsDropped() {
        XCTAssertEqual(RepoReference.normalize("apple/swift.git"), "apple/swift")
    }

    /// A repo genuinely named with ".git" inside it must not be truncated.
    func testOnlyATrailingGitSuffixIsDropped() {
        XCTAssertEqual(RepoReference.normalize("apple/swift.github"), "apple/swift.github")
        XCTAssertEqual(RepoReference.normalize("apple/.gitignore"), "apple/.gitignore")
    }

    // MARK: - Not a repository

    /// Rejected rather than guessed at, so the field can say so instead of
    /// silently cloning something wrong.
    func testTextThatIsNotARepositoryIsRejected() {
        for text in ["", "   ", "swift", "apple", "/", "//", "/swift", "apple/", "https://"] {
            XCTAssertNil(RepoReference.normalize(text), text.debugDescription)
        }
    }

    /// Without a URL prefix the text is taken literally, so a third component
    /// is a typo rather than a deep link — guessing would clone the wrong repo
    /// without saying so.
    func testAPlainThreePartPathIsRejectedRatherThanTruncated() {
        XCTAssertNil(RepoReference.normalize("org/team/repo"))
    }

    /// But with a prefix the same shape is a deep link and is trimmed.
    func testAPrefixedThreePartPathIsTrimmed() {
        XCTAssertEqual(RepoReference.normalize("github.com/org/team/repo"), "org/team")
    }

    func testAURLWithNoPathIsRejected() {
        XCTAssertNil(RepoReference.normalize("https://github.com"))
        XCTAssertNil(RepoReference.normalize("https://github.com/apple"))
    }

    // MARK: - Result shape

    /// The result is interpolated into a clone URL, so it must never carry a
    /// scheme, host or stray slash through.
    func testTheResultIsAlwaysABareOwnerRepo() throws {
        let inputs = [
            "apple/swift", "  apple/swift  ", "https://github.com/apple/swift.git",
            "git@github.com:apple/swift.git", "github.com/apple/swift/tree/main",
            "https://github.com/apple/swift/pull/1",
        ]
        for input in inputs {
            let value = try XCTUnwrap(RepoReference.normalize(input), input)
            XCTAssertEqual(value, "apple/swift", input)
            XCTAssertFalse(value.contains("://"), input)
            XCTAssertEqual(value.filter { $0 == "/" }.count, 1, input)
        }
    }

    /// Normalizing an already-normalized value changes nothing.
    func testNormalizingIsIdempotent() {
        for input in ["apple/swift", "https://github.com/apple/swift.git", "apple/swift.git"] {
            let once = RepoReference.normalize(input)
            XCTAssertEqual(RepoReference.normalize(once ?? ""), once, input)
        }
    }

    /// Hosts other than GitHub aren't rewritten away — the clone goes through
    /// exe.dev's GitHub proxy, so a non-GitHub URL is not a repo this can use.
    func testANonGitHubURLStillReducesToItsPath() {
        // Accepted as owner/repo from the path; the proxy decides the rest.
        XCTAssertEqual(RepoReference.normalize("https://gitlab.com/group/project"),
                       "group/project")
    }
}
