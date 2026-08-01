/**
 * The middle pane: the tab strip for the session's tmux panes, and the pane's
 * own screen below it.
 *
 * The screen is whatever `capture-pane -e` last returned — tmux's own rendering
 * of the pane, styling included — so lines are drawn through unchanged apart
 * from being clipped to the pane's width.
 */

import { Color, fit, styled } from "../tui/ansi.ts";
import { control, type HitMap, placeholder, type Rect, rule, wrap } from "../tui/widgets.ts";
import { tabDisplayName, type TerminalSession } from "../model/terminal-session.ts";

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
  ): { lines: string[]; content: Rect } {
    const width = rect.width;
    const emptyContent = { x: rect.x, y: rect.y, width, height: rect.height };

    if (session === null) {
      return {
        lines: placeholder(
          width,
          rect.height,
          "No session open",
          "Alt+T starts one on a fresh VM · Alt+L opens a local shell · F1 for keys",
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

    const tab = session.selectedTab;
    if (!tab) {
      lines.push(
        ...placeholder(
          width,
          contentHeight,
          `Connecting to ${session.destination ?? "the shell"}…`,
          "tmux is starting; the first pane appears when it does.",
        ),
      );
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
      hits.add({ x, y: rect.y, width: tabDisplayName(tab).length + 2, height: 1 }, id);
      bar += control(` ${tabDisplayName(tab)} `, {
        // The strip having the keyboard is shown on the current tab, so it is
        // clear that left/right will move between them.
        focused: selected && onTabs,
        active: selected,
        hovered: this.hovered === id,
      });
      x += tabDisplayName(tab).length + 2;
    }
    hits.add({ x, y: rect.y, width: 3, height: 1 }, "terminal.newTab");
    bar += control(" + ", {
      focused: focused && this.part === "new",
      hovered: this.hovered === "terminal.newTab",
    });
    if (onTabs || (focused && this.part === "new")) {
      bar += styled("  ← → switch · Enter to type", { fg: Color.dimmer });
    }
    return fit(bar, width);
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
