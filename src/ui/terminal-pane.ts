/**
 * The middle pane: the tab strip for the session's tmux panes, and the pane's
 * own screen below it.
 *
 * The screen is whatever `capture-pane -e` last returned — tmux's own rendering
 * of the pane, styling included — so lines are drawn through unchanged apart
 * from being clipped to the pane's width.
 */

import { Color, displayWidth, fit, styled } from "../tui/ansi.ts";
import {
  control,
  type HitMap,
  placeholder,
  type Rect,
  rule,
  spinnerFrame,
  wrap,
} from "../tui/widgets.ts";
import {
  type SessionPhase,
  tabDisplayName,
  type TerminalSession,
} from "../model/terminal-session.ts";

export interface TerminalGeometry {
  /** Where the pane's own screen starts, and how big tmux should make it. */
  content: Rect;
}

/**
 * The stops Tab visits inside this pane.
 *
 * The pane's *body* is deliberately not one of them: while it has the keyboard
 * every key belongs to the program running there, Tab included — a shell
 * without Tab completion is not a shell. Enter on the tab strip steps into the
 * body, and Alt+F steps back out.
 */
const PARTS = ["tabs", "new"] as const;
type Part = typeof PARTS[number] | "body";

export class TerminalPane {
  part: Part = "body";
  private hovered: string | null = null;

  focusFirst(): void {
    this.part = "tabs";
  }

  focusLast(): void {
    this.part = "new";
  }

  /** Put the keyboard in the pane itself, where keys go to the program. */
  enterBody(): void {
    this.part = "body";
  }

  get inBody(): boolean {
    return this.part === "body";
  }

  advance(step: number): boolean {
    // The body is a dead end for Tab; leaving it is Alt+F's job.
    if (this.part === "body") return false;
    const next = PARTS.indexOf(this.part) + step;
    if (next < 0 || next >= PARTS.length) return false;
    this.part = PARTS[next];
    return true;
  }

  /**
   * Draw the pane. Also reports the session's client size to tmux, because the
   * layout is the only place that knows how much room the pane actually got.
   */
  render(
    session: TerminalSession | null,
    rect: Rect,
    hits: HitMap,
    focused: boolean,
    configured = true,
  ): { lines: string[]; content: Rect } {
    const width = rect.width;
    const emptyContent = { x: rect.x, y: rect.y, width, height: rect.height };

    if (session === null) {
      // Without a token there is nothing Alt+N can do, so the empty screen
      // points at the one thing that has to happen first.
      return {
        lines: configured
          ? placeholder(
            width,
            rect.height,
            "No session open",
            "Alt+N starts one on a fresh VM · Alt+L opens a local shell · F1 for keys",
          )
          : placeholder(
            width,
            rect.height,
            "Add a provider token to begin",
            "Alt+, opens Settings, which takes an exe.dev or sprites.dev token · " +
              "Alt+L opens a local shell in the meantime",
          ),
        content: emptyContent,
      };
    }

    const lines: string[] = [];
    lines.push(this.renderTabBar(session, rect, hits, focused));
    lines.push(rule(width));

    const contentHeight = rect.height - lines.length;
    const content: Rect = { x: rect.x, y: rect.y + lines.length, width, height: contentHeight };

    if (session.isDisconnected) {
      const detail = session.disconnectReason ?? "The connection dropped.";
      lines.push(
        ...placeholder(width, contentHeight, "Disconnected", `${detail}  ·  Alt+R to reconnect`),
      );
      return { lines, content };
    }

    // A connecting session has nothing to draw — and for a reconnect that is
    // the *normal* case for several seconds, because the bootstrap it runs
    // prints almost nothing. Say what is happening rather than showing a blank
    // rectangle that looks identical to a hang.
    if (session.isConnecting) {
      lines.push(...connectingPanel(session, width, contentHeight));
      return { lines, content };
    }

    const tab = session.selectedTab;
    if (!tab) {
      lines.push(...placeholder(width, contentHeight, "No pane", "tmux reported no panes."));
      return { lines, content };
    }

    hits.add(content, "terminal.body");
    for (let index = 0; index < contentHeight; index += 1) {
      // Lines carry tmux's own SGR sequences; `fit` clips and pads without
      // cutting one in half, and closes any left open at the margin.
      lines.push(fit(tab.screen[index] ?? "", width));
    }
    return { lines, content };
  }

  private renderTabBar(
    session: TerminalSession,
    rect: Rect,
    hits: HitMap,
    focused: boolean,
  ): string {
    const width = rect.width;
    if (session.tabs.length === 0) {
      return fit(` ${styled(session.displayName, { fg: Color.dim })}`, width);
    }
    const onTabs = focused && this.part === "tabs";
    let bar = "";
    let x = rect.x;
    for (let index = 0; index < session.tabs.length; index += 1) {
      const tab = session.tabs[index];
      const selected = tab.paneID === session.selectedTabID;
      const id = `terminal.tab:${index}`;
      // A background window that has printed something is marked, the same way
      // a background session is in the sidebar.
      const label = `${tabDisplayName(tab)}${tab.hasUnseenOutput && !selected ? " •" : ""}`;
      hits.add({ x, y: rect.y, width: label.length + 2, height: 1 }, id);
      bar += control(` ${label} `, {
        // The strip having the keyboard is shown on the current tab, so it is
        // clear that left/right will move between them.
        focused: selected && onTabs,
        active: selected,
        hovered: this.hovered === id,
      });
      x += label.length + 2;
    }
    hits.add({ x, y: rect.y, width: 3, height: 1 }, "terminal.newTab");
    bar += control(" + ", {
      focused: focused && this.part === "new",
      hovered: this.hovered === "terminal.newTab",
    });
    if (onTabs || (focused && this.part === "new")) {
      bar += styled("  ← → switch · Enter to type", { fg: Color.dimmer });
    }

    // Reading the scrollback is a mode, and a mode you can't see is a mode you
    // get stuck in — so it says so, and says how to get out.
    const back = session.selectedTab?.scrollback ?? 0;
    if (back === 0) return fit(bar, width);
    const note = styled(` ↑ ${back} lines back · Alt+End or type to return `, {
      fg: Color.black,
      bg: Color.orange,
      bold: true,
    });
    const gap = Math.max(1, width - displayWidth(bar) - displayWidth(note));
    return fit(`${bar}${" ".repeat(gap)}${note}`, width);
  }

  /** Handle a key for the tab strip or the + button. */
  key(
    session: TerminalSession | null,
    name: string,
  ): "enterBody" | "newTab" | "handled" | "ignored" {
    if (this.part === "new") {
      return name === "enter" || name === "space" ? "newTab" : "ignored";
    }
    if (!session) return "ignored";
    switch (name) {
      case "left":
        session.selectAdjacentTab(-1);
        return "handled";
      case "right":
        session.selectAdjacentTab(1);
        return "handled";
      case "delete":
      case "backspace": {
        const tab = session.selectedTab;
        if (tab) session.closeTab(tab);
        return "handled";
      }
      case "enter":
      case "space":
        return "enterBody";
      default:
        return "ignored";
    }
  }

  setHover(id: string | null): void {
    this.hovered = id;
  }

  /** Wrapped help text, used by the empty state and the help overlay. */
  static describe(text: string, width: number): string[] {
    return wrap(text, width);
  }
}

/** What each phase is waiting for, in words. */
const PHASES: Array<{ phase: SessionPhase; label: string; detail: string }> = [
  {
    phase: "spawning",
    label: "Opening the connection",
    detail: "Reaching the VM and starting tmux.",
  },
  {
    phase: "attaching",
    label: "Attaching to tmux",
    detail: "Connected — waiting for the session's panes.",
  },
  {
    phase: "warming",
    label: "Running the setup",
    detail: "The pane is up. The bootstrap prints little, so this can look quiet.",
  },
];

/**
 * The connecting panel: a checklist of the stages, the elapsed time, and
 * whatever the transport last said.
 *
 * The stages are shown all at once, ticked off as they pass, so the wait has a
 * shape — you can see what is done, what is happening, and what is left.
 */
export function connectingPanel(
  session: TerminalSession,
  width: number,
  height: number,
): string[] {
  const elapsed = session.elapsedMs;
  const frame = spinnerFrame(elapsed);
  const current = session.phase;
  const reached = PHASES.findIndex((one) => one.phase === current);

  const body: string[] = [];
  body.push(styled(`${frame} Connecting to ${session.destination ?? "the shell"}`, {
    fg: Color.fg,
    bold: true,
  }));
  body.push("");

  for (let index = 0; index < PHASES.length; index += 1) {
    const stage = PHASES[index];
    const done = index < reached;
    const active = index === reached;
    const mark = done ? "✓" : active ? frame : "·";
    const colour = done ? Color.green : active ? Color.accent : Color.dimmer;
    body.push(
      `${styled(mark, { fg: colour })} ${
        styled(stage.label, { fg: active ? Color.fg : Color.dim, bold: active })
      }`,
    );
  }

  const stage = PHASES[Math.max(0, reached)];
  body.push("");
  body.push(styled(stage.detail, { fg: Color.dimmer }));
  if (session.progressNote) {
    body.push(styled(session.progressNote, { fg: Color.orange }));
  }
  body.push("");
  body.push(
    styled(`${(elapsed / 1000).toFixed(0)}s elapsed · Alt+K reconnects`, { fg: Color.dimmer }),
  );

  // Centred as a block, so the stages line up with each other rather than each
  // being centred on its own width.
  const inner = Math.max(1, width - 4);
  const rendered: string[] = [];
  for (const line of body) {
    for (const wrapped of line ? wrap(stripForWidth(line), inner) : [""]) {
      rendered.push(wrapped === stripForWidth(line) ? line : wrapped);
    }
  }
  const left = Math.max(0, Math.floor((width - widestOf(rendered)) / 2));
  const top = Math.max(0, Math.floor((height - rendered.length) / 2));

  const lines: string[] = [];
  for (let row = 0; row < height; row += 1) {
    const entry = rendered[row - top];
    lines.push(entry === undefined ? fit("", width) : fit(" ".repeat(left) + entry, width));
  }
  return lines;
}

function stripForWidth(text: string): string {
  // deno-lint-ignore no-control-regex
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

function widestOf(lines: string[]): number {
  return lines.reduce((widest, line) => Math.max(widest, stripForWidth(line).length), 0);
}
