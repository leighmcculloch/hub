import XCTest
@testable import ExeDesktopApp

/// The control-mode protocol, checked against transcripts recorded from a real
/// `tmux -C` session. Getting this wrong doesn't fail loudly — it silently
/// corrupts what a pane prints or loses a tab — so the fixtures here are
/// verbatim tmux output rather than what the protocol is remembered to be.
final class TmuxControlTests: XCTestCase {
    private func events(_ lines: [String]) -> [TmuxEvent] {
        var parser = TmuxControlParser()
        return lines.compactMap { parser.consume(line: Array($0.utf8)) }
    }

    // MARK: - Line buffering

    /// Reads are sized by the pipe, not by tmux: a line routinely spans two of
    /// them, and a partial line must be held rather than parsed as a short one.
    func testLinesAreReassembledAcrossReads() {
        var buffer = TmuxLineBuffer()
        XCTAssertEqual(buffer.lines(from: Array("%output %0 he".utf8)), [])
        XCTAssertEqual(buffer.lines(from: Array("llo\n%exit\n".utf8)).map(text),
                       ["%output %0 hello", "%exit"])
    }

    func testCarriageReturnsAndBlankLinesAreHandled() {
        var buffer = TmuxLineBuffer()
        XCTAssertEqual(buffer.lines(from: Array("a\r\n\nb\n".utf8)).map(text), ["a", "", "b"])
    }

    /// A newline landing exactly on a read boundary must not swallow the line.
    func testALineEndingOnAReadBoundary() {
        var buffer = TmuxLineBuffer()
        XCTAssertEqual(buffer.lines(from: Array("%exit".utf8)), [])
        XCTAssertEqual(buffer.lines(from: Array("\n".utf8)).map(text), ["%exit"])
    }

    private func text(_ line: [UInt8]) -> String { String(decoding: line, as: UTF8.self) }

    // MARK: - Pane output

    /// tmux escapes control bytes and backslashes as three octal digits, and
    /// passes everything else through as-is.
    func testOutputIsUnescapedToBytes() {
        let parsed = events([#"%output %0 \033[?2004hbash-5.2# "#])
        XCTAssertEqual(parsed, [.output(pane: "%0",
                                        bytes: Array("\u{1b}[?2004hbash-5.2# ".utf8))])
    }

    /// A literal backslash arrives as \134, so two of them are one backslash
    /// each — not an escape introducing the next byte.
    func testBackslashesAreUnescapedIndependently() {
        let parsed = events([#"%output %1 a\134\134b"#])
        XCTAssertEqual(parsed, [.output(pane: "%1", bytes: Array(#"a\\b"#.utf8))])
    }

    /// Bytes at or above a space are never escaped, so UTF-8 arrives raw. It has
    /// to survive as bytes: decoding the line as text and re-encoding would
    /// mangle any output that isn't valid UTF-8 in the first place.
    func testHighBytesPassThroughUntouched() {
        let star: [UInt8] = [0xE2, 0x98, 0x85]
        var line = Array("%output %2 ".utf8)
        line += star
        var parser = TmuxControlParser()
        XCTAssertEqual(parser.consume(line: line), .output(pane: "%2", bytes: star))
    }

    /// A pane can be written to with nothing to show for it.
    func testEmptyOutputIsStillAnEvent() {
        XCTAssertEqual(events(["%output %3 "]), [.output(pane: "%3", bytes: [])])
    }

    /// An incomplete escape is not an escape; eating the bytes after it would
    /// corrupt the rest of the line.
    func testTrailingBackslashIsKeptLiterally() {
        XCTAssertEqual(events([#"%output %0 ab\1"#]),
                       [.output(pane: "%0", bytes: Array(#"ab\1"#.utf8))])
    }

    /// Pane ids are not single digits once a session has been used for a while.
    func testMultiDigitPaneIds() {
        XCTAssertEqual(events(["%output %137 hi"]),
                       [.output(pane: "%137", bytes: Array("hi".utf8))])
    }

    // MARK: - Command replies

    func testReplyLinesAreCollected() {
        let parsed = events([
            "%begin 1785160745 277 1",
            "@0|0|1|%0|0|1|10|2|bash|/home/user",
            "%end 1785160745 277 1",
        ])
        XCTAssertEqual(parsed, [.reply(TmuxReply(lines: ["@0|0|1|%0|0|1|10|2|bash|/home/user"],
                                                 isError: false))])
    }

    func testErrorGuardMarksTheReply() {
        let parsed = events([
            "%begin 1785160752 287 1",
            "parse error: unknown command: bogus",
            "%error 1785160752 287 1",
        ])
        XCTAssertEqual(parsed, [.reply(TmuxReply(lines: ["parse error: unknown command: bogus"],
                                                 isError: true))])
    }

    /// tmux opens a block on attach that answers no command of ours (its flag is
    /// 0). Treating it as a reply would shift every later reply onto the wrong
    /// command, which is how a pane listing ends up being read as a screen
    /// capture.
    func testBlocksThatAnswerNoCommandAreDropped() {
        let parsed = events([
            "%begin 1785160407 264 0",
            "%end 1785160407 264 0",
            "%begin 1785160409 271 1",
            "one",
            "%end 1785160409 271 1",
        ])
        XCTAssertEqual(parsed, [.reply(TmuxReply(lines: ["one"], isError: false))])
    }

    /// Block contents are not escaped, so a captured screen can contain a line
    /// that looks like a guard. The command number is what tells them apart.
    func testAGuardForAnotherBlockIsJustContent() {
        let parsed = events([
            "%begin 1785160745 276 1",
            "%end 1785160745 999 1",
            "after",
            "%end 1785160745 276 1",
        ])
        XCTAssertEqual(parsed, [.reply(TmuxReply(lines: ["%end 1785160745 999 1", "after"],
                                                 isError: false))])
    }

    /// Likewise for output: inside a block it is text a command printed, not a
    /// pane writing to the screen.
    func testOutputInsideABlockIsContent() {
        let parsed = events([
            "%begin 1 2 1",
            "%output %0 captured",
            "%end 1 2 1",
        ])
        XCTAssertEqual(parsed, [.reply(TmuxReply(lines: ["%output %0 captured"], isError: false))])
    }

    /// capture-pane pads its output with the pane's blank lines.
    func testEmptyLinesInsideABlockAreKept() {
        let parsed = events(["%begin 1 2 1", "top", "", "%end 1 2 1"])
        XCTAssertEqual(parsed, [.reply(TmuxReply(lines: ["top", ""], isError: false))])
    }

    // MARK: - Notifications

    /// Everything that can change the tab strip collapses to one event: the
    /// client answers all of them by re-listing the panes.
    func testStructuralNotificationsAskForARefresh() {
        let lines = [
            "%window-add @1",
            "%window-close @1",
            "%unlinked-window-close @1",
            "%window-renamed @0 bash",
            "%window-pane-changed @1 %2",
            "%layout-change @1 419a,80x24,0,0[80x12,0,0,1,80x11,0,13,2] 419a,80x24,0,0 *",
            "%session-window-changed $0 @1",
            "%session-changed $0 exe",
        ]
        XCTAssertEqual(events(lines), Array(repeating: .paneListChanged, count: lines.count))
    }

    /// Notifications that say nothing about the panes must not cost a round
    /// trip each.
    func testUnrelatedNotificationsAreIgnored() {
        XCTAssertEqual(events(["%sessions-changed", "%pane-mode-changed %0", "%continue %0"]), [])
    }

    func testExitIsReportedWithItsReason() {
        XCTAssertEqual(events(["%exit"]), [.exit(reason: nil)])
        XCTAssertEqual(events(["%exit server exited"]), [.exit(reason: "server exited")])
    }

    // MARK: - Pane listing

    func testPanesAreParsed() {
        let panes = TmuxControl.parsePanes([
            "@0|0|1|1|%0|0|1|10|2|bash|/home/user/hub",
            "@1|1|2|0|%2|1|0|0|0|claude|/home/user",
        ])
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0], TmuxPane(
            id: "%0", windowID: "@0", windowIndex: 0, windowName: "bash", panesInWindow: 1,
            index: 0, isActive: true, cursorX: 10, cursorY: 2, currentPath: "/home/user/hub"))
        XCTAssertEqual(panes[1].id, "%2")
        XCTAssertFalse(panes[1].isActive)
    }

    /// `pane_active` is per-window, so a session with several windows has one
    /// active pane per window. Only the pane in the session's active window
    /// (`window_active` 1) is the focus — the others' `pane_active` must not
    /// win it. This is what makes a newly opened window take focus: tmux makes
    /// it the active window, so its pane is the one `isActive` picks out.
    func testOnlyTheActiveWindowsPaneIsTheFocus() {
        // Window @0 is the session's active window; @1 is not, even though its
        // pane is that window's active pane.
        let panes = TmuxControl.parsePanes([
            "@0|0|1|1|%0|0|1|10|2|bash|/home/user/hub",
            "@1|1|1|0|%2|0|1|0|0|claude|/home/user",
        ])
        XCTAssertEqual(panes.first { $0.isActive }?.id, "%0")
        XCTAssertFalse(panes[1].isActive)
    }

    /// A split window's tabs have to be told apart; an unsplit one shouldn't
    /// carry a pane number nobody needs.
    func testTitleNamesTheWindowAndOnlyNumbersSplits() {
        let panes = TmuxControl.parsePanes([
            "@0|0|1|1|%0|0|1|0|0|bash|/home",
            "@1|1|2|0|%1|1|1|0|0|vim|/home",
        ])
        XCTAssertEqual(panes[0].title, "bash")
        XCTAssertEqual(panes[1].title, "vim:1")
    }

    /// Window names are free text, so one can contain the field separator. The
    /// path is taken from the end and the name from what's left, which mangles
    /// one label instead of dropping the pane from the tab strip.
    func testASeparatorInTheWindowNameKeepsThePane() {
        let panes = TmuxControl.parsePanes(["@0|0|1|1|%0|0|1|0|0|a|b|/home/user"])
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].windowName, "a|b")
        XCTAssertEqual(panes[0].currentPath, "/home/user")
    }

    func testUnparseableRowsAreSkipped() {
        XCTAssertEqual(TmuxControl.parsePanes(["", "@0|0|1|%0", "@0|x|1|%0|0|1|0|0|n|/p"]), [])
    }

    // MARK: - Commands

    /// `-H` sends each byte through untranslated, which is the only way a pane
    /// receives typed UTF-8 as the bytes the terminal produced.
    func testSendKeysEncodesEveryByteAsHex() {
        XCTAssertEqual(TmuxControl.sendKeys(pane: "%0", bytes: [0x0d, 0xe2, 0x98, 0x85]),
                       ["send-keys -t %0 -H 0d e2 98 85"])
    }

    /// A paste is arbitrarily large; one command line for it is not.
    func testSendKeysSplitsLargeInput() {
        let bytes = [UInt8](repeating: 0x61, count: TmuxControl.sendKeysChunk + 1)
        let commands = TmuxControl.sendKeys(pane: "%0", bytes: bytes)
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[1].hasSuffix(" 61"))
        let sent = commands
            .map { $0.replacingOccurrences(of: "send-keys -t %0 -H ", with: "") }
            .joined(separator: " ")
            .split(separator: " ")
        XCTAssertEqual(sent.count, bytes.count)
    }

    func testSendKeysOfNothingSendsNothing() {
        XCTAssertEqual(TmuxControl.sendKeys(pane: "%0", bytes: []), [])
    }

    /// A control client has no size until it reports one, and a zero size would
    /// be refused.
    func testRefreshClientReportsASaneSize() {
        XCTAssertEqual(TmuxControl.refreshClient(cols: 100, rows: 30), "refresh-client -C 100,30")
        XCTAssertEqual(TmuxControl.refreshClient(cols: 0, rows: -1), "refresh-client -C 1,1")
    }

    /// The capture is exactly as many lines as the pane is tall, so the lines
    /// land on the rows they came from and the cursor move is absolute.
    func testRestoreScreenClearsDrawsAndPlacesTheCursor() {
        let restored = TmuxControl.restoreScreen(lines: ["one", "two"], cursorX: 4, cursorY: 1)
        XCTAssertEqual(String(decoding: restored, as: UTF8.self),
                       "\u{1b}[H\u{1b}[2Jone\r\ntwo\u{1b}[2;5H")
    }

    // MARK: - A recorded session

    /// One connection end to end, as recorded from tmux: attach, a command
    /// reply, output, a new window, and the exit.
    func testARecordedSessionParses() {
        let parsed = events([
            "%begin 1785160407 264 0",
            "%end 1785160407 264 0",
            "%window-add @0",
            "%sessions-changed",
            "%session-changed $0 exe",
            "%window-renamed @0 zsh",
            #"%output %0 \033[?2004hbash-5.2# "#,
            "%begin 1785160407 271 1",
            "@0|0|1|%0|0|1|10|0|bash|/home/user",
            "%end 1785160407 271 1",
            "%session-window-changed $0 @1",
            "%window-add @1",
            "%exit",
        ])
        XCTAssertEqual(parsed, [
            .paneListChanged,                                   // %window-add @0
            .paneListChanged,                                   // %session-changed
            .paneListChanged,                                   // %window-renamed
            .output(pane: "%0", bytes: Array("\u{1b}[?2004hbash-5.2# ".utf8)),
            .reply(TmuxReply(lines: ["@0|0|1|%0|0|1|10|0|bash|/home/user"], isError: false)),
            .paneListChanged,                                   // %session-window-changed
            .paneListChanged,                                   // %window-add @1
            .exit(reason: nil),
        ])
    }
}
