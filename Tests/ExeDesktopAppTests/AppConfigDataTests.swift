import XCTest
@testable import ExeDesktopApp

/// Loading the persisted configuration. The file is written by the app but the
/// format invites hand-editing, and an older build's file has to keep working.
final class AppConfigDataTests: XCTestCase {

    private func decode(_ json: String) throws -> AppConfigData {
        try JSONDecoder().decode(AppConfigData.self, from: Data(json.utf8))
    }

    // MARK: - Missing keys

    /// The reason this decoder is hand-written: the synthesized one throws on
    /// the first missing key and the whole file is discarded.
    func testAnEmptyObjectYieldsTheDefaults() throws {
        let decoded = try decode("{}")
        let defaults = AppConfigData()

        XCTAssertEqual(decoded.exeToken, defaults.exeToken)
        XCTAssertEqual(decoded.environments, defaults.environments)
        XCTAssertEqual(decoded.fontName, defaults.fontName)
        XCTAssertEqual(decoded.fontSize, defaults.fontSize)
        XCTAssertEqual(decoded.claudeSettings, defaults.claudeSettings)
        XCTAssertNil(decoded.model)
        XCTAssertTrue(decoded.globalEnvironment.isEmpty)
    }

    /// A file from an older build has the keys it knew about and none of the
    /// newer ones; the known values must survive.
    func testAnOlderFileKeepsItsValuesAndDefaultsTheRest() throws {
        let decoded = try decode(#"{"exeToken":"secret","fontName":"Fira Code"}"#)

        XCTAssertEqual(decoded.exeToken, "secret")
        XCTAssertEqual(decoded.fontName, "Fira Code")
        XCTAssertEqual(decoded.environments, AppConfigData().environments)
        XCTAssertEqual(decoded.claudeSettings, AppConfigData.defaultClaudeSettings)
    }

    /// The fallbacks must be the real defaults, not a second copy of them that
    /// can drift from the property initializers.
    func testDefaultsFromDecodingMatchTheDefaultsFromInit() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Every field at once, so a default added later is covered without
        // anyone remembering to extend this test.
        XCTAssertEqual(try encoder.encode(decode("{}")),
                       try encoder.encode(AppConfigData()))
    }

    // MARK: - Malformed values

    /// One bad entry should cost that entry, not the file. Losing a configured
    /// token because the font size was typed as a string would be a bad trade.
    func testAWrongTypedValueFallsBackWithoutLosingTheRest() throws {
        let decoded = try decode(#"{"exeToken":"secret","fontSize":"thirteen"}"#)

        XCTAssertEqual(decoded.exeToken, "secret", "a bad font size discarded the token")
        XCTAssertEqual(decoded.fontSize, AppConfigData().fontSize)
    }

    func testSeveralWrongTypedValuesEachFallBackIndependently() throws {
        let decoded = try decode("""
        {"exeToken":42,"environments":["a"],"fontName":true,"claudeSettings":"{}"}
        """)
        let defaults = AppConfigData()

        XCTAssertEqual(decoded.exeToken, defaults.exeToken)
        XCTAssertEqual(decoded.environments, defaults.environments)
        XCTAssertEqual(decoded.fontName, defaults.fontName)
        XCTAssertEqual(decoded.claudeSettings, "{}", "the one good value was lost")
    }

    func testAnExplicitNullFallsBackToTheDefault() throws {
        XCTAssertEqual(try decode(#"{"fontName":null}"#).fontName, AppConfigData().fontName)
    }

    /// A malformed environment list shouldn't take the rest of the config down.
    func testAMalformedEnvironmentListFallsBackToEmpty() throws {
        let decoded = try decode(#"{"globalEnvironment":"not a list","exeToken":"secret"}"#)
        XCTAssertTrue(decoded.globalEnvironment.isEmpty)
        XCTAssertEqual(decoded.exeToken, "secret")
    }

    // MARK: - Font size bounds

    /// Clamped rather than defaulted, so an out-of-range value still lands on
    /// something usable instead of a terminal that can't be read.
    /// Concrete numbers, deliberately: comparing against `fontSizeRange` would
    /// pass even if the range itself were widened to allow a zero-point font.
    func testAnOutOfRangeFontSizeIsClamped() throws {
        XCTAssertEqual(try decode(#"{"fontSize":0}"#).fontSize, 8)
        XCTAssertEqual(try decode(#"{"fontSize":-5}"#).fontSize, 8)
        XCTAssertEqual(try decode(#"{"fontSize":400}"#).fontSize, 32)
    }

    /// The bounds themselves have to stay sensible — the clamp is only as good
    /// as the range it clamps to.
    func testTheAllowedRangeIsReadable() {
        XCTAssertGreaterThanOrEqual(AppConfigData.fontSizeRange.lowerBound, 6)
        XCTAssertLessThanOrEqual(AppConfigData.fontSizeRange.upperBound, 100)
    }

    func testAnInRangeFontSizeIsKept() throws {
        XCTAssertEqual(try decode(#"{"fontSize":18}"#).fontSize, 18)
    }

    func testTheDefaultFontSizeIsInsideTheAllowedRange() {
        XCTAssertTrue(AppConfigData.fontSizeRange.contains(AppConfigData().fontSize))
    }

    // MARK: - Round trip

    func testConfigurationSurvivesAnEncodeDecodeCycle() throws {
        var original = AppConfigData()
        original.exeToken = "token"
        original.environments = [SessionEnvironment(
            name: "Pi", setupScript: "brew install ripgrep", startCommand: "pi",
            environment: [EnvVar(key: "PI", value: "1")])]
        original.selectedEnvironmentID = original.environments[0].id
        original.model = GatewayModel(provider: "anthropic", model: "claude-opus-5")
        original.fontName = "SF Mono"
        original.fontSize = 15
        original.globalEnvironment = [EnvVar(key: "FOO", value: "bar")]

        let decoded = try JSONDecoder().decode(
            AppConfigData.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.exeToken, original.exeToken)
        XCTAssertEqual(decoded.environments, original.environments)
        XCTAssertEqual(decoded.selectedEnvironmentID, original.selectedEnvironmentID)
        XCTAssertEqual(decoded.model, original.model)
        XCTAssertEqual(decoded.fontName, original.fontName)
        XCTAssertEqual(decoded.fontSize, original.fontSize)
        XCTAssertEqual(decoded.globalEnvironment, original.globalEnvironment)
    }

    /// The default settings blob is shipped to every VM, so it has to be valid
    /// JSON — a typo here would break the bootstrap on every new session.
    func testTheDefaultClaudeSettingsAreValidJSON() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(AppConfigData.defaultClaudeSettings.utf8))
        let dictionary = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(dictionary["hasCompletedOnboarding"] as? Bool, true)
    }

    // MARK: - Environment entries

    /// The config file can be hand-edited with bare key/value pairs, so a
    /// missing id has to be generated rather than failing the decode.
    func testAnEnvironmentEntryWithoutAnIDStillDecodes() throws {
        let decoded = try decode(#"{"globalEnvironment":[{"key":"FOO","value":"bar"}]}"#)
        XCTAssertEqual(decoded.globalEnvironment.map(\.key), ["FOO"])
        XCTAssertEqual(decoded.globalEnvironment.map(\.value), ["bar"])
    }

    /// Generated ids must be distinct, or SwiftUI collapses the rows in the
    /// settings editor.
    func testGeneratedEnvironmentIDsAreDistinct() throws {
        let decoded = try decode("""
        {"globalEnvironment":[{"key":"A","value":"1"},{"key":"B","value":"2"}]}
        """)
        XCTAssertEqual(Set(decoded.globalEnvironment.map(\.id)).count, 2)
    }

    func testAnEnvironmentEntryKeepsAnExplicitID() throws {
        let id = UUID()
        let decoded = try decode(#"{"globalEnvironment":[{"id":"\#(id.uuidString)","key":"K"}]}"#)
        XCTAssertEqual(decoded.globalEnvironment.first?.id, id)
    }

    // MARK: - Environments

    /// The two harnesses the app ships knowing about. The Claude Code one
    /// carries the token variable so there's a row to paste into.
    func testTheDefaultEnvironmentsAreClaudeCodeAndCodex() {
        let environments = AppConfigData().environments
        XCTAssertEqual(environments.map(\.name), ["Claude Code", "Codex"])
        XCTAssertEqual(environments[0].startCommand, "claude")
        XCTAssertEqual(environments[0].environment.map(\.key), ["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(environments[0].environment.map(\.value), [""])
        XCTAssertEqual(environments[1].startCommand, "codex")
        XCTAssertTrue(environments[1].environment.isEmpty)
    }

    func testTheSelectedEnvironmentIsTheOneChosen() throws {
        var config = AppConfigData()
        config.selectedEnvironmentID = config.environments[1].id
        XCTAssertEqual(config.selectedEnvironment.name, "Codex")
    }

    /// Nothing chosen, or a choice that has since been deleted: either way a
    /// session still has to have something to run.
    func testAMissingSelectionFallsBackToTheFirstEnvironment() {
        var config = AppConfigData()
        XCTAssertEqual(config.selectedEnvironment.name, "Claude Code")
        config.selectedEnvironmentID = UUID()
        XCTAssertEqual(config.selectedEnvironment.name, "Claude Code")
    }

    /// An empty list would leave the settings editor with nothing to edit and
    /// no way back.
    func testAnEmptyEnvironmentListFallsBackToTheDefaults() throws {
        XCTAssertEqual(try decode(#"{"environments":[]}"#).environments,
                       AppConfigData().environments)
    }

    /// Default ids are fixed, so a file that records only the selection still
    /// points at the same environment on the next launch.
    func testASelectionOfADefaultEnvironmentSurvivesWithoutTheList() throws {
        let id = AppConfigData().environments[1].id
        let decoded = try decode(#"{"selectedEnvironmentID":"\#(id.uuidString)"}"#)
        XCTAssertEqual(decoded.selectedEnvironment.name, "Codex")
    }

    func testAnEnvironmentDecodesWithoutEveryField() throws {
        let decoded = try decode(#"{"environments":[{"name":"Bare"}]}"#)
        XCTAssertEqual(decoded.environments.map(\.name), ["Bare"])
        XCTAssertEqual(decoded.environments[0].startCommand, "")
        XCTAssertEqual(decoded.environments[0].setupScript, "")
    }

    // MARK: - Upgrading from the single setup script

    /// The setup script someone wrote before environments existed has to come
    /// with them, or an upgrade silently drops it.
    func testALegacySetupScriptBecomesTheFirstEnvironment() throws {
        let decoded = try decode("""
        {"setupScript":"apt install ripgrep","startCommand":"claude --resume"}
        """)

        XCTAssertEqual(decoded.environments.count, AppConfigData().environments.count)
        XCTAssertEqual(decoded.environments[0].setupScript, "apt install ripgrep")
        XCTAssertEqual(decoded.environments[0].startCommand, "claude --resume")
        XCTAssertEqual(decoded.selectedEnvironment.id, decoded.environments[0].id)
    }

    /// Once environments are in the file they are the truth; a stale legacy key
    /// left behind by hand-editing must not overwrite them.
    func testALegacySetupScriptIsIgnoredOnceEnvironmentsExist() throws {
        let decoded = try decode("""
        {"setupScript":"old","environments":[{"name":"Mine","setupScript":"new"}]}
        """)
        XCTAssertEqual(decoded.environments.map(\.setupScript), ["new"])
    }

    /// The global variables were called `environment` before the per-environment
    /// lists forced the clearer name.
    func testLegacyEnvironmentVariablesBecomeTheGlobalOnes() throws {
        let decoded = try decode(#"{"environment":[{"key":"FOO","value":"bar"}]}"#)
        XCTAssertEqual(decoded.globalEnvironment.map(\.key), ["FOO"])
    }

    func testTheNewVariablesKeyWinsOverTheLegacyOne() throws {
        let decoded = try decode("""
        {"environment":[{"key":"OLD"}],"globalEnvironment":[{"key":"NEW"}]}
        """)
        XCTAssertEqual(decoded.globalEnvironment.map(\.key), ["NEW"])
    }

    // MARK: - Model selection

    /// Nil is "Custom": nothing is configured and the VM's own setup stands.
    func testNoModelIsSelectedByDefault() throws {
        XCTAssertNil(AppConfigData().model)
        XCTAssertNil(try decode("{}").model)
    }

    func testASelectedModelRoundTrips() throws {
        let decoded = try decode("""
        {"model":{"provider":"fireworks","model":"accounts/fireworks/models/glm-5p2"}}
        """)
        XCTAssertEqual(decoded.model?.provider, "fireworks")
        XCTAssertEqual(decoded.model?.model, "accounts/fireworks/models/glm-5p2")
    }

    /// A half-written model entry shouldn't cost the rest of the file.
    func testAMalformedModelFallsBackToCustom() throws {
        let decoded = try decode(#"{"model":{"provider":"anthropic"},"exeToken":"secret"}"#)
        XCTAssertNil(decoded.model)
        XCTAssertEqual(decoded.exeToken, "secret")
    }
}
