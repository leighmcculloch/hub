import XCTest
@testable import ExeDesktopApp

/// Combining the three sources of VM variables: global, the session
/// environment's, and the model's.
final class EnvVarTests: XCTestCase {

    private func merged(_ lists: [[EnvVar]]) -> [(String, String)] {
        EnvVar.merged(lists).map { ($0.key, $0.value) }
    }

    func testVariablesFromEverySourceAreKept() {
        let result = merged([
            [EnvVar(key: "GLOBAL", value: "1")],
            [EnvVar(key: "ENVIRONMENT", value: "2")],
            [EnvVar(key: "MODEL", value: "3")],
        ])
        XCTAssertEqual(result.map(\.0), ["GLOBAL", "ENVIRONMENT", "MODEL"])
    }

    /// The case this ordering exists for: pointing Claude Code at the gateway
    /// means blanking the token the Claude Code environment sets.
    func testALaterListWinsOnASharedKey() {
        let result = merged([
            [EnvVar(key: "CLAUDE_CODE_OAUTH_TOKEN", value: "sk-secret")],
            [EnvVar(key: "CLAUDE_CODE_OAUTH_TOKEN", value: "")],
        ])
        XCTAssertEqual(result.map(\.0), ["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(result.first?.1, "")
    }

    /// The winning value replaces the losing one in place, so the order the
    /// keys were introduced in is what the progress line reports.
    func testOverridingAValueKeepsItsPosition() {
        let result = merged([
            [EnvVar(key: "A", value: "1"), EnvVar(key: "B", value: "2")],
            [EnvVar(key: "A", value: "3")],
        ])
        XCTAssertEqual(result.map(\.0), ["A", "B"])
        XCTAssertEqual(result.first?.1, "3")
    }

    /// Nameless rows can't be set on the VM, and the settings editor says so.
    func testNamelessRowsAreDropped() {
        XCTAssertEqual(merged([[EnvVar(key: "", value: "orphan"), EnvVar(key: "A")]]).map(\.0), ["A"])
    }

    func testMergingNothingYieldsNothing() {
        XCTAssertTrue(EnvVar.merged([[], []]).isEmpty)
    }
}
