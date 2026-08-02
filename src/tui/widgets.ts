/**
 * The small pieces every pane is built from: hit regions for the mouse, scroll
 * arithmetic, boxes, and an editable text field.
 *
 * Everything here renders to an array of strings, each exactly the width it was
 * asked for, which is the contract the frame compositor relies on.
 */

import { Color, displayWidth, elideHead, fit, resetStyle, sgr, Style, styled } from "./ansi.ts";

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export function contains(rect: Rect, x: number, y: number): boolean {
  return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
}

/**
 * Where each clickable thing ended up in the last frame.
 *
 * Panes register regions as they render, so hit testing follows the layout
 * automatically instead of being re-derived — and re-derived slightly
 * differently — from geometry in the click handler.
 */
export class HitMap {
  private regions: Array<{ rect: Rect; id: string; data?: unknown }> = [];

  clear(): void {
    this.regions = [];
  }

  add(rect: Rect, id: string, data?: unknown): void {
    this.regions.push({ rect, id, data });
  }

  /**
   * The thing at these coordinates. Later registrations win, so a modal drawn
   * over a pane takes the click rather than what is behind it.
   */
  hit(x: number, y: number): { id: string; rect: Rect; data?: unknown } | null {
    for (let index = this.regions.length - 1; index >= 0; index -= 1) {
      const region = this.regions[index];
      if (contains(region.rect, x, y)) return region;
    }
    return null;
  }
}

// MARK: - Scrolling

/**
 * A scroll offset that keeps `selected` on screen and never runs past the end
 * of the content. Returns the offset to render from.
 */
export function scrollToShow(
  offset: number,
  selected: number,
  visible: number,
  total: number,
): number {
  if (visible <= 0 || total <= 0) return 0;
  const maximum = Math.max(0, total - visible);
  let next = Math.min(Math.max(0, offset), maximum);
  if (selected >= 0) {
    if (selected < next) next = selected;
    else if (selected >= next + visible) next = selected - visible + 1;
  }
  return Math.min(Math.max(0, next), maximum);
}

/**
 * A one-column scrollbar for a list, as a per-row array of glyphs.
 *
 * Empty strings where the bar isn't drawn, so the caller can lay it out without
 * a special case for "no scrolling needed".
 */
export function scrollbar(offset: number, visible: number, total: number): string[] {
  if (total <= visible || visible <= 0) return new Array(Math.max(0, visible)).fill(" ");
  const thumb = Math.max(1, Math.round((visible * visible) / total));
  const span = visible - thumb;
  const maximum = Math.max(1, total - visible);
  const start = Math.round((offset / maximum) * span);
  return Array.from({ length: visible }, (_, index) => {
    const inThumb = index >= start && index < start + thumb;
    return styled(inThumb ? "▐" : "│", { fg: inThumb ? Color.dim : Color.border });
  });
}

// MARK: - Boxes

const BOX = {
  topLeft: "╭",
  topRight: "╮",
  bottomLeft: "╰",
  bottomRight: "╯",
  horizontal: "─",
  vertical: "│",
};

/**
 * A rounded panel with an optional title, `height` lines tall and `width` wide.
 * `body` is drawn inside the border, clipped to fit.
 */
export function panel(
  width: number,
  height: number,
  title: string,
  body: string[],
  style: Style = {},
): string[] {
  if (width < 2 || height < 2) return new Array(Math.max(0, height)).fill(fit("", width, style));
  const inner = width - 2;
  const border = sgr({ ...style, fg: Color.border });
  const lines: string[] = [];

  const heading = title ? ` ${title} ` : "";
  const headingWidth = Math.min(displayWidth(heading), Math.max(0, inner - 2));
  const rule = BOX.horizontal.repeat(Math.max(0, inner - headingWidth));
  lines.push(
    fit(
      `${border}${BOX.topLeft}${resetStyle}${styled(heading, { ...style, bold: true })}` +
        `${border}${rule}${BOX.topRight}${resetStyle}`,
      width,
      style,
    ),
  );

  for (let row = 0; row < height - 2; row += 1) {
    const content = body[row] ?? "";
    lines.push(
      fit(
        `${border}${BOX.vertical}${resetStyle}${fit(content, inner, style)}` +
          `${border}${BOX.vertical}${resetStyle}`,
        width,
        style,
      ),
    );
  }

  lines.push(
    fit(
      `${border}${BOX.bottomLeft}${BOX.horizontal.repeat(inner)}${BOX.bottomRight}${resetStyle}`,
      width,
      style,
    ),
  );
  return lines;
}

/** A full-width horizontal rule, for separating stacked sections. */
export function rule(width: number, style: Style = {}): string {
  return fit(
    styled(BOX.horizontal.repeat(Math.max(0, width)), { ...style, fg: Color.border }),
    width,
    style,
  );
}

/** A section heading: small, dim, uppercase. */
export function sectionHeader(title: string, width: number, trailing = ""): string {
  const left = styled(` ${title.toUpperCase()}`, { fg: Color.dimmer, bold: true });
  const right = trailing ? styled(`${trailing} `, { fg: Color.dimmer }) : "";
  const gap = Math.max(0, width - displayWidth(left) - displayWidth(right));
  return fit(`${left}${" ".repeat(gap)}${right}`, width);
}

/**
 * The background a pane's title bar carries. Lit while that pane has the
 * keyboard — see `paneHeader` for why the title bar is where focus is shown.
 */
export function headerBackground(focused: boolean): string {
  return focused ? Color.paneFocus : Color.panelAlt;
}

/**
 * A pane's title bar, and the one place the app says which pane has the
 * keyboard: the focused pane's bar lifts onto a brighter background and grows
 * an accent edge, in every pane, at the same place — the top row.
 *
 * Focus deliberately isn't painted across a pane's body. The terminal pane's
 * body is tmux's own rendering and can't be re-tinted without corrupting it, so
 * a body tint could never mean the same thing in all three panes; one row that
 * every pane has means exactly one thing everywhere.
 *
 * `content` is styled by the caller on `headerBackground(focused)`, since what
 * goes in the bar differs per pane — a name here, a strip of tabs there.
 */
export function paneHeader(width: number, content: string, focused: boolean): string {
  const bg = headerBackground(focused);
  const edge = focused ? styled("▎", { fg: Color.accent, bg }) : fit(" ", 1, { bg });
  return fit(`${edge}${fit(content, Math.max(0, width - 1), { bg })}`, width, { bg });
}

/**
 * The edge marker for a section inside a pane: filled while the keyboard is on
 * it. The same glyph the pane header uses, so "the keyboard is here" reads the
 * same whether it is a whole pane or one section of one.
 */
export function focusEdge(active: boolean): string {
  return active ? styled("▎", { fg: Color.accent }) : " ";
}

/**
 * A list row with the selection bar, hover tint and selected tint the whole app
 * uses, so every list reads the same way.
 *
 * `selected` and `cursor` are different things and are drawn differently: the
 * selected row is the one the pane is *showing* (the open session, the diff on
 * screen) and carries the blue bar; the cursor is where the keyboard is, and
 * carries the accent edge. Painting both the same way left two rows looking
 * equally chosen, with no way to tell which one Enter would act on.
 */
export function row(
  content: string,
  width: number,
  state: { selected?: boolean; cursor?: boolean; hovered?: boolean; focused?: boolean },
): string {
  // Hover wins over selection, so pointing at the row you are already on still
  // shows that it responds.
  const background = state.selected
    ? (state.hovered ? Color.selectionHover : state.focused ? Color.selection : Color.selectionDim)
    : state.hovered || state.cursor
    ? Color.hover
    : undefined;
  const bar = state.cursor
    ? styled("▎", { fg: Color.accent, bg: background })
    : state.selected
    ? styled("▎", { fg: Color.dim, bg: background })
    : fit(" ", 1, { bg: background });
  return fit(`${bar}${fit(content, Math.max(0, width - 1), { bg: background })}`, width, {
    bg: background,
  });
}

/**
 * A clickable chip or button.
 *
 * Every interactive element that isn't a list row goes through this, so hover
 * looks the same everywhere: the pointer landing on something that responds
 * always tints it, whether it is a tab, a divider handle or a dropdown.
 */
export function control(
  label: string,
  state: { focused?: boolean; hovered?: boolean; active?: boolean; danger?: boolean } = {},
): string {
  if (state.danger) {
    return styled(label, {
      fg: Color.black,
      bg: state.hovered ? Color.orange : Color.red,
      bold: true,
    });
  }
  if (state.focused) {
    return styled(label, { fg: Color.black, bg: Color.accent, bold: true });
  }
  if (state.active) {
    return styled(label, {
      fg: Color.fg,
      bg: state.hovered ? Color.selectionHover : Color.selection,
      bold: true,
    });
  }
  return styled(label, {
    fg: state.hovered ? Color.fg : Color.dim,
    bg: state.hovered ? Color.hover : undefined,
  });
}

/**
 * A dropdown's closed state: the current value plus the marker that says it
 * opens a list. Tinted on hover and on focus like every other control.
 */
export function dropdown(
  value: string,
  width: number,
  state: { focused?: boolean; hovered?: boolean } = {},
): string {
  const background = state.focused ? Color.selection : state.hovered ? Color.hover : Color.panelAlt;
  const inner = Math.max(1, width - 3);
  return fit(
    ` ${styled(elideHead(value, inner), { fg: Color.fg, bg: background })}` +
      styled(" ▾", {
        fg: state.focused || state.hovered ? Color.accent : Color.dim,
        bg: background,
      }),
    width,
    { bg: background },
  );
}

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

/**
 * The spinner frame for a given age in milliseconds.
 *
 * Derived from elapsed time rather than a counter, so every spinner on screen
 * turns in step and none of them needs state of its own.
 */
export function spinnerFrame(elapsedMs: number): string {
  return SPINNER[Math.floor(elapsedMs / 90) % SPINNER.length];
}

/** Centred placeholder text for an empty pane. */
export function placeholder(
  width: number,
  height: number,
  title: string,
  detail?: string,
): string[] {
  const lines: string[] = [];
  const body = [styled(title, { fg: Color.dim, bold: true })];
  if (detail) {
    for (const wrapped of wrap(detail, Math.max(4, width - 4))) {
      body.push(styled(wrapped, { fg: Color.dimmer }));
    }
  }
  const top = Math.max(0, Math.floor((height - body.length) / 2));
  for (let index = 0; index < height; index += 1) {
    const entry = body[index - top];
    if (entry === undefined) {
      lines.push(fit("", width));
      continue;
    }
    const pad = Math.max(0, Math.floor((width - displayWidth(entry)) / 2));
    lines.push(fit(" ".repeat(pad) + entry, width));
  }
  return lines;
}

/** Greedy word wrap. Words longer than the width are broken rather than dropped. */
export function wrap(text: string, width: number): string[] {
  if (width <= 0) return [];
  const lines: string[] = [];
  for (const paragraph of text.split("\n")) {
    let current = "";
    for (const word of paragraph.split(/\s+/).filter((entry) => entry.length > 0)) {
      const candidate = current ? `${current} ${word}` : word;
      if (displayWidth(candidate) <= width) {
        current = candidate;
        continue;
      }
      if (current) lines.push(current);
      if (displayWidth(word) <= width) {
        current = word;
        continue;
      }
      // A single word too long to fit is chopped at the margin.
      let rest = word;
      while (displayWidth(rest) > width) {
        lines.push(rest.slice(0, width));
        rest = rest.slice(width);
      }
      current = rest;
    }
    lines.push(current);
  }
  return lines;
}

// MARK: - Text input

/**
 * A single-line editable field.
 *
 * Holds its own cursor and horizontal scroll so a long value stays usable in a
 * narrow modal.
 */
export class TextInput {
  value: string;
  cursor: number;

  constructor(value = "") {
    this.value = value;
    this.cursor = value.length;
  }

  set(value: string): void {
    this.value = value;
    this.cursor = value.length;
  }

  /** Apply a keystroke. Returns whether it was consumed. */
  handle(key: { name: string; ctrl: boolean; alt: boolean }): boolean {
    if (key.alt) return false;
    if (key.ctrl) {
      switch (key.name) {
        case "a":
          this.cursor = 0;
          return true;
        case "e":
          this.cursor = this.value.length;
          return true;
        case "u":
          this.value = this.value.slice(this.cursor);
          this.cursor = 0;
          return true;
        case "k":
          this.value = this.value.slice(0, this.cursor);
          return true;
        case "w": {
          const head = this.value.slice(0, this.cursor).replace(/\S*\s*$/, "");
          this.value = head + this.value.slice(this.cursor);
          this.cursor = head.length;
          return true;
        }
        default:
          return false;
      }
    }
    switch (key.name) {
      case "backspace":
        if (this.cursor > 0) {
          this.value = this.value.slice(0, this.cursor - 1) + this.value.slice(this.cursor);
          this.cursor -= 1;
        }
        return true;
      case "delete":
        this.value = this.value.slice(0, this.cursor) + this.value.slice(this.cursor + 1);
        return true;
      case "left":
        this.cursor = Math.max(0, this.cursor - 1);
        return true;
      case "right":
        this.cursor = Math.min(this.value.length, this.cursor + 1);
        return true;
      case "home":
        this.cursor = 0;
        return true;
      case "end":
        this.cursor = this.value.length;
        return true;
      case "space":
        this.insert(" ");
        return true;
      default:
        if (key.name.length === 1) {
          this.insert(key.name);
          return true;
        }
        return false;
    }
  }

  insert(text: string): void {
    this.value = this.value.slice(0, this.cursor) + text + this.value.slice(this.cursor);
    this.cursor += text.length;
  }

  /** The leading space every field is drawn with, so the cursor lines up. */
  private static readonly GUTTER = 1;

  /** How wide the editable window is inside a field of `width` cells. */
  private static innerWidth(width: number): number {
    return Math.max(1, width - 2);
  }

  /**
   * Where the caret sits, as a cell offset from the field's left edge.
   *
   * The renderer places the terminal's own cursor here, so a focused field
   * carries a real blinking caret rather than a painted stand-in — including
   * when the field is empty and showing its hint.
   */
  cursorOffset(width: number): number {
    const inner = TextInput.innerWidth(width);
    const start = Math.max(0, this.cursor - inner + 1);
    return TextInput.GUTTER + (this.cursor - start);
  }

  /**
   * The field as one line, scrolled so the caret is always inside it.
   *
   * A focused field is tinted and keeps its hint visible when empty; the caret
   * itself is the terminal's, positioned by `cursorOffset`.
   */
  render(width: number, focused: boolean, hint = "", hovered = false): string {
    const inner = TextInput.innerWidth(width);
    // The same three shades a dropdown uses, so every control that takes input
    // reads as one kind of thing and the panel behind them as another. A
    // resting field on `panel` would be the panel — invisible as a field.
    const background = focused ? Color.selection : hovered ? Color.hover : Color.panelAlt;
    if (!this.value && hint) {
      return fit(
        ` ${styled(elideHead(hint, inner), { fg: Color.dimmer, bg: background })}`,
        width,
        { bg: background },
      );
    }
    const start = Math.max(0, this.cursor - inner + 1);
    const window = this.value.slice(start, start + inner);
    return fit(` ${styled(window, { fg: Color.fg, bg: background })}`, width, { bg: background });
  }
}
