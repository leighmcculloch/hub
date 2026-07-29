import XCTest
@testable import ExeDesktopApp

/// Tag/name generation and response decoding for the exe.dev API.
final class ExeServiceTests: XCTestCase {

    /// exe.dev requires tag names to match this, and rejects anything else with
    /// HTTP 422.
    private func assertValidTag(_ tag: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(tag.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression),
                        "\(tag) violates the tag pattern", file: file, line: line)
    }

    func testSlugLowercasesAndReplacesSeparators() {
        XCTAssertEqual(ExeService.slug("leighmcculloch/hub"), "leighmcculloch-hub")
        XCTAssertEqual(ExeService.slug("Owner/Repo.Name"), "owner-repo-name")
    }

    /// The regression that caused a real HTTP 422: an owner starting with a
    /// digit produced a tag starting with a digit.
    func testSlugPrefixesNamesThatDontStartWithALetter() {
        assertValidTag(ExeService.slug("4d63/testmergequeue"))
        assertValidTag(ExeService.slug("9/9"))
        assertValidTag(ExeService.slug("_x/y"))
        assertValidTag(ExeService.slug("-leading/x"))
    }

    func testSlugIsAlwaysValid() {
        for repo in ["a/b", "4/4", "UPPER/CASE", "dots.and/dashes-", "ünïcøde/repo", "x"] {
            assertValidTag(ExeService.slug(repo))
        }
    }

    func testQuoteEscapesForTheCommandParser() {
        XCTAssertEqual(ExeService.quote("PLAIN=abc"), "'PLAIN=abc'")
        XCTAssertEqual(ExeService.quote("GREETING=hello world"), "'GREETING=hello world'")
        XCTAssertEqual(ExeService.quote("MSG=it's"), #"'MSG=it'\''s'"#)
    }

    /// Shape confirmed against the live `ls --json` response.
    func testDecodesVMList() throws {
        let json = """
        {"vms":[{"vm_name":"elm-mews","ssh_dest":"elm-mews.exe.xyz","status":"running",
                 "region":"syd","https_url":"https://elm-mews.exe.xyz","tags":["a"]}]}
        """
        let list = try JSONDecoder().decode(ExeVMList.self, from: Data(json.utf8))
        XCTAssertEqual(list.vms.count, 1)
        XCTAssertEqual(list.vms[0].vm_name, "elm-mews")
        XCTAssertEqual(list.vms[0].ssh_dest, "elm-mews.exe.xyz")
        XCTAssertEqual(list.vms[0].tags, ["a"])
    }

    /// `id` backs SwiftUI list identity; a fresh value per read would churn the
    /// sidebar on every refresh.
    func testVMIdentityIsStableAcrossReads() throws {
        let json = #"{"vms":[{"vm_name":null,"ssh_dest":null}]}"#
        let list = try JSONDecoder().decode(ExeVMList.self, from: Data(json.utf8))
        XCTAssertEqual(list.vms[0].id, list.vms[0].id)
    }

    func testDecodesIntegrationsAndFindsAttachedTag() throws {
        let json = """
        [{"name":"x","type":"github","attachments":["tag:x"],
          "config":{"repositories":["o/r"],"act_as_user":true}}]
        """
        let integrations = try JSONDecoder().decode([ExeIntegration].self, from: Data(json.utf8))
        XCTAssertEqual(integrations[0].attachedTag, "x")
        XCTAssertEqual(integrations[0].config?.repositories, ["o/r"])
    }

    func testIntegrationWithNoTagAttachmentHasNoTag() throws {
        let json = #"[{"name":"x","type":"github","attachments":["auto:all"]}]"#
        let integrations = try JSONDecoder().decode([ExeIntegration].self, from: Data(json.utf8))
        XCTAssertNil(integrations[0].attachedTag)
    }
}

/// Config values that get persisted and round-tripped.
final class ConfigTests: XCTestCase {

    /// Synthesized Decodable ignores default values, so a config written by an
    /// older build would otherwise fail to decode and silently reset.
    func testConfigDecodesWhenNewerKeysAreAbsent() throws {
        let json = #"{"exeToken":"t","environments":[{"name":"Mine","setupScript":"echo hi"}]}"#
        let data = try JSONDecoder().decode(AppConfigData.self, from: Data(json.utf8))
        XCTAssertEqual(data.exeToken, "t")
        XCTAssertEqual(data.selectedEnvironment.setupScript, "echo hi")
        XCTAssertTrue(data.globalEnvironment.isEmpty)
        XCTAssertEqual(data.fontName, "Menlo")
        XCTAssertFalse(data.claudeSettings.isEmpty)
    }

    func testConfigDecodesFromAnEmptyObject() throws {
        let data = try JSONDecoder().decode(AppConfigData.self, from: Data("{}".utf8))
        XCTAssertEqual(data.exeToken, "")
        XCTAssertEqual(data.selectedEnvironment.startCommand, "claude")
    }

    /// The seeded Claude settings are shipped as text, so a typo would only
    /// surface on the VM.
    func testDefaultClaudeSettingsAreValidJSON() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(AppConfigData.defaultClaudeSettings.utf8)) as? [String: Any]
        XCTAssertNotNil(object)
        XCTAssertEqual(object?["theme"] as? String, "dark")
        XCTAssertEqual(object?["hasCompletedOnboarding"] as? Bool, true)
    }

    /// Hand-editable config: entries without an id must still load.
    func testEnvVarGeneratesAnIDWhenAbsent() throws {
        let json = #"[{"key":"FOO","value":"bar"}]"#
        let vars = try JSONDecoder().decode([EnvVar].self, from: Data(json.utf8))
        XCTAssertEqual(vars[0].key, "FOO")
        XCTAssertEqual(vars[0].value, "bar")
    }
}

/// The commit identity seeded onto a VM.
final class GitHubUserTests: XCTestCase {

    func testNoreplyEmailMatchesGitHubsFormat() {
        let user = GitHubUser(login: "leighmcculloch", id: 351529, name: "Leigh")
        XCTAssertEqual(user.noreplyEmail, "351529+leighmcculloch@users.noreply.github.com")
    }

    func testDisplayNameFallsBackToLoginWhenProfileNameIsBlank() {
        XCTAssertEqual(GitHubUser(login: "u", id: 1, name: nil).displayName, "u")
        XCTAssertEqual(GitHubUser(login: "u", id: 1, name: "").displayName, "u")
        XCTAssertEqual(GitHubUser(login: "u", id: 1, name: "Real Name").displayName, "Real Name")
    }
}

/// Status codes shown in the diff sidebar's file list.
final class GitFileChangeTests: XCTestCase {

    func testUntrackedIsDetected() {
        XCTAssertTrue(GitFileChange(status: "??", path: "a").isUntracked)
        XCTAssertFalse(GitFileChange(status: " M", path: "a").isUntracked)
    }

    func testIdentityIsThePath() {
        XCTAssertEqual(GitFileChange(status: " M", path: "src/a.swift").id, "src/a.swift")
    }
}
