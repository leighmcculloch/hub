import Foundation

/// Watches a terminal's output for the two OSC sequences the UI depends on: the
/// title (OSC 0 and 2) and the shell's working directory (OSC 7).
///
/// libghostty renders the stream but doesn't hand these back to the embedding
/// app, so the bytes are read on their way to the surface. Feed every chunk, in
/// order; a sequence split across chunks is carried over to the next one.
struct TerminalOSCScanner {
    enum Event: Equatable {
        case title(String)
        case workingDirectory(String)
    }

    /// A sequence longer than this is treated as noise and abandoned, so a
    /// stream that never terminates one can't grow the buffer without bound.
    private static let maxPayloadBytes = 4096

    private enum State {
        /// Ordinary output.
        case text
        /// Saw ESC; an OSC starts if the next byte is `]`.
        case escape
        /// Inside an OSC, collecting its payload.
        case payload
        /// Saw ESC inside a payload; the sequence ends if the next byte is `\`.
        case payloadEscape
    }

    private var state: State = .text
    private var payload: [UInt8] = []

    /// Returns the events found in `data`, which is left untouched — the caller
    /// still passes the bytes on to the terminal.
    mutating func scan(_ data: Data) -> [Event] {
        var events: [Event] = []

        for byte in data {
            switch state {
            case .text:
                if byte == 0x1B { state = .escape }

            case .escape:
                if byte == 0x5D { // ']'
                    state = .payload
                    payload.removeAll(keepingCapacity: true)
                } else {
                    // Some other escape sequence. An ESC here starts a new one.
                    state = byte == 0x1B ? .escape : .text
                }

            case .payload:
                switch byte {
                case 0x07: // BEL terminator
                    if let event = Self.event(from: payload) { events.append(event) }
                    state = .text
                case 0x1B:
                    state = .payloadEscape
                default:
                    payload.append(byte)
                    if payload.count > Self.maxPayloadBytes { state = .text }
                }

            case .payloadEscape:
                if byte == 0x5C { // '\', completing the ST terminator
                    if let event = Self.event(from: payload) { events.append(event) }
                    state = .text
                } else {
                    // Malformed: an ESC mid-payload that isn't a terminator.
                    // Drop the sequence rather than guessing where it ends.
                    state = byte == 0x1B ? .escape : .text
                }
            }
        }

        return events
    }

    /// Payloads are `<code>;<value>`. Anything else is a sequence we don't use.
    private static func event(from payload: [UInt8]) -> Event? {
        let text = String(decoding: payload, as: UTF8.self)
        guard let separator = text.firstIndex(of: ";") else { return nil }
        let value = String(text[text.index(after: separator)...])

        switch text[text.startIndex..<separator] {
        case "0", "2":
            return .title(value)
        case "7":
            return .workingDirectory(value)
        default:
            return nil
        }
    }
}
