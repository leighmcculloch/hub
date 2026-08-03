/**
 * Turns the byte stream on stdin into key, mouse and paste events.
 *
 * Every event carries the raw bytes it was decoded from. That is what lets the
 * terminal pane work: anything the app doesn't claim as a shortcut is forwarded
 * to the remote pane byte for byte, so the program running there sees exactly
 * what the terminal produced — arrow keys, kitty-protocol modifiers and all.
 */

export interface KeyEvent {
  type: "key";
  /** A readable name: "a", "enter", "up", "f1", "escape", … */
  name: string;
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  bytes: Uint8Array;
}

export interface MouseEvent {
  type: "mouse";
  kind: "down" | "up" | "move" | "wheel";
  /** 0 left, 1 middle, 2 right; for a wheel, -1 up and 1 down. */
  button: number;
  /** 0-based cell coordinates. */
  x: number;
  y: number;
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  bytes: Uint8Array;
}

export interface PasteEvent {
  type: "paste";
  text: string;
  bytes: Uint8Array;
}

export interface FocusEvent {
  type: "focus";
  focused: boolean;
  bytes: Uint8Array;
}

export type InputEvent = KeyEvent | MouseEvent | PasteEvent | FocusEvent;

const PASTE_START = "\x1b[200~";
const PASTE_END = "\x1b[201~";

/** Names for the CSI final byte of the cursor and editing keys. */
const CSI_FINAL_NAMES: Record<string, string> = {
  A: "up",
  B: "down",
  C: "right",
  D: "left",
  H: "home",
  F: "end",
  E: "begin",
  Z: "backtab",
};

/** Names for `CSI <number> ~` sequences. */
const CSI_TILDE_NAMES: Record<number, string> = {
  1: "home",
  2: "insert",
  3: "delete",
  4: "end",
  5: "pageup",
  6: "pagedown",
  7: "home",
  8: "end",
  11: "f1",
  12: "f2",
  13: "f3",
  14: "f4",
  15: "f5",
  17: "f6",
  18: "f7",
  19: "f8",
  20: "f9",
  21: "f10",
  23: "f11",
  24: "f12",
};

/** Names for `SS3 <final>` — the other spelling of the function keys. */
const SS3_NAMES: Record<string, string> = {
  P: "f1",
  Q: "f2",
  R: "f3",
  S: "f4",
  A: "up",
  B: "down",
  C: "right",
  D: "left",
  H: "home",
  F: "end",
};

/**
 * Incremental decoder. Reads arrive in whatever sizes the terminal hands over,
 * which has nothing to do with where escape sequences end, so a partial
 * sequence is held until the rest of it turns up.
 */
export class InputDecoder {
  private pending = new Uint8Array(0);
  private decoder = new TextDecoder();
  private inPaste = false;
  private pasteBuffer = "";

  /** Decode everything complete in `chunk`, holding any partial tail. */
  feed(chunk: Uint8Array): InputEvent[] {
    const buffer = new Uint8Array(this.pending.length + chunk.length);
    buffer.set(this.pending);
    buffer.set(chunk, this.pending.length);
    this.pending = buffer;

    const events: InputEvent[] = [];
    while (this.pending.length > 0) {
      const consumed = this.step(events);
      if (consumed === 0) break; // incomplete sequence; wait for more bytes
      this.pending = this.pending.slice(consumed);
    }
    return events;
  }

  /**
   * Decode one event from the head of the buffer, returning how many bytes it
   * used — or 0 when the buffer holds only the start of a sequence.
   */
  private step(events: InputEvent[]): number {
    const bytes = this.pending;
    const text = this.decoder.decode(bytes, { stream: false });

    if (this.inPaste) {
      const end = text.indexOf(PASTE_END);
      if (end === -1) {
        // The terminator is six bytes and a read can land anywhere, including
        // in the middle of it. Swallowing the whole chunk would eat the half
        // that arrived and leave the other half unable to match — a paste that
        // never ends, with every keystroke after it disappearing into the
        // buffer, in this session and every other one. So keep back as much as
        // could still turn out to be the start of a terminator.
        const held = Math.min(PASTE_END.length - 1, text.length);
        const settled = text.slice(0, text.length - held);
        this.pasteBuffer += settled;
        return byteLength(settled);
      }
      this.pasteBuffer += text.slice(0, end);
      const consumed = byteLength(text.slice(0, end + PASTE_END.length));
      events.push({
        type: "paste",
        text: this.pasteBuffer,
        bytes: bytes.slice(0, consumed),
      });
      this.inPaste = false;
      this.pasteBuffer = "";
      return consumed;
    }

    if (text.startsWith(PASTE_START)) {
      this.inPaste = true;
      this.pasteBuffer = "";
      return byteLength(PASTE_START);
    }

    if (bytes[0] === 0x1b) {
      return this.escapeSequence(text, bytes, events);
    }

    return this.plainKey(text, bytes, events);
  }

  /** Anything starting with ESC: CSI, SS3, or Alt+key. */
  private escapeSequence(
    text: string,
    bytes: Uint8Array,
    events: InputEvent[],
  ): number {
    // A lone ESC is ambiguous until the next byte arrives — it could be the
    // Escape key or the start of a sequence. One read boundary is the most we
    // wait: terminals send a sequence in one write, so a solitary ESC that has
    // survived a whole read really is the key.
    if (bytes.length === 1) {
      events.push(key("escape", bytes, {}));
      return 1;
    }

    if (text[1] === "[") {
      return this.csi(text, bytes, events);
    }

    if (text[1] === "O") {
      if (bytes.length < 3) return 0;
      const name = SS3_NAMES[text[2]];
      events.push(key(name ?? text[2], bytes.slice(0, 3), {}));
      return 3;
    }

    // ESC ESC [ … : a terminal with "Alt sends Escape" turns Alt+Arrow into an
    // escape *prefixing another escape sequence*, rather than into a modified
    // CSI. Without this the inner ESC decodes as a control character — Ctrl+`{`
    // — and the arrow that follows is left to arrive as stray text.
    if (text[1] === "\x1b" && (text[2] === "[" || text[2] === "O")) {
      const inner: InputEvent[] = [];
      const consumed = this.escapeSequence(text.slice(1), bytes.slice(1), inner);
      if (consumed === 0) return 0;
      for (const event of inner) {
        events.push(
          event.type === "key"
            ? { ...event, alt: true, bytes: bytes.slice(0, consumed + 1) }
            : event,
        );
      }
      return consumed + 1;
    }

    // ESC followed by anything else is Alt+that. Decoded as its own key so the
    // app's shortcuts (all Alt-based) can claim it before the pane does.
    const rest = this.plainKeyAt(text.slice(1), bytes.slice(1));
    if (!rest) return 0;
    events.push({
      ...rest.event,
      alt: true,
      bytes: bytes.slice(0, rest.consumed + 1),
    });
    return rest.consumed + 1;
  }

  private csi(text: string, bytes: Uint8Array, events: InputEvent[]): number {
    // SGR mouse: CSI < b ; x ; y (M|m)
    if (text[2] === "<") {
      // The escape byte is what the sequence is made of; matching it is the
      // point, so the control-character rule doesn't apply here.
      // deno-lint-ignore no-control-regex
      const match = /^\x1b\[<(\d+);(\d+);(\d+)([Mm])/.exec(text);
      if (!match) return 0;
      const consumed = byteLength(match[0]);
      events.push(mouseEvent(match, bytes.slice(0, consumed)));
      return consumed;
    }

    if (text[2] === "I" || text[2] === "O") {
      events.push({
        type: "focus",
        focused: text[2] === "I",
        bytes: bytes.slice(0, 3),
      });
      return 3;
    }

    // A CSI runs until its final byte (0x40–0x7e).
    let end = 2;
    while (end < text.length) {
      const code = text.charCodeAt(end);
      if (code >= 0x40 && code <= 0x7e) break;
      end += 1;
    }
    if (end >= text.length) return 0; // still arriving
    const final = text[end];
    const params = text.slice(2, end);
    const consumed = byteLength(text.slice(0, end + 1));
    const raw = bytes.slice(0, consumed);

    // "1;5C" — the second parameter is a modifier bitmask, biased by 1.
    const fields = params.split(";");
    const modifiers = decodeModifiers(fields[1]);

    if (final === "~") {
      const name = CSI_TILDE_NAMES[Number(fields[0])];
      events.push(key(name ?? `csi${params}~`, raw, modifiers));
      return consumed;
    }
    const name = CSI_FINAL_NAMES[final];
    if (name) {
      // CSI Z is Shift+Tab however the terminal spells the modifiers.
      const shift = name === "backtab" ? true : modifiers.shift;
      events.push(key(name === "backtab" ? "tab" : name, raw, { ...modifiers, shift }));
      return consumed;
    }
    events.push(key(`csi${params}${final}`, raw, modifiers));
    return consumed;
  }

  private plainKey(text: string, bytes: Uint8Array, events: InputEvent[]): number {
    const decoded = this.plainKeyAt(text, bytes);
    if (!decoded) return 0;
    events.push(decoded.event);
    return decoded.consumed;
  }

  /** One non-escape keystroke off the front of the buffer. */
  private plainKeyAt(
    text: string,
    bytes: Uint8Array,
  ): { event: KeyEvent; consumed: number } | null {
    if (bytes.length === 0) return null;
    const byte = bytes[0];

    if (byte === 0x0d) return { event: key("enter", bytes.slice(0, 1), {}), consumed: 1 };
    if (byte === 0x0a) return { event: key("enter", bytes.slice(0, 1), {}), consumed: 1 };
    if (byte === 0x09) return { event: key("tab", bytes.slice(0, 1), {}), consumed: 1 };
    if (byte === 0x7f || byte === 0x08) {
      return { event: key("backspace", bytes.slice(0, 1), {}), consumed: 1 };
    }
    if (byte === 0x00) {
      return { event: key("space", bytes.slice(0, 1), { ctrl: true }), consumed: 1 };
    }
    if (byte < 0x20) {
      // Control characters are Ctrl+letter, in the order of the alphabet.
      const letter = String.fromCharCode(byte + 96);
      return { event: key(letter, bytes.slice(0, 1), { ctrl: true }), consumed: 1 };
    }

    // A printable character, which may be several bytes of UTF-8.
    const first = text.codePointAt(0);
    if (first === undefined) return null;
    const character = String.fromCodePoint(first);
    const consumed = byteLength(character);
    if (consumed > bytes.length) return null; // split mid-character
    return {
      event: key(character === " " ? "space" : character, bytes.slice(0, consumed), {}),
      consumed,
    };
  }
}

function key(
  name: string,
  bytes: Uint8Array,
  modifiers: { ctrl?: boolean; alt?: boolean; shift?: boolean },
): KeyEvent {
  return {
    type: "key",
    name,
    ctrl: modifiers.ctrl ?? false,
    alt: modifiers.alt ?? false,
    shift: modifiers.shift ?? false,
    bytes,
  };
}

/** xterm's modifier parameter: a bitmask of shift/alt/ctrl, biased by 1. */
function decodeModifiers(field: string | undefined): {
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
} {
  const value = Number(field ?? "1");
  const mask = Number.isFinite(value) && value > 0 ? value - 1 : 0;
  return {
    shift: (mask & 1) !== 0,
    alt: (mask & 2) !== 0,
    ctrl: (mask & 4) !== 0,
  };
}

/**
 * `CSI < button ; col ; row M|m` into an event.
 *
 * The button field packs the modifiers and the motion/wheel flags alongside the
 * button number, and coordinates are 1-based on the wire.
 */
function mouseEvent(match: RegExpExecArray, bytes: Uint8Array): MouseEvent {
  const code = Number(match[1]);
  const x = Number(match[2]) - 1;
  const y = Number(match[3]) - 1;
  const released = match[4] === "m";

  const shift = (code & 4) !== 0;
  const alt = (code & 8) !== 0;
  const ctrl = (code & 16) !== 0;
  const motion = (code & 32) !== 0;
  const wheel = (code & 64) !== 0;
  const button = code & 3;

  if (wheel) {
    return {
      type: "mouse",
      kind: "wheel",
      button: button === 0 ? -1 : 1,
      x,
      y,
      ctrl,
      alt,
      shift,
      bytes,
    };
  }
  // Button 3 with the motion flag is the pointer moving with nothing held.
  const kind = released ? "up" : motion ? "move" : "down";
  return {
    type: "mouse",
    kind,
    button: button === 3 ? -1 : button,
    x,
    y,
    ctrl,
    alt,
    shift,
    bytes,
  };
}

const encoder = new TextEncoder();

function byteLength(text: string): number {
  return encoder.encode(text).length;
}
