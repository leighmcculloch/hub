/**
 * The tmux control-mode protocol (`tmux -C`): parsing what tmux writes on
 * stdout, and building the commands written back to its stdin.
 *
 * Pure byte and text handling — the process and the I/O belong to
 * `tmux/client.ts`, and what the events *mean* is the session's business.
 */

/**
 * One pane of the tmux session, as reported by `list-panes`. The app shows one
 * terminal tab per pane, so this is what a tab is built from.
 */
export interface TmuxPane {
  /** tmux's own pane id, e.g. `%3`. Stable for the pane's whole life. */
  id: string;
  /** The window the pane belongs to, e.g. `@1`. */
  windowID: string;
  windowIndex: number;
  windowName: string;
  /** How many panes that window has; a split window needs its tabs told apart. */
  panesInWindow: number;
  /** Pane index within its window. */
  index: number;
  /**
   * True only for the pane tmux has focused at the session level: the active
   * pane of the session's active window. (`pane_active` alone is per-window.)
   */
  isActive: boolean;
  cursorX: number;
  cursorY: number;
  /** The pane's working directory — tmux swallows OSC 7, so this is the only way. */
  currentPath: string;
}

/** The tab label: the window name, plus the pane index when the window is split. */
export function paneTitle(pane: TmuxPane): string {
  return pane.panesInWindow > 1 ? `${pane.windowName}:${pane.index}` : pane.windowName;
}

/**
 * The reply to one command sent to tmux. Which command it answers is not on the
 * wire: replies come back in the order the commands were sent, so the caller
 * pairs them against its own queue of sent commands.
 */
export interface TmuxReply {
  lines: string[];
  /** True when tmux closed the block with `%error` instead of `%end`. */
  isError: boolean;
}

/** Something tmux reported on its control stream. */
export type TmuxEvent =
  /** Bytes a pane wrote, already unescaped. */
  | { type: "output"; pane: string; bytes: Uint8Array }
  /**
   * Windows or panes were added, closed, renamed or relaid out. Every such
   * notification collapses to this: the client answers all of them the same
   * way, by re-listing the panes.
   */
  | { type: "paneListChanged" }
  /** A command's reply, in the order the commands were sent. */
  | { type: "reply"; reply: TmuxReply }
  /** tmux is finished with us — the session was killed or the server exited. */
  | { type: "exit"; reason: string | null };

/**
 * Bytes per `send-keys`. Keystrokes are one or two bytes, but a paste is
 * arbitrarily large and each byte costs three characters on the wire, so it is
 * split rather than written as one enormous command line.
 */
export const SEND_KEYS_CHUNK = 512;

/**
 * What each `list-panes` row contains. The two free-text fields come last so a
 * `|` inside a window name can't be mistaken for a separator.
 *
 * `window_active` is needed alongside `pane_active` because `pane_active` is
 * per-window — every window's active pane is `1`, not just the session's. With
 * `list-panes -s` that would make the active pane of the lowest-index window
 * look like the session's focus, so a newly opened window (which tmux makes
 * current but appends at a higher index) would never be recognised as the focus
 * change it is.
 */
export const PANE_FORMAT = "#{window_id}|#{window_index}|#{window_panes}" +
  "|#{window_active}" +
  "|#{pane_id}|#{pane_index}|#{pane_active}|#{cursor_x}|#{cursor_y}" +
  "|#{window_name}|#{pane_current_path}";

/**
 * Every pane of every window in the attached session. `-s` scopes it to the
 * session (not just the current window) without dragging in other sessions the
 * way `-a` would.
 */
export function listPanesCommand(): string {
  return `list-panes -s -F "${PANE_FORMAT}"`;
}

/**
 * Parse a `list-panes` reply. Rows that don't have every field are skipped
 * rather than guessed at.
 *
 * Only the *first* nine fields are positional. A window name can contain the
 * separator (tmux allows any name), so the trailing path is taken from the end
 * and whatever lies between is the name — that way a stray `|` mangles one
 * label instead of dropping the pane from the tab bar.
 */
export function parsePanes(lines: string[]): TmuxPane[] {
  const panes: TmuxPane[] = [];
  for (const line of lines) {
    const fields = line.split("|");
    if (fields.length < 11) continue;
    const windowIndex = integer(fields[1]);
    const panesInWindow = integer(fields[2]);
    const index = integer(fields[5]);
    const cursorX = integer(fields[7]);
    const cursorY = integer(fields[8]);
    if (
      windowIndex === null || panesInWindow === null || index === null ||
      cursorX === null || cursorY === null
    ) {
      continue;
    }
    panes.push({
      id: fields[4],
      windowID: fields[0],
      windowIndex,
      windowName: fields.slice(9, fields.length - 1).join("|"),
      panesInWindow,
      index,
      // `pane_active` is per-window, so only a pane that is both its window's
      // active pane and in the session's active window is the one tmux focused.
      isActive: fields[3] === "1" && fields[6] === "1",
      cursorX,
      cursorY,
      currentPath: fields[fields.length - 1],
    });
  }
  return panes;
}

function integer(text: string): number | null {
  if (!/^-?\d+$/.test(text)) return null;
  return Number(text);
}

/**
 * Keystrokes for a pane. `-H` takes one byte per argument and sends it through
 * untranslated, so the pane's program sees exactly what the terminal produced —
 * including UTF-8, which would otherwise be re-encoded as if each byte were a
 * character.
 */
export function sendKeysCommands(pane: string, bytes: Uint8Array): string[] {
  const commands: string[] = [];
  for (let start = 0; start < bytes.length; start += SEND_KEYS_CHUNK) {
    const chunk = bytes.subarray(start, Math.min(start + SEND_KEYS_CHUNK, bytes.length));
    const hex = Array.from(chunk, (byte) => byte.toString(16).padStart(2, "0")).join(" ");
    commands.push(`send-keys -t ${pane} -H ${hex}`);
  }
  return commands;
}

/**
 * Tell tmux how big this client is; it resizes the session's windows to match.
 * Control clients start with no size at all, so this has to be sent before
 * anything renders sensibly.
 *
 * The `width,height` spelling is used rather than `widthxheight` because tmux
 * has accepted it for far longer.
 */
export function refreshClientCommand(cols: number, rows: number): string {
  return `refresh-client -C ${Math.max(1, cols)},${Math.max(1, rows)}`;
}

export function newWindowCommand(): string {
  return "new-window";
}

export function killPaneCommand(pane: string): string {
  return `kill-pane -t ${pane}`;
}

/**
 * Follow the tab selection in tmux itself, so another attached client — and
 * anything that acts on the "current" pane — agrees with what's on screen.
 */
export function selectPaneCommands(window: string, pane: string): string[] {
  return [`select-window -t ${window}`, `select-pane -t ${pane}`];
}

/**
 * The pane's visible screen, with its colours (`-e`). This is how the middle
 * pane is drawn: tmux keeps the screen state, so the app renders what tmux says
 * is on it rather than emulating a terminal of its own.
 */
export function capturePaneCommand(pane: string): string {
  return `capture-pane -p -e -t ${pane}`;
}

/**
 * Where tmux has the pane's cursor. Asked alongside each capture, because the
 * cursor moves on every keystroke while the pane list only changes when windows
 * do.
 */
export function cursorCommand(pane: string): string {
  return `display-message -p -t ${pane} "#{cursor_x},#{cursor_y},#{?cursor_flag,1,0}"`;
}

/** Parse `cursorCommand`'s reply. */
export function parseCursor(lines: string[]): { x: number; y: number; visible: boolean } | null {
  const fields = (lines[0] ?? "").trim().split(",");
  if (fields.length < 2) return null;
  const x = integer(fields[0]);
  const y = integer(fields[1]);
  if (x === null || y === null) return null;
  return { x, y, visible: fields[2] !== "0" };
}

/**
 * tmux escapes `\` and every byte below a space as a three-digit octal sequence
 * in `%output`, and passes everything else — including raw UTF-8 — through
 * untouched. So this has to work on bytes: decoding the line as text first
 * would replace any byte sequence that isn't valid UTF-8.
 */
export function unescapeOutput(bytes: Uint8Array): Uint8Array {
  const result = new Uint8Array(bytes.length);
  let length = 0;
  let index = 0;
  const BACKSLASH = 0x5c;
  while (index < bytes.length) {
    if (bytes[index] === BACKSLASH && index + 3 < bytes.length) {
      const value = octalValue(bytes[index + 1], bytes[index + 2], bytes[index + 3]);
      if (value !== null) {
        result[length++] = value;
        index += 4;
        continue;
      }
    }
    result[length++] = bytes[index];
    index += 1;
  }
  return result.subarray(0, length);
}

/**
 * Three octal digits as a byte, or null if they aren't three octal digits. A
 * lone backslash is then kept literally rather than eating what follows.
 */
function octalValue(a: number, b: number, c: number): number | null {
  const ZERO = 0x30;
  const SEVEN = 0x37;
  for (const digit of [a, b, c]) {
    if (digit < ZERO || digit > SEVEN) return null;
  }
  const value = ((a - ZERO) * 8 + (b - ZERO)) * 8 + (c - ZERO);
  return value <= 0xff ? value : null;
}

/**
 * Splits a stream of bytes into protocol lines.
 *
 * Reads arrive in whatever sizes the pipe hands over, which has nothing to do
 * with where tmux's lines end: one read can hold a hundred notifications and
 * half of the next.
 */
export class TmuxLineBuffer {
  private pending = new Uint8Array(0);

  /** The complete lines in `data`, with anything left over held for next time. */
  lines(data: Uint8Array): Uint8Array[] {
    const buffer = new Uint8Array(this.pending.length + data.length);
    buffer.set(this.pending);
    buffer.set(data, this.pending.length);

    const lines: Uint8Array[] = [];
    let start = 0;
    for (let index = 0; index < buffer.length; index += 1) {
      if (buffer[index] !== 0x0a) continue;
      let end = index;
      // tmux escapes its own carriage returns, so a bare one here is only ever
      // a line terminator that came through as CRLF.
      if (end > start && buffer[end - 1] === 0x0d) end -= 1;
      lines.push(buffer.slice(start, end));
      start = index + 1;
    }
    this.pending = buffer.slice(start);
    return lines;
  }
}

const decoder = new TextDecoder();
const OUTPUT_PREFIX = new TextEncoder().encode("%output %");

/**
 * Turns tmux's control stream, line by line, into events.
 *
 * tmux writes two kinds of line: notifications starting with `%`, and command
 * replies wrapped in a `%begin`/`%end` (or `%error`) block. Reply blocks arrive
 * in the order the commands were sent, which is what lets the client pair them
 * up without any identifier of its own.
 */
export class TmuxControlParser {
  private block: { number: string; isReply: boolean; lines: string[] } | null = null;

  /** Feed one line, without its terminator. Returns an event when one completes. */
  consume(line: Uint8Array): TmuxEvent | null {
    // Only %output can carry bytes that aren't text, and it is the hot path
    // besides, so it is matched before the line is decoded.
    const output = this.outputEvent(line);
    if (output) return output;

    const text = decoder.decode(line);

    if (this.block !== null) return this.consumeInBlock(text);
    if (!text.startsWith("%")) return null;

    const fields = text.split(" ");
    switch (fields[0]) {
      case "%begin":
        // %begin <time> <number> <flags>
        this.block = {
          number: fields.length > 2 ? fields[2] : "",
          // tmux sets the guard's flag when the command came from *this*
          // client. A block without it is one tmux ran for its own reasons (the
          // initial attach, another client's command) and has no command of
          // ours to pair with, so it is dropped rather than shifting every
          // later reply by one.
          isReply: fields.length > 3 && fields[3] !== "0",
          lines: [],
        };
        return null;
      case "%exit": {
        const reason = text.slice("%exit".length).trim();
        return { type: "exit", reason: reason || null };
      }
      case "%window-add":
      case "%window-close":
      case "%unlinked-window-close":
      case "%window-renamed":
      case "%window-pane-changed":
      case "%layout-change":
      case "%session-window-changed":
      case "%session-changed":
        return { type: "paneListChanged" };
      default:
        return null;
    }
  }

  /**
   * A line inside a `%begin` block: either the guard that closes it, or one more
   * line of the command's output.
   */
  private consumeInBlock(text: string): TmuxEvent | null {
    const block = this.block;
    if (block === null) return null;
    const fields = text.split(" ");
    // The number is checked so a captured screen containing a line that looks
    // like `%end` doesn't end the block early — block contents aren't escaped.
    const isGuard = fields.length > 2 && fields[2] === block.number &&
      (fields[0] === "%end" || fields[0] === "%error");
    if (!isGuard) {
      block.lines.push(text);
      return null;
    }
    this.block = null;
    if (!block.isReply) return null;
    return { type: "reply", reply: { lines: block.lines, isError: fields[0] === "%error" } };
  }

  /**
   * `%output %<pane> <escaped bytes>`, or null if the line isn't one. Matched on
   * bytes so the payload never passes through a string.
   */
  private outputEvent(line: Uint8Array): TmuxEvent | null {
    if (this.block !== null) return null;
    if (line.length < OUTPUT_PREFIX.length) return null;
    for (let index = 0; index < OUTPUT_PREFIX.length; index += 1) {
      if (line[index] !== OUTPUT_PREFIX[index]) return null;
    }
    // The pane id runs to the next space; the payload is everything after it,
    // which may legitimately be empty.
    let space = -1;
    for (let index = OUTPUT_PREFIX.length; index < line.length; index += 1) {
      if (line[index] === 0x20) {
        space = index;
        break;
      }
    }
    if (space === -1) return null;
    const pane = `%${decoder.decode(line.subarray(OUTPUT_PREFIX.length, space))}`;
    return { type: "output", pane, bytes: unescapeOutput(line.subarray(space + 1)) };
  }
}
