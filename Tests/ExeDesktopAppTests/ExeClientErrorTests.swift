import XCTest
@testable import ExeDesktopApp

/// The messages shown when an exe.dev call fails.
final class ExeClientErrorTests: XCTestCase {

    private func failure(_ status: Int, _ body: String) -> String? {
        ExeClient.failure(status: status, body: Data(body.utf8))?.message
    }

    // MARK: - Success

    func testASuccessfulResponseIsNotAFailure() {
        XCTAssertNil(failure(200, #"{"vms":[]}"#))
        XCTAssertNil(failure(201, #"{"vm_name":"x"}"#))
        XCTAssertNil(failure(204, ""))
    }

    /// A JSON array is a normal success shape — `integrations list --json`
    /// returns one — and must not be mistaken for an error object.
    func testAJSONArrayIsNotAFailure() {
        XCTAssertNil(failure(200, #"[{"name":"a"},{"name":"b"}]"#))
    }

    /// A field that merely happens to be called "error" but isn't a string
    /// shouldn't be reported as one.
    func testANonStringErrorFieldIsNotAFailure() {
        XCTAssertNil(failure(200, #"{"error":null}"#))
        XCTAssertNil(failure(200, #"{"error":false}"#))
    }

    // MARK: - Failure

    /// exe.dev reports errors in the body regardless of status, so the body is
    /// checked before the status code.
    func testTheAPIErrorMessageIsUsedEvenOnA200() throws {
        let message = try XCTUnwrap(failure(200, #"{"error":"invalid tag name"}"#))
        XCTAssertEqual(message, "exe.dev (HTTP 200): invalid tag name")
    }

    func testAStatusOnlyFailureIncludesTheBody() throws {
        let message = try XCTUnwrap(failure(500, "upstream exploded"))
        XCTAssertTrue(message.contains("500"), message)
        XCTAssertTrue(message.contains("upstream exploded"), message)
    }

    /// An empty body would otherwise leave the message trailing off after the
    /// colon.
    func testAnEmptyBodySaysSoRatherThanTrailingOff() throws {
        let message = try XCTUnwrap(failure(502, ""))
        XCTAssertTrue(message.contains("(empty response)"), message)
    }

    func testAWhitespaceOnlyBodyCountsAsEmpty() throws {
        XCTAssertTrue(try XCTUnwrap(failure(502, "\n\n   \t")).contains("(empty response)"))
    }

    // MARK: - Bodies that aren't the API talking

    /// A failing proxy answers with an HTML page. The whole thing in an alert is
    /// unreadable, and this string is held in view state.
    func testAnHTMLErrorPageIsCondensedToOneLine() throws {
        let page = """
        <html>
        <head><title>502 Bad Gateway</title></head>
        <body>
        <center><h1>502 Bad Gateway</h1></center>
        <hr><center>nginx</center>
        </body>
        </html>
        """
        let message = try XCTUnwrap(failure(502, page))
        XCTAssertFalse(message.contains("\n"), "message spans lines: \(message)")
        XCTAssertTrue(message.contains("502 Bad Gateway"), message)
    }

    func testAnAbsurdlyLongBodyIsTruncated() throws {
        let message = try XCTUnwrap(failure(500, String(repeating: "x", count: 100_000)))
        XCTAssertLessThan(message.count, 400, "message kept the whole body")
        XCTAssertTrue(message.hasSuffix("…"), message)
    }

    func testAnAbsurdlyLongAPIErrorIsAlsoTruncated() throws {
        let body = #"{"error":"\#(String(repeating: "y", count: 5_000))"}"#
        XCTAssertLessThan(try XCTUnwrap(failure(422, body)).count, 400)
    }

    // MARK: - Pointing at the fix

    /// An expired token is the most common failure and the least
    /// self-explanatory, so the message has to say where to change it.
    func testAuthFailuresPointAtTheTokenSetting() throws {
        for status in [401, 403] {
            let message = try XCTUnwrap(failure(status, #"{"error":"unauthorized"}"#))
            XCTAssertTrue(message.contains("Settings"), "\(status): \(message)")
            XCTAssertTrue(message.contains("EXE_DEV_TOKEN"), "\(status): \(message)")
        }
    }

    /// The hint must not appear on failures a token can't fix, or it sends the
    /// user to the wrong place.
    func testOtherFailuresDoNotMentionTheToken() throws {
        for status in [404, 422, 500, 502] {
            let message = try XCTUnwrap(failure(status, #"{"error":"nope"}"#))
            XCTAssertFalse(message.contains("EXE_DEV_TOKEN"), "\(status): \(message)")
        }
    }

    // MARK: - condense

    func testCondenseCollapsesRunsOfWhitespace() {
        XCTAssertEqual(ExeClient.condense("a\n\n\tb   c"), "a b c")
    }

    func testCondenseLeavesAnOrdinaryMessageAlone() {
        XCTAssertEqual(ExeClient.condense("invalid tag name"), "invalid tag name")
    }

    /// Invalid UTF-8 must degrade to something rather than crashing or
    /// producing an empty alert.
    func testAnUndecodableBodyStillProducesAMessage() throws {
        let invalid = Data([0xFF, 0xFE, 0xFD])
        let message = try XCTUnwrap(ExeClient.failure(status: 500, body: invalid)?.message)
        XCTAssertTrue(message.contains("500"), message)
    }
}
