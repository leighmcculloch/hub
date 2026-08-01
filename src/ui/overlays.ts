/**
 * The two small overlays: the destructive-action confirmation, and the key map.
 */

import { center, Color, fit, styled } from "../tui/ansi.ts";
import { control, type HitMap, panel, type Rect, wrap } from "../tui/widgets.ts";

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

interface Binding {
  keys: string;
  description: string;
}

const BINDINGS: Binding[] = [
  { keys: "Tab / ⇧Tab", description: "Move between controls; ↑↓←→ within one" },
  { keys: "Enter", description: "Activate; on the tab strip, start typing" },
  { keys: "Alt+F", description: "Leave the terminal (where Tab is the shell's)" },
  { keys: "Esc", description: "Back to typing in the terminal" },
  { keys: "Alt+N", description: "New session on a fresh VM" },
  { keys: "Alt+L", description: "New local shell" },
  { keys: "Alt+W", description: "Close the session (leaves the VM running)" },
  { keys: "Alt+D", description: "Delete the session and destroy its VM" },
  { keys: "Alt+O", description: "Open this VM's URL in the system browser" },
  { keys: "Alt+S", description: "Toggle the sessions sidebar" },
  { keys: "Alt+R", description: "Toggle the worktree diff sidebar" },
  { keys: "Alt+1…9", description: "Select a session (9 is the last)" },
  { keys: "Alt+[ / ]", description: "Previous / next session" },
  { keys: "Alt+T", description: "New tmux window in this session" },
  { keys: "Alt+, ", description: "Settings" },
  { keys: "Alt+← / →", description: "Previous / next terminal tab" },
  { keys: "Alt+K", description: "Reconnect a dropped session" },
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
