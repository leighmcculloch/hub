/**
 * ANSI escape sequences, and the width arithmetic every layout in this app
 * depends on.
 *
 * The renderer composes each screen row from pane-sized strings that may
 * already carry styling — the middle pane's content comes straight out of
 * `tmux capture-pane -e`, colours and all — so slicing and padding have to
 * count *cells*, not code units, and must never cut an escape sequence in half.
 */

export const ESC = "\x1b";
export const CSI = `${ESC}[`;

// MARK: - Screen and cursor control

export const enterAltScreen = `${CSI}?1049h`;
export const leaveAltScreen = `${CSI}?1049l`;
export const hideCursor = `${CSI}?25l`;
export const showCursor = `${CSI}?25h`;
export const clearScreen = `${CSI}2J${CSI}H`;
export const resetStyle = `${CSI}0m`;

/** 1-based cursor position, the way terminals count. */
export function cursorTo(x: number, y: number): string {
  return `${CSI}${y + 1};${x + 1}H`;
}

// MARK: - Mouse

/**
 * Mouse reporting: button events (1000), drag tracking (1002), any-motion
 * (1003) so rows can highlight under the pointer, and SGR extended coordinates
 * (1006) so columns past 223 still report correctly — the plain encoding packs
 * a coordinate into one byte and simply gives up on a wide window.
 */
export const enableMouse = `${CSI}?1000h${CSI}?1002h${CSI}?1003h${CSI}?1006h`;
export const disableMouse = `${CSI}?1006l${CSI}?1003l${CSI}?1002l${CSI}?1000l`;

/** Pasted text arrives wrapped in markers, so it isn't read as keystrokes. */
export const enableBracketedPaste = `${CSI}?2004h`;
export const disableBracketedPaste = `${CSI}?2004l`;

/**
 * OSC 52: hand text to the *terminal's* clipboard rather than the machine this
 * process runs on. That is the whole point here — hub is routinely run over SSH
 * or inside another multiplexer, and the clipboard worth reaching is the one on
 * the keyboard in front of you.
 *
 * Terminals cap the sequence's length; anything longer is dropped silently, so
 * callers truncate rather than send something the terminal will discard.
 */
export function setClipboard(base64: string): string {
  return `${ESC}]52;c;${base64}\x07`;
}

/** Ask the terminal to keep reporting focus, so a blurred app can dim. */
export const enableFocusReporting = `${CSI}?1004h`;
export const disableFocusReporting = `${CSI}?1004l`;

// MARK: - Styling

export interface Style {
  fg?: string;
  bg?: string;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  underline?: boolean;
  reverse?: boolean;
}

/** The 256-colour palette entries this app draws with. */
export const Color = {
  fg: "15",
  dim: "244",
  dimmer: "240",
  accent: "39",
  green: "35",
  red: "167",
  orange: "179",
  yellow: "185",
  purple: "140",
  blue: "75",
  panel: "235",
  panelAlt: "236",
  /** A selected row in the pane that has the keyboard. */
  selection: "24",
  /** The same row in a pane that doesn't — dimmer, so focus is legible. */
  selectionDim: "23",
  /** A selected row under the pointer. Distinct from both of the above, or
   * hovering something already selected would look like nothing happened. */
  selectionHover: "25",
  /** Anything interactive under the pointer. */
  hover: "237",
  border: "238",
  black: "232",
} as const;

export function sgr(style: Style): string {
  const codes: string[] = [];
  if (style.bold) codes.push("1");
  if (style.dim) codes.push("2");
  if (style.italic) codes.push("3");
  if (style.underline) codes.push("4");
  if (style.reverse) codes.push("7");
  if (style.fg) codes.push(`38;5;${style.fg}`);
  if (style.bg) codes.push(`48;5;${style.bg}`);
  return codes.length ? `${CSI}${codes.join(";")}m` : "";
}

/** Wrap `text` in `style`, resetting afterwards so it can't leak rightwards. */
export function styled(text: string, style: Style): string {
  const prefix = sgr(style);
  return prefix ? `${prefix}${text}${resetStyle}` : text;
}

// MARK: - Width

/**
 * How many terminal cells one code point occupies.
 *
 * A deliberately small table rather than a full Unicode database: the ranges
 * below cover the wide and zero-width characters that actually turn up in
 * repository paths, commit subjects and terminal output, and getting one exotic
 * script wrong costs a column of padding rather than a broken frame.
 */
export function charWidth(codePoint: number): number {
  if (codePoint === 0) return 0;
  if (codePoint < 32 || (codePoint >= 0x7f && codePoint < 0xa0)) return 0;
  // Combining marks and variation selectors sit on the previous cell.
  if (
    (codePoint >= 0x0300 && codePoint <= 0x036f) ||
    (codePoint >= 0x200b && codePoint <= 0x200f) ||
    (codePoint >= 0xfe00 && codePoint <= 0xfe0f) ||
    (codePoint >= 0xfe20 && codePoint <= 0xfe2f) ||
    codePoint === 0xfeff
  ) {
    return 0;
  }
  if (
    (codePoint >= 0x1100 && codePoint <= 0x115f) || // Hangul Jamo
    (codePoint >= 0x2e80 && codePoint <= 0x303e) || // CJK radicals, Kangxi
    (codePoint >= 0x3041 && codePoint <= 0x33ff) || // Kana, CJK compatibility
    (codePoint >= 0x3400 && codePoint <= 0x4dbf) ||
    (codePoint >= 0x4e00 && codePoint <= 0x9fff) || // CJK unified
    (codePoint >= 0xa000 && codePoint <= 0xa4cf) || // Yi
    (codePoint >= 0xac00 && codePoint <= 0xd7a3) || // Hangul syllables
    (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
    (codePoint >= 0xfe30 && codePoint <= 0xfe6f) ||
    (codePoint >= 0xff00 && codePoint <= 0xff60) || // Fullwidth forms
    (codePoint >= 0xffe0 && codePoint <= 0xffe6) ||
    (codePoint >= 0x1f300 && codePoint <= 0x1f64f) || // Emoji
    (codePoint >= 0x1f900 && codePoint <= 0x1f9ff) ||
    (codePoint >= 0x20000 && codePoint <= 0x3fffd)
  ) {
    return 2;
  }
  return 1;
}

/** Where an escape sequence starting at `index` ends (exclusive). */
function escapeEnd(text: string, index: number): number {
  const next = text[index + 1];
  if (next === "[") {
    // CSI: parameter and intermediate bytes, then one final byte.
    let cursor = index + 2;
    while (cursor < text.length) {
      const code = text.charCodeAt(cursor);
      if (code >= 0x40 && code <= 0x7e) return cursor + 1;
      cursor += 1;
    }
    return text.length;
  }
  if (next === "]") {
    // OSC: runs to BEL or ST.
    let cursor = index + 2;
    while (cursor < text.length) {
      if (text[cursor] === "\x07") return cursor + 1;
      if (text[cursor] === ESC && text[cursor + 1] === "\\") return cursor + 2;
      cursor += 1;
    }
    return text.length;
  }
  return Math.min(index + 2, text.length);
}

/** Visible width of `text`, ignoring any escape sequences in it. */
export function displayWidth(text: string): number {
  let width = 0;
  let index = 0;
  while (index < text.length) {
    if (text[index] === ESC) {
      index = escapeEnd(text, index);
      continue;
    }
    const codePoint = text.codePointAt(index)!;
    width += charWidth(codePoint);
    index += codePoint > 0xffff ? 2 : 1;
  }
  return width;
}

/** Everything in `text` with the escape sequences taken out. */
export function stripAnsi(text: string): string {
  let out = "";
  let index = 0;
  while (index < text.length) {
    if (text[index] === ESC) {
      index = escapeEnd(text, index);
      continue;
    }
    out += text[index];
    index += 1;
  }
  return out;
}

/**
 * The first `width` cells of `text`, keeping every escape sequence that leads
 * up to them so styling still applies to what survives.
 *
 * A double-width character straddling the boundary is replaced by a space:
 * emitting half of it would leave the rest of the row a cell out of step.
 */
export function truncate(text: string, width: number): string {
  if (width <= 0) return "";
  let out = "";
  let used = 0;
  let index = 0;
  while (index < text.length) {
    if (text[index] === ESC) {
      const end = escapeEnd(text, index);
      out += text.slice(index, end);
      index = end;
      continue;
    }
    const codePoint = text.codePointAt(index)!;
    const size = codePoint > 0xffff ? 2 : 1;
    const cells = charWidth(codePoint);
    if (used + cells > width) {
      if (cells > 1 && used < width) out += " ";
      break;
    }
    out += text.slice(index, index + size);
    used += cells;
    index += size;
  }
  return out;
}

/**
 * `text` clipped and padded to exactly `width` cells.
 *
 * The renderer writes whole rows and never clears to end of line, so every
 * segment has to occupy exactly the space the layout gave it — that is what
 * stops a shrinking pane from leaving the last frame's pixels behind.
 */
export function fit(text: string, width: number, style?: Style): string {
  if (width <= 0) return "";
  const clipped = truncate(text, width);
  const padding = width - displayWidth(clipped);
  const body = padding > 0 ? clipped + " ".repeat(padding) : clipped;
  // The reset goes last so a sequence left open inside `text` — capture-pane
  // output routinely ends mid-colour — can't bleed into the next segment.
  return style ? `${sgr(style)}${body}${resetStyle}` : `${body}${resetStyle}`;
}

/** `text` centred in `width` cells. */
export function center(text: string, width: number, style?: Style): string {
  const visible = displayWidth(text);
  if (visible >= width) return fit(text, width, style);
  const left = Math.floor((width - visible) / 2);
  return fit(" ".repeat(left) + text, width, style);
}

/** Middle-elided `text`, for names that are long but identified at both ends. */
export function elideMiddle(text: string, width: number): string {
  if (width <= 0) return "";
  if (displayWidth(text) <= width) return text;
  if (width <= 1) return "…";
  const keep = width - 1;
  const head = Math.ceil(keep / 2);
  const tail = keep - head;
  return `${truncate(text, head)}…${tailCells(text, tail)}`;
}

/** Head-elided `text`, for paths whose last components identify them. */
export function elideHead(text: string, width: number): string {
  if (width <= 0) return "";
  if (displayWidth(text) <= width) return text;
  if (width <= 1) return "…";
  return `…${tailCells(text, width - 1)}`;
}

/**
 * `text` with its first `count` cells removed, re-opening any styling that was
 * in force at the cut so the remainder still renders as it did.
 */
export function dropCells(text: string, count: number): string {
  if (count <= 0) return text;
  let skipped = 0;
  let index = 0;
  let carried = "";
  while (index < text.length && skipped < count) {
    if (text[index] === ESC) {
      const end = escapeEnd(text, index);
      carried += text.slice(index, end);
      index = end;
      continue;
    }
    const codePoint = text.codePointAt(index)!;
    const size = codePoint > 0xffff ? 2 : 1;
    skipped += charWidth(codePoint);
    index += size;
  }
  // Overshooting means a double-width character straddled the cut; a space
  // stands in for its second half so the columns after it stay aligned.
  const lead = skipped > count ? " " : "";
  return carried + lead + text.slice(index);
}

/**
 * `row` with `replacement` written over it starting at cell `x`.
 *
 * Used to lay modal panels over the composed frame without re-rendering what is
 * behind them.
 */
export function overlay(row: string, x: number, replacement: string, total: number): string {
  const head = fit(truncate(row, x), x);
  const width = displayWidth(replacement);
  const tailStart = x + width;
  const tail = tailStart >= total ? "" : dropCells(row, tailStart);
  return `${head}${replacement}${fit(tail, Math.max(0, total - tailStart))}`;
}

/** The last `width` cells of `text`. */
function tailCells(text: string, width: number): string {
  if (width <= 0) return "";
  const chars = [...text];
  let used = 0;
  let start = chars.length;
  while (start > 0) {
    const cells = charWidth(chars[start - 1].codePointAt(0)!);
    if (used + cells > width) break;
    used += cells;
    start -= 1;
  }
  return chars.slice(start).join("");
}
