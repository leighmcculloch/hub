/**
 * The left sidebar: one row per open session, then the VMs on the account that
 * aren't open yet. Clicking a session selects it; clicking an unopened VM
 * connects to it.
 */

import { Color, elideMiddle, fit, styled } from "../tui/ansi.ts";
import {
  type HitMap,
  placeholder,
  type Rect,
  row as listRow,
  rule,
  scrollbar,
  scrollToShow,
  sectionHeader,
} from "../tui/widgets.ts";
import type { Workspace } from "../model/workspace.ts";
import type { RemoteVMRecord } from "../providers/types.ts";
import type { TerminalSession } from "../model/terminal-session.ts";

type SidebarRow =
  | { kind: "header"; title: string; busy: boolean }
  | { kind: "session"; session: TerminalSession }
  | { kind: "vm"; vm: RemoteVMRecord };

export class SessionSidebar {
  /** The row the keyboard is on, as an index into the flattened list. */
  selection = 0;
  private offset = 0;
  private rows: SidebarRow[] = [];
  private hovered: string | null = null;

  constructor(private workspace: Workspace) {}

  render(rect: Rect, hits: HitMap, focused: boolean): string[] {
    const width = rect.width;
    this.rows = this.buildRows();

    const lines: string[] = [];
    const listHeight = rect.height - 2; // the new-session footer and its rule

    if (this.rows.length === 0) {
      lines.push(
        ...placeholder(width, listHeight, "No sessions", "Start one on a fresh VM with Alt+T."),
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
        const id = `sidebar.row:${this.offset + index}`;
        hits.add({ x: rect.x, y: rect.y + index, width, height: 1 }, id);
        lines.push(
          fit(
            listRow(this.rowText(entry, width - 2), width - 1, {
              selected: this.isSelected(entry),
              hovered: this.hovered === id,
              focused,
            }) + bar[index],
            width,
          ),
        );
      }
    }

    lines.push(rule(width));
    hits.add({ x: rect.x, y: rect.y + rect.height - 1, width, height: 1 }, "sidebar.new");
    lines.push(
      fit(
        ` ${styled("+ New Session", { fg: Color.accent, bold: true })}` +
          `${" ".repeat(Math.max(1, width - 20))}${styled("Alt+T", { fg: Color.dimmer })}`,
        width,
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
    if (unopened.length > 0 || this.workspace.loadingVMs) {
      rows.push({ kind: "header", title: "Existing", busy: this.workspace.loadingVMs });
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
      const icon = session.isDisconnected
        ? styled("!", { fg: Color.orange, bold: true })
        : styled("›", { fg: Color.accent });
      const name = elideMiddle(session.displayName, Math.max(6, width - 4));
      const style = session.isDisconnected ? { fg: Color.dim } : { fg: Color.fg };
      return `${icon} ${styled(name, style)}`;
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

  move(offset: number): void {
    if (this.rows.length === 0) return;
    let next = this.selection;
    // Headers aren't selectable, so keep going in the same direction past them.
    for (let step = 0; step < this.rows.length; step += 1) {
      next = (next + offset + this.rows.length) % this.rows.length;
      if (this.rows[next].kind !== "header") break;
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
