import XCTest
@testable import ExeDesktopApp

/// The repo picker's ordering and errors, and the identity seeded onto a VM.
final class GitHubReposTests: XCTestCase {

    private func repos(_ names: [String]) -> [GitHubRepo] {
        names.map { GitHubRepo(fullName: $0, isPrivate: false) }
    }

    // MARK: - Ordering

    /// A plain `<` puts every capitalised name ahead of every lowercase one, so
    /// the picker looked unsorted to anyone scanning it.
    func testOrderingIgnoresCase() {
        let ordered = GitHubRepos.sorted(repos(["ZZZ/alpha", "aaa/beta", "Mmm/gamma"]))
        XCTAssertEqual(ordered.map(\.fullName), ["aaa/beta", "Mmm/gamma", "ZZZ/alpha"])
    }

    func testOrderingIsStableAcrossOwners() {
        let ordered = GitHubRepos.sorted(repos([
            "leighmcculloch/hub", "Anthropic/claude", "anthropic/tools", "zed/editor",
        ]))
        XCTAssertEqual(ordered.map(\.fullName),
                       ["Anthropic/claude", "anthropic/tools", "leighmcculloch/hub", "zed/editor"])
    }

    /// Names differing only in case must still have a definite order, or the
    /// list can shuffle between refreshes.
    func testNamesDifferingOnlyByCaseHaveATotalOrder() {
        let input = repos(["a/B", "a/b"])
        XCTAssertEqual(GitHubRepos.sorted(input).map(\.fullName),
                       GitHubRepos.sorted(input.reversed()).map(\.fullName))
    }

    func testOrderingHandlesEmptyAndSingleLists() {
        XCTAssertTrue(GitHubRepos.sorted([]).isEmpty)
        XCTAssertEqual(GitHubRepos.sorted(repos(["only/one"])).map(\.fullName), ["only/one"])
    }

    func testOrderingKeepsEveryRepo() {
        let input = repos(["c/x", "A/y", "b/z", "A/a"])
        XCTAssertEqual(GitHubRepos.sorted(input).count, input.count)
        XCTAssertEqual(Set(GitHubRepos.sorted(input).map(\.fullName)),
                       Set(input.map(\.fullName)))
    }

    // MARK: - Errors

    func testAnAPIErrorNamesTheStatus() {
        let message = GitHubRepos.apiError(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8))
        XCTAssertTrue(message.contains("404"), message)
        XCTAssertTrue(message.contains("Not Found"), message)
    }

    /// GitHub returns JSON normally, but an intermediary failure is an HTML
    /// page, and this string goes straight into a label.
    func testAnHTMLErrorPageIsCondensed() {
        let page = "<html>\n<head><title>503</title></head>\n<body>down</body>\n</html>"
        let message = GitHubRepos.apiError(status: 503, body: Data(page.utf8))
        XCTAssertFalse(message.contains("\n"), message)
    }

    func testAnAbsurdlyLongBodyIsTruncated() {
        let message = GitHubRepos.apiError(
            status: 500, body: Data(String(repeating: "x", count: 50_000).utf8))
        XCTAssertLessThan(message.count, 400)
    }

    /// A bad or missing token is the common failure, and the fix is a different
    /// place from exe.dev's token.
    func testAuthFailuresPointAtTheGitHubToken() {
        for status in [401, 403] {
            let message = GitHubRepos.apiError(status: status, body: Data(#"{"message":"Bad"}"#.utf8))
            XCTAssertTrue(message.contains("GITHUB_TOKEN"), "\(status): \(message)")
            XCTAssertTrue(message.contains("gh auth login"), "\(status): \(message)")
        }
    }

    func testOtherFailuresDoNotMentionTheToken() {
        for status in [404, 500, 503] {
            let message = GitHubRepos.apiError(status: status, body: Data("x".utf8))
            XCTAssertFalse(message.contains("GITHUB_TOKEN"), "\(status): \(message)")
        }
    }

    // MARK: - Commit identity

    func testDisplayNameUsesTheProfileName() {
        XCTAssertEqual(GitHubUser(login: "octocat", id: 1, name: "The Octocat").displayName,
                       "The Octocat")
    }

    func testDisplayNameFallsBackToTheLogin() {
        XCTAssertEqual(GitHubUser(login: "octocat", id: 1, name: nil).displayName, "octocat")
        XCTAssertEqual(GitHubUser(login: "octocat", id: 1, name: "").displayName, "octocat")
    }

    /// This is written into `git config user.name` on the VM, so a blank-looking
    /// profile name would author every commit as nothing.
    func testABlankProfileNameFallsBackToTheLogin() {
        for blank in ["   ", "\n", "\t ", " \n "] {
            XCTAssertEqual(GitHubUser(login: "octocat", id: 1, name: blank).displayName, "octocat",
                           "blank name \(blank.debugDescription)")
        }
    }

    func testASurroundedNameIsTrimmed() {
        XCTAssertEqual(GitHubUser(login: "octocat", id: 1, name: "  The Octocat \n").displayName,
                       "The Octocat")
    }

    /// GitHub only links a commit to the profile when the address is exactly
    /// `<id>+<login>@users.noreply.github.com`.
    func testTheNoreplyAddressMatchesGitHubsFormat() {
        XCTAssertEqual(GitHubUser(login: "octocat", id: 583231).noreplyEmail,
                       "583231+octocat@users.noreply.github.com")
    }

    // MARK: - Cache

    /// The cache is what lets the picker render immediately, so a repo written
    /// must come back identically — including the private flag, which the row's
    /// icon depends on.
    func testCacheRoundTripsRepos() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repo-cache-test.json")
        try? FileManager.default.removeItem(at: url)
        let original = RepoCache.fileURL
        RepoCache.fileURL = url
        defer {
            RepoCache.fileURL = original
            try? FileManager.default.removeItem(at: url)
        }

        XCTAssertNil(RepoCache.read(), "nothing cached yet")

        let repos = [
            GitHubRepo(fullName: "anthropic/claude", isPrivate: false),
            GitHubRepo(fullName: "octocat/secret", isPrivate: true),
        ]
        RepoCache.write(repos)

        let read = try XCTUnwrap(RepoCache.read())
        XCTAssertEqual(read.map(\.fullName), repos.map(\.fullName))
        XCTAssertEqual(read.map(\.isPrivate), repos.map(\.isPrivate))
    }

    /// A half-written or corrupt cache is a miss, not a crash — the picker just
    /// falls back to the spinner and the next fetch rewrites it.
    func testCorruptCacheIsAMiss() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repo-cache-corrupt.json")
        let original = RepoCache.fileURL
        RepoCache.fileURL = url
        defer {
            RepoCache.fileURL = original
            try? FileManager.default.removeItem(at: url)
        }

        try Data("not json".utf8).write(to: url)
        XCTAssertNil(RepoCache.read())
    }

    // MARK: - Shared message helper

    func testCondenseCollapsesAndTrims() {
        XCTAssertEqual(MessageText.condense("a\n\n  b\tc "), "a b c")
    }

    func testCondenseReportsAnEmptyBody() {
        XCTAssertEqual(MessageText.condense("   \n"), "(empty response)")
        XCTAssertEqual(MessageText.condense(Data()), "(empty response)")
    }

    func testCondenseRespectsTheLimit() {
        XCTAssertEqual(MessageText.condense(String(repeating: "x", count: 50), limit: 10),
                       String(repeating: "x", count: 10) + "…")
    }

    func testCondenseLeavesAShortMessageAlone() {
        XCTAssertEqual(MessageText.condense("Not Found"), "Not Found")
    }

    func testUndecodableBytesStillCondense() {
        XCTAssertFalse(MessageText.condense(Data([0xFF, 0xFE])).isEmpty)
    }
}

private extension GitHubUser {
    init(login: String, id: Int) {
        self.init(login: login, id: id, name: nil)
    }
}
