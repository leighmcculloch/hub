/**
 * The frame buffer: a list of composed rows, diffed against the previous frame
 * so a redraw only writes the lines that actually changed.
 *
 * Rows rather than cells because the middle pane's content arrives as strings
 * that already carry their own styling (`tmux capture-pane -e`). Re-parsing
 * those into cells only to serialise them again would cost more than it saves,
 * and every row here is already padded to the terminal's exact width, so a
 * changed row can be overwritten without clearing first.
 */

import {
  cursorTo,
  disableBracketedPaste,
  disableFocusReporting,
  disableMouse,
  enableBracketedPaste,
  enableFocusReporting,
  enableMouse,
  enterAltScreen,
  hideCursor,
  leaveAltScreen,
  resetStyle,
  showCursor,
} from "./ansi.ts";

export interface CursorState {
  x: number;
  y: number;
  visible: boolean;
}

export class Screen {
  cols: number;
  rows: number;

  private previous: string[] = [];
  private encoder = new TextEncoder();
  private started = false;

  constructor() {
    const size = safeConsoleSize();
    this.cols = size.columns;
    this.rows = size.rows;
  }

  /** Take over the terminal: alt screen, raw input, mouse reporting. */
  start(): void {
    if (this.started) return;
    this.started = true;
    try {
      Deno.stdin.setRaw(true);
    } catch {
      // Not a TTY (a pipe, a test). Rendering still works; input won't.
    }
    this.write(
      enterAltScreen + hideCursor + enableMouse + enableBracketedPaste +
        enableFocusReporting,
    );
    this.previous = [];
  }

  /** Give the terminal back, in the reverse order it was taken. */
  stop(): void {
    if (!this.started) return;
    this.started = false;
    this.write(
      disableFocusReporting + disableBracketedPaste + disableMouse + showCursor +
        resetStyle + leaveAltScreen,
    );
    try {
      Deno.stdin.setRaw(false);
    } catch {
      // Same as start(): nothing to restore when there was no TTY.
    }
  }

  /** Re-read the terminal size. Returns whether it changed. */
  measure(): boolean {
    const size = safeConsoleSize();
    if (size.columns === this.cols && size.rows === this.rows) return false;
    this.cols = size.columns;
    this.rows = size.rows;
    // The whole screen is suspect after a resize: the terminal has reflowed
    // whatever was there, so nothing on it can be trusted as unchanged.
    this.previous = [];
    return true;
  }

  /**
   * Draw one frame. `rows` must each be exactly `cols` cells wide — the
   * layout's job — and there must be at most `this.rows` of them.
   */
  render(rows: string[], cursor: CursorState): void {
    let out = hideCursor;
    for (let y = 0; y < this.rows; y += 1) {
      const line = rows[y] ?? "";
      if (this.previous[y] === line) continue;
      out += cursorTo(0, y) + line;
      this.previous[y] = line;
    }
    if (cursor.visible) {
      out += cursorTo(cursor.x, cursor.y) + showCursor;
    }
    this.write(out);
  }

  /** Force the next `render` to repaint every row. */
  invalidate(): void {
    this.previous = [];
  }

  private write(text: string): void {
    if (!text) return;
    const bytes = this.encoder.encode(text);
    let written = 0;
    while (written < bytes.length) {
      try {
        written += Deno.stdout.writeSync(bytes.subarray(written));
      } catch {
        // A closed stdout means the terminal went away; there is nothing left
        // to draw on and nothing useful to report.
        return;
      }
    }
  }
}

/**
 * The terminal's size, with a usable fallback.
 *
 * `consoleSize` throws when stdout isn't a terminal, which happens whenever
 * output is piped — including in tests — and an 80×24 frame is a better answer
 * there than a crash.
 */
function safeConsoleSize(): { columns: number; rows: number } {
  try {
    const size = Deno.consoleSize();
    return {
      columns: Math.max(20, size.columns),
      rows: Math.max(6, size.rows),
    };
  } catch {
    return { columns: 80, rows: 24 };
  }
}
