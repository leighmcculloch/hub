/**
 * The middle pane: the tab strip for the session's tmux panes, and the pane's
 * own screen below it.
 *
 * The screen is whatever `capture-pane -e` last returned — tmux's own rendering
 * of the pane, styling included — so lines are drawn through unchanged apart
 * from being clipped to the pane's width.
 */

import { Color, fit, styled } from "../tui/ansi.ts";
import { type HitMap, placeholder, type Rect, rule, wrap } from "../tui/widgets.ts";
import { tabDisplayName, type TerminalSession } from "../model/terminal-session.ts";

export interface TerminalGeometry {
  /** Where the pane's own screen starts, and how big tmux should make it. */
  content: Rect;
}

export class TerminalPane {
  private hovered: string | null = null;

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
    lines.push(this.renderTabBar(session, rect, hits));
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
    void focused;
    return { lines, content };
  }

  private renderTabBar(session: TerminalSession, rect: Rect, hits: HitMap): string {
    const width = rect.width;
    if (session.tabs.length === 0) {
      return fit(` ${styled(session.displayName, { fg: Color.dim })}`, width);
    }
    let bar = "";
    let x = rect.x;
    for (let index = 0; index < session.tabs.length; index += 1) {
      const tab = session.tabs[index];
      const selected = tab.paneID === session.selectedTabID;
      const label = ` ${tabDisplayName(tab)} `;
      const chip = styled(label, {
        fg: selected ? Color.fg : Color.dim,
        bg: selected ? Color.selection : undefined,
        bold: selected,
      });
      const id = `terminal.tab:${index}`;
      hits.add({ x, y: rect.y, width: label.length, height: 1 }, id);
      bar += this.hovered === id && !selected
        ? styled(label, { fg: Color.fg, bg: Color.hover })
        : chip;
      x += label.length;
    }
    const trailing = ` ${styled("+", { fg: Color.dimmer })} `;
    hits.add({ x, y: rect.y, width: 3, height: 1 }, "terminal.newTab");
    return fit(bar + trailing, width);
  }

  setHover(id: string | null): void {
    this.hovered = id;
  }

  /** Wrapped help text, used by the empty state and the help overlay. */
  static describe(text: string, width: number): string[] {
    return wrap(text, width);
  }
}
