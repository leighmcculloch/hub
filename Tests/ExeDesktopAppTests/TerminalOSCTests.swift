import XCTest
@testable import ExeDesktopApp

/// Reading the title and working directory out of a terminal's output stream.
final class TerminalOSCTests: XCTestCase {

    /// Feeds `text` as one chunk.
    private func scan(_ text: String) -> [TerminalOSCScanner.Event] {
        var scanner = TerminalOSCScanner()
        return scanner.scan(Data(text.utf8))
    }

    // MARK: - The sequences we use

    func testWorkingDirectoryFromOSC7() {
        XCTAssertEqual(
            scan("\u{1B}]7;file://host/Users/me/src\u{07}"),
            [.workingDirectory("file://host/Users/me/src")])
    }

    func testTitleFromOSC0AndOSC2() {
        XCTAssertEqual(scan("\u{1B}]0;zsh\u{07}"), [.title("zsh")])
        XCTAssertEqual(scan("\u{1B}]2;zsh\u{07}"), [.title("zsh")])
    }

    /// Both terminators are in the wild: BEL from most shells, ESC `\` (ST)
    /// from others.
    func testStringTerminatorEndsASequence() {
        XCTAssertEqual(
            scan("\u{1B}]7;file:///tmp\u{1B}\\"),
            [.workingDirectory("file:///tmp")])
    }

    /// A title can contain semicolons; only the first one delimits the code.
    func testOnlyTheFirstSemicolonSplitsTheCode() {
        XCTAssertEqual(scan("\u{1B}]2;a; b; c\u{07}"), [.title("a; b; c")])
    }

    func testEventsComeBackInOrder() {
        XCTAssertEqual(
            scan("\u{1B}]2;shell\u{07}ready\n\u{1B}]7;file:///tmp\u{07}"),
            [.title("shell"), .workingDirectory("file:///tmp")])
    }

    // MARK: - Everything else in the stream

    func testPlainOutputYieldsNothing() {
        XCTAssertEqual(scan("total 0\ndrwxr-xr-x  4 me  staff\n"), [])
    }

    /// Colours, cursor moves and the OSC codes we don't use are all ignored.
    func testUnusedSequencesAreIgnored() {
        XCTAssertEqual(scan("\u{1B}[31mred\u{1B}[0m"), [])
        XCTAssertEqual(scan("\u{1B}]4;1;rgb:ff/00/00\u{07}"), [])
        XCTAssertEqual(scan("\u{1B}]133;A\u{07}"), [])
    }

    func testPayloadWithoutASemicolonIsIgnored() {
        XCTAssertEqual(scan("\u{1B}]7\u{07}"), [])
    }

    // MARK: - Chunking

    /// Output arrives in arbitrarily sized reads, so a sequence split anywhere
    /// still has to be recognised.
    func testSequenceSplitAcrossChunks() {
        let sequence = "\u{1B}]7;file:///Users/me\u{07}"
        for split in 1..<sequence.count {
            var scanner = TerminalOSCScanner()
            let index = sequence.index(sequence.startIndex, offsetBy: split)
            let first = scanner.scan(Data(sequence[..<index].utf8))
            let second = scanner.scan(Data(sequence[index...].utf8))
            XCTAssertEqual(
                first + second,
                [.workingDirectory("file:///Users/me")],
                "split after \(split) bytes")
        }
    }

    /// A sequence that never terminates must not swallow the ones after it for
    /// the rest of the session, nor grow the buffer without bound.
    func testOverlongSequenceIsAbandoned() {
        var scanner = TerminalOSCScanner()
        XCTAssertEqual(scanner.scan(Data("\u{1B}]7;\(String(repeating: "x", count: 5000))".utf8)), [])
        XCTAssertEqual(
            scanner.scan(Data("\u{07}\u{1B}]7;file:///tmp\u{07}".utf8)),
            [.workingDirectory("file:///tmp")])
    }

    /// An ESC inside a payload that isn't the ST terminator means the sequence
    /// was truncated; drop it rather than guessing where it ended.
    func testTruncatedSequenceIsDropped() {
        XCTAssertEqual(
            scan("\u{1B}]7;file:///tmp\u{1B}[0m\u{1B}]2;shell\u{07}"),
            [.title("shell")])
    }
}
