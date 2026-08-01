/**
 * The two small overlays: the destructive-action confirmation, and the key map.
 */

import { center, Color, fit, styled } from "../tui/ansi.ts";
import { control, type HitMap, panel, type Rect, TextInput, wrap } from "../tui/widgets.ts";
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

interface Binding {
  keys: string;
  description: string;
}

const BINDINGS: Binding[] = [
  { keys: "Tab / ⇧Tab", description: "Move between controls; ↑↓←→ within one" },
  { keys: "Enter", description: "Activate; on the tab strip, start typing" },
  { keys: "Alt+F", description: "Leave the terminal (where Tab is the shell's)" },
  { keys: "Esc", description: "Back to typing in the terminal" },
  { keys: "Alt+P", description: "Command palette — everything, by name" },
  { keys: "Alt+N", description: "New session on a fresh VM" },
  { keys: "Alt+L", description: "New local shell" },
  { keys: "Alt+M", description: "Rename the session" },
  { keys: "Alt+W", description: "Close the session (leaves the VM running)" },
  { keys: "Alt+D", description: "Delete the session and destroy its VM" },
  { keys: "Alt+O", description: "Open this VM's URL in the system browser" },
  { keys: "Alt+S", description: "Toggle the sessions sidebar" },
  { keys: "Alt+R", description: "Toggle the worktree diff sidebar" },
  { keys: "Alt+Z", description: "Zen mode — the terminal, edge to edge" },
  { keys: "Alt+1…9", description: "Select a session (9 is the last)" },
  { keys: "Alt+[ / ]", description: "Previous / next session" },
  { keys: "Alt+T", description: "New tmux window in this session" },
  { keys: "Alt+, ", description: "Settings" },
  { keys: "Alt+← / →", description: "Previous / next terminal tab" },
  { keys: "Alt+K", description: "Reconnect a dropped session" },
  { keys: "/ n p", description: "In the diff: search, next / previous match" },
  { keys: "[ ]", description: "In the diff: previous / next file or hunk" },
  { keys: "y", description: "Copy the diff, file or commit to the clipboard" },
  { keys: "F1", description: "This help" },
  { keys: "Alt+Q", description: "Quit" },
  { keys: "Mouse", description: "Click, drag the dividers, wheel to scroll" },
];

/** The key map. Every shortcut is Alt-based so plain keys reach the terminal. */
export class HelpModal {
  render(cols: number, rows: number, _hits: HitMap): { lines: string[]; rect: Rect } {
    const width = Math.min(64, cols - 4);
    const height = Math.min(BINDINGS.length + 5, rows - 2);
    const rect: Rect = {
      x: Math.floor((cols - width) / 2),
      y: Math.floor((rows - height) / 2),
      width,
      height,
    };
    const inner = width - 2;
    const lines: string[] = [fit("", inner, { bg: Color.panel })];
    for (const binding of BINDINGS) {
      lines.push(
        fit(
          ` ${styled(binding.keys.padEnd(12), { fg: Color.accent, bg: Color.panel })}` +
            styled(binding.description, { fg: Color.fg, bg: Color.panel }),
          inner,
          { bg: Color.panel },
        ),
      );
    }
    lines.push(fit("", inner, { bg: Color.panel }));
    lines.push(
      fit(
        center(
          styled("Any other key goes to the terminal", { fg: Color.dimmer, bg: Color.panel }),
          inner,
        ),
        inner,
        {
          bg: Color.panel,
        },
      ),
    );
    return { lines: panel(width, height, "Keys", lines, { bg: Color.panel }), rect };
  }
}
