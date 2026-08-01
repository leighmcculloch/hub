/**
 * The left sidebar: one row per open session, then the VMs on the account that
 * aren't open yet. Clicking a session selects it; clicking an unopened VM
 * connects to it.
 */

import { Color, displayWidth, elideMiddle, fit, styled } from "../tui/ansi.ts";
import {
  type HitMap,
  placeholder,
  type Rect,
  row as listRow,
  rule,
  scrollbar,
  scrollToShow,
  sectionHeader,
  spinnerFrame,
} from "../tui/widgets.ts";
import type { Workspace } from "../model/workspace.ts";
import type { RemoteVMRecord } from "../providers/types.ts";
import type { TerminalSession } from "../model/terminal-session.ts";

type SidebarRow =
  | { kind: "header"; title: string; busy: boolean }
  | { kind: "session"; session: TerminalSession }
  | { kind: "vm"; vm: RemoteVMRecord }
  /** Why the list below is short — a failed listing, not an empty account. */
  | { kind: "notice"; text: string };

/** The stops Tab visits inside this pane, in order. */
const PARTS = ["list", "new"] as const;
type Part = typeof PARTS[number];

export class SessionSidebar {
  /** The row the keyboard is on, as an index into the flattened list. */
  selection = 0;
  /** Which control inside the pane has the keyboard. */
  part: Part = "list";
  private offset = 0;
  private rows: SidebarRow[] = [];
  private hovered: string | null = null;

  constructor(private workspace: Workspace) {}

  focusFirst(): void {
    this.part = PARTS[0];
  }

  focusLast(): void {
    this.part = PARTS[PARTS.length - 1];
  }

  /**
   * Move to the next control in the pane. False when there isn't one, which is
   * the app's cue to move on to the next pane.
   */
  advance(step: number): boolean {
    const next = PARTS.indexOf(this.part) + step;
    if (next < 0 || next >= PARTS.length) return false;
    this.part = PARTS[next];
    return true;
  }

  render(rect: Rect, hits: HitMap, focused: boolean): string[] {
    const width = rect.width;
    this.rows = this.buildRows();

    const lines: string[] = [];
    const listHeight = rect.height - 2; // the new-session footer and its rule

    if (this.rows.length === 0) {
      // Nothing here and no token is a setup step, not an empty list.
      const configured = this.workspace.config.effectiveToken !== "";
      lines.push(
        ...placeholder(
          width,
          listHeight,
          configured ? "No sessions" : "No token yet",
          configured ? "Start one on a fresh VM with Alt+N." : "Add one in Settings, with Alt+,",
        ),
      );
    } else {
      this.selection = Math.min(Math.max(0, this.selection), this.rows.length - 1);
      this.offset = scrollToShow(this.offset, this.selection, listHeight, this.rows.length);
      const bar = scrollbar(this.offset, listHeight, this.rows.length);
      for (let index = 0; index < listHeight; index += 1) {
        const entry = this.rows[this.offset + index];
        if (!entry) {
          lines.push(fit("", width));
          continue;
        }
        if (entry.kind === "header") {
          lines.push(sectionHeader(entry.title, width, entry.busy ? "◌" : ""));
          continue;
        }
        if (entry.kind === "notice") {
          // No hit region: there is nothing to click, and tinting it under the
          // pointer would promise otherwise.
          lines.push(
            fit(
              ` ${styled("!", { fg: Color.orange })} ` +
                styled(elideMiddle(entry.text, Math.max(6, width - 4)), { fg: Color.dim }),
              width,
            ),
          );
          continue;
        }
        const id = `sidebar.row:${this.offset + index}`;
        hits.add({ x: rect.x, y: rect.y + index, width, height: 1 }, id);
        const listFocused = focused && this.part === "list";
        // The row the keyboard is on is marked even when it isn't the open
        // session, so arrowing through the list is visible.
        const onCursor = listFocused && this.offset + index === this.selection;
        lines.push(
          fit(
            listRow(this.rowText(entry, width - 2), width - 1, {
              selected: this.isSelected(entry) || onCursor,
              hovered: this.hovered === id,
              focused: listFocused,
            }) + bar[index],
            width,
          ),
        );
      }
    }

    lines.push(rule(width));
    hits.add({ x: rect.x, y: rect.y + rect.height - 1, width, height: 1 }, "sidebar.new");
    const newFocused = focused && this.part === "new";
    const background = newFocused
      ? Color.selection
      : this.hovered === "sidebar.new"
      ? Color.hover
      : undefined;
    lines.push(
      fit(
        ` ${styled("+ New Session", { fg: Color.accent, bold: true, bg: background })}` +
          `${" ".repeat(Math.max(1, width - 20))}${
            styled("Alt+N", { fg: Color.dimmer, bg: background })
          }`,
        width,
        { bg: background },
      ),
    );
    return lines.slice(0, rect.height);
  }

  private buildRows(): SidebarRow[] {
    const rows: SidebarRow[] = [];
    if (this.workspace.sessions.length > 0) {
      rows.push({ kind: "header", title: "Sessions", busy: false });
      for (const session of this.workspace.sessions) rows.push({ kind: "session", session });
    }
    const unopened = this.workspace.unopenedVMs;
    const failure = this.workspace.vmListError;
    if (unopened.length > 0 || this.workspace.loadingVMs || failure) {
      rows.push({ kind: "header", title: "Existing", busy: this.workspace.loadingVMs });
      if (failure) rows.push({ kind: "notice", text: failure });
      for (const vm of unopened) rows.push({ kind: "vm", vm });
    }
    return rows;
  }

  private isSelected(entry: SidebarRow): boolean {
    return entry.kind === "session" && entry.session.id === this.workspace.selectedSessionID;
  }

  private rowText(entry: SidebarRow, width: number): string {
    if (entry.kind === "session") {
      const session = entry.session;
      // The same spinner the pane shows, so a session still connecting is
      // obvious from the list without opening it.
      const icon = session.isDisconnected
        ? styled("!", { fg: Color.orange, bold: true })
        : session.isConnecting
        ? styled(spinnerFrame(session.elapsedMs), { fg: Color.accent })
        : styled("›", { fg: Color.accent });
      const nameWidth = Math.max(6, width - 4);
      const name = elideMiddle(session.displayName, nameWidth);
      const style = session.isDisconnected ? { fg: Color.dim } : { fg: Color.fg };
      // An agent working in a session you aren't looking at is the reason to
      // keep several open, so a session that has printed something since you
      // last saw it carries a dot on the right until you go back to it.
      if (!session.hasUnseenOutput || this.isSelected(entry)) {
        return `${icon} ${styled(name, style)}`;
      }
      const gap = " ".repeat(Math.max(1, nameWidth - displayWidth(name) + 1));
      return `${icon} ${styled(name, style)}${gap}${styled("●", { fg: Color.orange })}`;
    }
    if (entry.kind === "vm") {
      const running = entry.vm.status === "running";
      const dot = styled("•", { fg: running ? Color.green : Color.dimmer });
      const name = elideMiddle(entry.vm.name, Math.max(6, width - 4));
      return `${dot} ${styled(name, { fg: Color.dim })}`;
    }
    return "";
  }

  setHover(id: string | null): void {
    this.hovered = id;
  }

  /** The row a hit id refers to, if it is one of ours. */
  rowFor(id: string): SidebarRow | null {
    if (!id.startsWith("sidebar.row:")) return null;
    return this.rows[Number(id.slice("sidebar.row:".length))] ?? null;
  }

  /** The row the keyboard selection is on. */
  get current(): SidebarRow | null {
    return this.rows[this.selection] ?? null;
  }

  /**
   * Handle a key for whichever control has the keyboard. Returns what the app
   * should do about it, since activating a row is the app's business.
   */
  key(name: string): "activate" | "delete" | "handled" | "ignored" {
    if (this.part === "new") {
      return name === "enter" || name === "space" ? "activate" : "ignored";
    }
    switch (name) {
      case "up":
        this.move(-1);
        return "handled";
      case "down":
        this.move(1);
        return "handled";
      case "home":
        this.selection = 0;
        this.move(1);
        this.move(-1);
        return "handled";
      case "end":
        this.selection = this.rows.length - 1;
        return "handled";
      case "enter":
      case "space":
        return "activate";
      case "delete":
      case "backspace":
        return "delete";
      default:
        return "ignored";
    }
  }

  /** True when the New Session button is what Enter would press. */
  get onNewButton(): boolean {
    return this.part === "new";
  }

  move(offset: number): void {
    if (this.rows.length === 0) return;
    let next = this.selection;
    // Headers and notices aren't selectable, so keep going past them in the
    // same direction.
    for (let step = 0; step < this.rows.length; step += 1) {
      next = (next + offset + this.rows.length) % this.rows.length;
      if (this.rows[next].kind !== "header" && this.rows[next].kind !== "notice") break;
    }
    this.selection = next;
  }

  scroll(delta: number): void {
    this.offset = Math.max(0, this.offset + delta);
  }

  /** Put the keyboard selection on the workspace's selected session. */
  syncSelection(): void {
    const index = this.rows.findIndex((entry) =>
      entry.kind === "session" && entry.session.id === this.workspace.selectedSessionID
    );
    if (index >= 0) this.selection = index;
  }
}
