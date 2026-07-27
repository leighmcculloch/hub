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
        XCTAssertEqual(decoded.setupScript, defaults.setupScript)
        XCTAssertEqual(decoded.fontName, defaults.fontName)
        XCTAssertEqual(decoded.fontSize, defaults.fontSize)
        XCTAssertEqual(decoded.startCommand, defaults.startCommand)
        XCTAssertEqual(decoded.claudeSettings, defaults.claudeSettings)
        XCTAssertTrue(decoded.environment.isEmpty)
    }

    /// A file from an older build has the keys it knew about and none of the
    /// newer ones; the known values must survive.
    func testAnOlderFileKeepsItsValuesAndDefaultsTheRest() throws {
        let decoded = try decode(#"{"exeToken":"secret","fontName":"Fira Code"}"#)

        XCTAssertEqual(decoded.exeToken, "secret")
        XCTAssertEqual(decoded.fontName, "Fira Code")
        XCTAssertEqual(decoded.startCommand, AppConfigData().startCommand)
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
        {"exeToken":42,"setupScript":["a"],"fontName":true,"startCommand":"claude"}
        """)
        let defaults = AppConfigData()

        XCTAssertEqual(decoded.exeToken, defaults.exeToken)
        XCTAssertEqual(decoded.setupScript, defaults.setupScript)
        XCTAssertEqual(decoded.fontName, defaults.fontName)
        XCTAssertEqual(decoded.startCommand, "claude", "the one good value was lost")
    }

    func testAnExplicitNullFallsBackToTheDefault() throws {
        XCTAssertEqual(try decode(#"{"fontName":null}"#).fontName, AppConfigData().fontName)
    }

    /// A malformed environment list shouldn't take the rest of the config down.
    func testAMalformedEnvironmentListFallsBackToEmpty() throws {
        let decoded = try decode(#"{"environment":"not a list","exeToken":"secret"}"#)
        XCTAssertTrue(decoded.environment.isEmpty)
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
        original.setupScript = "brew install ripgrep"
        original.startCommand = "claude"
        original.fontName = "SF Mono"
        original.fontSize = 15
        original.environment = [EnvVar(key: "FOO", value: "bar")]

        let decoded = try JSONDecoder().decode(
            AppConfigData.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.exeToken, original.exeToken)
        XCTAssertEqual(decoded.setupScript, original.setupScript)
        XCTAssertEqual(decoded.startCommand, original.startCommand)
        XCTAssertEqual(decoded.fontName, original.fontName)
        XCTAssertEqual(decoded.fontSize, original.fontSize)
        XCTAssertEqual(decoded.environment, original.environment)
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
        let decoded = try decode(#"{"environment":[{"key":"FOO","value":"bar"}]}"#)
        XCTAssertEqual(decoded.environment.map(\.key), ["FOO"])
        XCTAssertEqual(decoded.environment.map(\.value), ["bar"])
    }

    /// Generated ids must be distinct, or SwiftUI collapses the rows in the
    /// settings editor.
    func testGeneratedEnvironmentIDsAreDistinct() throws {
        let decoded = try decode("""
        {"environment":[{"key":"A","value":"1"},{"key":"B","value":"2"}]}
        """)
        XCTAssertEqual(Set(decoded.environment.map(\.id)).count, 2)
    }

    func testAnEnvironmentEntryKeepsAnExplicitID() throws {
        let id = UUID()
        let decoded = try decode(#"{"environment":[{"id":"\#(id.uuidString)","key":"K"}]}"#)
        XCTAssertEqual(decoded.environment.first?.id, id)
    }
}
