/**
 * The two small overlays: the destructive-action confirmation, and the key map.
 */

import { center, Color, fit, styled } from "../tui/ansi.ts";
import {
  control,
  type HitMap,
  panel,
  type Rect,
  scrollbar,
  TextInput,
  wrap,
} from "../tui/widgets.ts";
import type { CursorHint } from "./select-popup.ts";

/**
 * Deleting a VM destroys its disk, so it is confirmed. Held as its own overlay
 * rather than inline in a list, so the same confirmation serves the sidebar's ✕
 * and the Alt+D shortcut.
 */
export class ConfirmModal {
  constructor(
    readonly title: string,
    readonly detail: string,
    readonly confirmLabel: string,
    readonly onConfirm: () => void,
  ) {}

  render(
    cols: number,
    rows: number,
    hits: HitMap,
    hovered: string | null = null,
  ): { lines: string[]; rect: Rect } {
    const width = Math.min(60, cols - 4);
    const body = wrap(this.detail, width - 4);
    const height = body.length + 6;
    const rect: Rect = {
      x: Math.floor((cols - width) / 2),
      y: Math.floor((rows - height) / 2),
      width,
      height,
    };
    const inner = width - 2;
    const lines: string[] = [fit("", inner, { bg: Color.panel })];
    for (const line of body) {
      lines.push(fit(` ${styled(line, { fg: Color.fg, bg: Color.panel })}`, inner, {
        bg: Color.panel,
      }));
    }
    lines.push(fit("", inner, { bg: Color.panel }));

    // Each button gets its own region, so the pointer can tell them apart and
    // hover shows which one a click would land on.
    const acceptLabel = ` ${this.confirmLabel} `;
    const cancelLabel = " Cancel ";
    const buttonRow = rect.y + 1 + lines.length;
    hits.add(
      { x: rect.x + 2, y: buttonRow, width: acceptLabel.length, height: 1 },
      "confirm.accept",
    );
    hits.add(
      { x: rect.x + 4 + acceptLabel.length, y: buttonRow, width: cancelLabel.length, height: 1 },
      "confirm.cancel",
    );
    lines.push(
      fit(
        ` ${control(acceptLabel, { danger: true, hovered: hovered === "confirm.accept" })}  ` +
          `${control(cancelLabel, { active: true, hovered: hovered === "confirm.cancel" })}   ` +
          styled("y / Esc", { fg: Color.dimmer, bg: Color.panel }),
        inner,
        { bg: Color.panel },
      ),
    );

    return { lines: panel(width, height, this.title, lines, { bg: Color.panel }), rect };
  }

  /** Returns true when the overlay should close. */
  key(name: string): boolean {
    if (name === "y" || name === "enter") {
      this.onConfirm();
      return true;
    }
    return name === "escape" || name === "n";
  }
}

/**
 * One line of text and somewhere to type it — renaming a session, say, where a
 * whole modal is too much and a bare keystroke is too little.
 *
 * Submitting an empty value is allowed and meaningful: it is how a session goes
 * back to being named by whatever named it in the first place.
 */
export class PromptModal {
  private input: TextInput;
  private cursor: CursorHint | null = null;

  constructor(
    readonly title: string,
    readonly hint: string,
    value: string,
    private onSubmit: (value: string) => void,
  ) {
    this.input = new TextInput(value);
  }

  cursorPosition(): CursorHint | null {
    return this.cursor;
  }

  render(cols: number, rows: number, hits: HitMap): { lines: string[]; rect: Rect } {
    const width = Math.min(56, cols - 4);
    const height = 6;
    const rect: Rect = {
      x: Math.floor((cols - width) / 2),
      y: Math.floor((rows - height) / 2),
      width,
      height,
    };
    const inner = width - 2;
    const fieldY = rect.y + 2;
    hits.add({ x: rect.x + 1, y: fieldY, width: inner, height: 1 }, "prompt.field");

    const lines: string[] = [fit("", inner, { bg: Color.panel })];
    lines.push(this.input.render(inner, true, this.hint, false));
    this.cursor = { x: rect.x + 1 + this.input.cursorOffset(inner), y: fieldY };
    lines.push(fit("", inner, { bg: Color.panel }));
    lines.push(
      fit(
        ` ${styled("Enter saves · Esc cancels", { fg: Color.dimmer, bg: Color.panel })}`,
        inner,
        { bg: Color.panel },
      ),
    );
    return { lines: panel(width, height, this.title, lines, { bg: Color.panel }), rect };
  }

  /** Returns true when the overlay should close. */
  key(event: { name: string; ctrl: boolean; alt: boolean; shift: boolean }): boolean {
    if (event.name === "escape") return true;
    if (event.name === "enter") {
      this.onSubmit(this.input.value.trim());
      return true;
    }
    this.input.handle(event);
    return false;
  }
}

type HelpRow =
  | { kind: "heading"; text: string }
  | { kind: "binding"; keys: string; description: string };

/**
 * The key map, grouped by what you'd be trying to do. Grouped rather than
 * alphabetical because nobody arrives at a key map knowing the key — they
 * arrive knowing the task.
 */
const HELP_ROWS: HelpRow[] = [
  { kind: "heading", text: "Getting around" },
  { kind: "binding", keys: "Tab / ⇧Tab", description: "Move between controls; ↑↓←→ within one" },
  { kind: "binding", keys: "Enter", description: "Activate; on the tab strip, start typing" },
  { kind: "binding", keys: "Alt+F", description: "Leave the terminal (where Tab is the shell's)" },
  { kind: "binding", keys: "Esc", description: "Back to typing in the terminal" },
  { kind: "binding", keys: "Alt+P", description: "Command palette — everything, by name" },
  { kind: "binding", keys: "Mouse", description: "Click, drag the dividers, wheel to scroll" },

  { kind: "heading", text: "Sessions" },
  { kind: "binding", keys: "Alt+N", description: "New session on a fresh VM" },
  { kind: "binding", keys: "Alt+L", description: "New local shell" },
  { kind: "binding", keys: "Alt+G", description: "Go to a session or VM by name" },
  { kind: "binding", keys: "Alt+1…9", description: "Select a session (9 is the last)" },
  { kind: "binding", keys: "Alt+[ / ]", description: "Previous / next session" },
  { kind: "binding", keys: "Alt+M", description: "Rename the session" },
  { kind: "binding", keys: "Alt+W", description: "Close the session (leaves the VM running)" },
  { kind: "binding", keys: "Alt+D", description: "Delete the session and destroy its VM" },
  { kind: "binding", keys: "Alt+K", description: "Reconnect a dropped session" },
  { kind: "binding", keys: "Alt+O", description: "Open this VM's URL in the system browser" },

  { kind: "heading", text: "The terminal" },
  { kind: "binding", keys: "Alt+T", description: "New tmux window in this session" },
  { kind: "binding", keys: "Alt+← / →", description: "Previous / next terminal tab" },
  { kind: "binding", keys: "Alt+PgUp/Dn", description: "Read the pane's scrollback" },
  { kind: "binding", keys: "Alt+End", description: "Back to the live screen" },
  { kind: "binding", keys: "Alt+C", description: "Copy the pane's screen to the clipboard" },

  { kind: "heading", text: "The diff" },
  { kind: "binding", keys: "/ n p", description: "Search, next / previous match" },
  { kind: "binding", keys: "[ ]", description: "Previous / next file or hunk" },
  { kind: "binding", keys: "y", description: "Copy the diff, file or commit" },

  { kind: "heading", text: "Layout" },
  { kind: "binding", keys: "Alt+S", description: "Toggle the sessions sidebar" },
  { kind: "binding", keys: "Alt+R", description: "Toggle the worktree diff sidebar" },
  { kind: "binding", keys: "Alt+Z", description: "Zen mode — the terminal, edge to edge" },
  { kind: "binding", keys: "Alt+⇧← / →", description: "Resize the sidebar you're in" },

  { kind: "heading", text: "The app" },
  { kind: "binding", keys: "Alt+,", description: "Settings" },
  { kind: "binding", keys: "F1", description: "This help" },
  { kind: "binding", keys: "Alt+Q", description: "Quit" },
];

/**
 * The key map. Every shortcut is Alt-based so plain keys reach the terminal.
 *
 * Scrolls, because the list is longer than a short terminal is tall and a key
 * you can't scroll to is a key that doesn't exist.
 */
export class HelpModal {
  private offset = 0;

  render(cols: number, rows: number, _hits: HitMap): { lines: string[]; rect: Rect } {
    const width = Math.min(64, cols - 4);
    const height = Math.min(HELP_ROWS.length + 4, rows - 2);
    const rect: Rect = {
      x: Math.floor((cols - width) / 2),
      y: Math.floor((rows - height) / 2),
      width,
      height,
    };
    const inner = width - 2;
    const bodyHeight = Math.max(1, height - 3);
    this.offset = Math.min(
      Math.max(0, this.offset),
      Math.max(0, HELP_ROWS.length - bodyHeight),
    );
    const bar = scrollbar(this.offset, bodyHeight, HELP_ROWS.length);

    const lines: string[] = [];
    for (let index = 0; index < bodyHeight; index += 1) {
      const row = HELP_ROWS[this.offset + index];
      if (!row) {
        lines.push(fit("", inner, { bg: Color.panel }));
        continue;
      }
      const text = row.kind === "heading"
        ? ` ${styled(row.text.toUpperCase(), { fg: Color.dim, bold: true, bg: Color.panel })}`
        : ` ${styled(row.keys.padEnd(12), { fg: Color.accent, bg: Color.panel })}` +
          styled(row.description, { fg: Color.fg, bg: Color.panel });
      // The bar sits at the right edge, so the row is padded out to meet it.
      lines.push(
        fit(fit(text, inner - 1, { bg: Color.panel }) + bar[index], inner, { bg: Color.panel }),
      );
    }
    lines.push(
      fit(
        center(
          styled(
            HELP_ROWS.length > bodyHeight
              ? "↑↓ scroll · any other key goes to the terminal"
              : "Any other key goes to the terminal",
            { fg: Color.dimmer, bg: Color.panel },
          ),
          inner,
        ),
        inner,
        { bg: Color.panel },
      ),
    );
    return { lines: panel(width, height, "Keys", lines, { bg: Color.panel }), rect };
  }

  /** Returns true when the overlay should close. */
  key(name: string): boolean {
    switch (name) {
      case "up":
        this.offset -= 1;
        return false;
      case "down":
        this.offset += 1;
        return false;
      case "pageup":
        this.offset -= 10;
        return false;
      case "pagedown":
        this.offset += 10;
        return false;
      case "home":
        this.offset = 0;
        return false;
      case "end":
        this.offset = HELP_ROWS.length;
        return false;
      default:
        return true;
    }
  }

  scroll(delta: number): void {
    this.offset += delta;
  }
}
