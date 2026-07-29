import Foundation

/// One pane of the tmux session, as reported by `list-panes`. The app shows one
/// terminal tab per pane, so this is what a tab is built from.
struct TmuxPane: Equatable {
    /// tmux's own pane id, e.g. `%3`. Stable for the pane's whole life, and
    /// what `%output` and `send-keys` address.
    let id: String
    /// The window the pane belongs to, e.g. `@1`.
    let windowID: String
    let windowIndex: Int
    let windowName: String
    /// How many panes that window has; a split window needs its tabs told apart.
    let panesInWindow: Int
    /// Pane index within its window.
    let index: Int
    let isActive: Bool
    let cursorX: Int
    let cursorY: Int
    /// The pane's working directory — tmux swallows OSC 7, so this is the only
    /// way to know it.
    let currentPath: String

    /// The tab label: the window name, which tmux keeps set to the running
    /// command, plus the pane index when the window is split.
    var title: String {
        panesInWindow > 1 ? "\(windowName):\(index)" : windowName
    }
}

/// The reply to one command sent to tmux. Which command it answers is not on
/// the wire: replies come back in the order the commands were sent, so the
/// caller pairs them against its own queue of sent commands.
struct TmuxReply: Equatable {
    var lines: [String]
    /// True when tmux closed the block with `%error` instead of `%end`.
    var isError: Bool
}

/// Something tmux reported on its control stream.
enum TmuxEvent: Equatable {
    /// Bytes a pane wrote, already unescaped.
    case output(pane: String, bytes: [UInt8])
    /// Windows or panes were added, closed, renamed or relaid out. Every such
    /// notification collapses to this: the client answers all of them the same
    /// way, by re-listing the panes, so tracking each one separately would only
    /// duplicate what `list-panes` already says.
    case paneListChanged
    /// A command's reply, in the order the commands were sent.
    case reply(TmuxReply)
    /// tmux is finished with us — the session was killed or the server exited.
    case exit(reason: String?)
}

/// The tmux control-mode protocol (`tmux -C`): parsing what tmux writes on
/// stdout, and building the commands written back to its stdin.
///
/// Pure text handling, free of Apple-only imports so it stays testable off
/// macOS. `TmuxClient` owns the process and the I/O.
enum TmuxControl {
    /// Bytes per `send-keys`. Keystrokes are one or two bytes, but a paste is
    /// arbitrarily large and each byte costs three characters on the wire, so
    /// it is split rather than written as one enormous command line.
    static let sendKeysChunk = 512

    /// What each `list-panes` row contains. The two free-text fields come last
    /// so a `|` inside a window name can't be mistaken for a separator (see
    /// `parsePanes`).
    static let paneFormat = "#{window_id}|#{window_index}|#{window_panes}"
        + "|#{pane_id}|#{pane_index}|#{pane_active}|#{cursor_x}|#{cursor_y}"
        + "|#{window_name}|#{pane_current_path}"

    /// Every pane of every window in the attached session. `-s` scopes it to the
    /// session (not just the current window) without dragging in other sessions
    /// the way `-a` would.
    static func listPanes() -> String {
        "list-panes -s -F \"\(paneFormat)\""
    }

    /// Parse a `list-panes` reply. Rows that don't have every field are skipped
    /// rather than guessed at.
    ///
    /// Only the *first* eight fields are positional. A window name can contain
    /// the separator (tmux allows any name), so the trailing path is taken from
    /// the end and whatever lies between is the name — that way a stray `|`
    /// mangles one label instead of dropping the pane from the tab bar.
    static func parsePanes(_ lines: [String]) -> [TmuxPane] {
        lines.compactMap { line in
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 10,
                  let windowIndex = Int(fields[1]),
                  let panesInWindow = Int(fields[2]),
                  let index = Int(fields[4]),
                  let cursorX = Int(fields[6]),
                  let cursorY = Int(fields[7])
            else { return nil }
            return TmuxPane(
                id: fields[3],
                windowID: fields[0],
                windowIndex: windowIndex,
                windowName: fields[8..<(fields.count - 1)].joined(separator: "|"),
                panesInWindow: panesInWindow,
                index: index,
                isActive: fields[5] == "1",
                cursorX: cursorX,
                cursorY: cursorY,
                currentPath: fields[fields.count - 1])
        }
    }

    /// Keystrokes for a pane. `-H` takes one byte per argument and sends it
    /// through untranslated, so the pane's program sees exactly what the
    /// terminal view produced — including UTF-8, which would otherwise be
    /// re-encoded as if each byte were a character.
    static func sendKeys(pane: String, bytes: [UInt8]) -> [String] {
        stride(from: 0, to: bytes.count, by: sendKeysChunk).map { start in
            let chunk = bytes[start..<min(start + sendKeysChunk, bytes.count)]
            return "send-keys -t \(pane) -H "
                + chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }

    /// Tell tmux how big this client is; it resizes the session's windows to
    /// match. Control clients start with no size at all, so this has to be sent
    /// before anything renders sensibly.
    ///
    /// The `width,height` spelling is used rather than `widthxheight` because
    /// tmux has accepted it for far longer.
    static func refreshClient(cols: Int, rows: Int) -> String {
        "refresh-client -C \(max(1, cols)),\(max(1, rows))"
    }

    static func newWindow() -> String { "new-window" }

    static func killPane(_ pane: String) -> String { "kill-pane -t \(pane)" }

    /// Follow the tab selection in tmux itself, so another attached client — and
    /// anything that acts on the "current" pane — agrees with what's on screen.
    static func selectPane(window: String, pane: String) -> [String] {
        ["select-window -t \(window)", "select-pane -t \(pane)"]
    }

    /// The pane's visible screen, with its colours (`-e`). tmux replays nothing
    /// on attach, so without this an already-running session would open as a
    /// blank tab until the program in it happened to redraw.
    static func capturePane(_ pane: String) -> String {
        "capture-pane -p -e -t \(pane)"
    }

    /// Turn a captured screen back into something to feed a terminal: clear,
    /// draw the lines, then put the cursor where tmux says it is.
    ///
    /// The capture is exactly as many lines as the pane is tall, so the lines
    /// land on the rows they came from and the absolute cursor move is correct.
    static func restoreScreen(lines: [String], cursorX: Int, cursorY: Int) -> [UInt8] {
        let escape = "\u{1b}"
        var text = "\(escape)[H\(escape)[2J"
        text += lines.joined(separator: "\r\n")
        text += "\(escape)[\(cursorY + 1);\(cursorX + 1)H"
        return Array(text.utf8)
    }

    /// tmux escapes `\` and every byte below a space as a three-digit octal
    /// sequence in `%output`, and passes everything else — including raw UTF-8 —
    /// through untouched. So this has to work on bytes: decoding the line as
    /// text first would replace any byte sequence that isn't valid UTF-8.
    static func unescapeOutput(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            let digits = bytes.index(index, offsetBy: 4, limitedBy: bytes.endIndex)
            if byte == UInt8(ascii: "\\"), let end = digits,
               let value = octalValue(bytes[bytes.index(after: index)..<end]) {
                result.append(value)
                index = end
            } else {
                result.append(byte)
                index = bytes.index(after: index)
            }
        }
        return result
    }

    /// Three octal digits as a byte, or nil if they aren't three octal digits.
    /// A lone backslash is then kept literally rather than eating what follows.
    private static func octalValue(_ digits: ArraySlice<UInt8>) -> UInt8? {
        var value = 0
        for digit in digits {
            guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { return nil }
            value = value * 8 + Int(digit - UInt8(ascii: "0"))
        }
        return value <= 0xFF ? UInt8(value) : nil
    }
}

/// Splits a stream of bytes into protocol lines.
///
/// Reads arrive in whatever sizes the pipe hands over, which has nothing to do
/// with where tmux's lines end: one read can hold a hundred notifications and
/// half of the next.
struct TmuxLineBuffer {
    private var pending: [UInt8] = []

    /// The complete lines in `data`, with anything left over held for next time.
    mutating func lines(from data: some Sequence<UInt8>) -> [[UInt8]] {
        pending.append(contentsOf: data)
        var lines: [[UInt8]] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = Array(pending[start..<newline])
            // tmux escapes its own carriage returns, so a bare one here is only
            // ever a line terminator that came through as CRLF.
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            lines.append(line)
            start = pending.index(after: newline)
        }
        pending.removeSubrange(pending.startIndex..<start)
        return lines
    }
}

/// Turns tmux's control stream, line by line, into events.
///
/// tmux writes two kinds of line: notifications starting with `%`, and command
/// replies wrapped in a `%begin`/`%end` (or `%error`) block. Reply blocks arrive
/// in the order the commands were sent, which is what lets the client pair them
/// up without any identifier of its own.
struct TmuxControlParser {
    /// The block being accumulated, if any.
    private var block: Block?

    private struct Block {
        /// The number from `%begin`, echoed by the closing guard. Checked so a
        /// captured screen containing a line that looks like `%end` doesn't end
        /// the block early — block contents are not escaped.
        let number: String
        /// tmux sets the guard's flag when the command came from *this* client.
        /// A block without it is one tmux ran for its own reasons (the initial
        /// attach, another client's command) and has no command of ours to pair
        /// with, so it is dropped rather than shifting every later reply by one.
        let isReply: Bool
        var lines: [String]
    }

    /// Feed one line, without its terminator. Returns an event when the line
    /// completes one.
    mutating func consume(line: [UInt8]) -> TmuxEvent? {
        // Only %output can carry bytes that aren't text, and it is the hot path
        // besides, so it is matched before the line is decoded.
        if let event = outputEvent(line) { return event }

        let text = String(decoding: line, as: UTF8.self)

        if block != nil {
            return consumeInBlock(text)
        }
        guard text.hasPrefix("%") else { return nil }

        let fields = text.split(separator: " ", omittingEmptySubsequences: false)
        switch fields[0] {
        case "%begin":
            // %begin <time> <number> <flags>
            block = Block(number: fields.count > 2 ? String(fields[2]) : "",
                          isReply: fields.count > 3 && fields[3] != "0",
                          lines: [])
            return nil
        case "%exit":
            let reason = text.dropFirst("%exit".count).trimmingCharacters(in: .whitespaces)
            return .exit(reason: reason.isEmpty ? nil : reason)
        case "%window-add", "%window-close", "%unlinked-window-close", "%window-renamed",
             "%window-pane-changed", "%layout-change", "%session-window-changed",
             "%session-changed":
            return .paneListChanged
        default:
            return nil
        }
    }

    /// A line inside a `%begin` block: either the guard that closes it, or one
    /// more line of the command's output.
    private mutating func consumeInBlock(_ text: String) -> TmuxEvent? {
        guard var block else { return nil }
        let fields = text.split(separator: " ", omittingEmptySubsequences: false)
        let isGuard = fields.count > 2 && String(fields[2]) == block.number
            && (fields[0] == "%end" || fields[0] == "%error")
        guard isGuard else {
            block.lines.append(text)
            self.block = block
            return nil
        }
        self.block = nil
        guard block.isReply else { return nil }
        return .reply(TmuxReply(lines: block.lines, isError: fields[0] == "%error"))
    }

    /// `%output %<pane> <escaped bytes>`, or nil if the line isn't one. Matched
    /// on bytes so the payload never passes through a String.
    private func outputEvent(_ line: [UInt8]) -> TmuxEvent? {
        guard block == nil else { return nil }
        let prefix = Array("%output %".utf8)
        guard line.starts(with: prefix) else { return nil }
        // The pane id runs to the next space; the payload is everything after
        // it, which may legitimately be empty.
        guard let space = line[prefix.count...].firstIndex(of: UInt8(ascii: " ")) else {
            return nil
        }
        let pane = "%" + String(decoding: line[prefix.count..<space], as: UTF8.self)
        return .output(pane: pane,
                       bytes: TmuxControl.unescapeOutput(line[line.index(after: space)...]))
    }
}
