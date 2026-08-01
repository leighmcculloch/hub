/**
 * The left sidebar: one row per open session, then the VMs on the account that
 * aren't open yet. Clicking a session selects it; clicking an unopened VM
 * connects to it.
 *
 * The rows can be grouped — by VM provider (which host an instance is on), by
 * GitHub repo (inferred from the session's working directory), or by state
 * (connecting, waiting, output ready, disconnected). Grouping is what keeps a
 * growing sidebar legible: with two providers configured the first question is
 * "which account is this?", and grouping by provider answers it without a row
 * having to carry a badge. `Alt+G`-while-in-the-pane (plain `g`) cycles the
 * grouping, and the footer control does the same for the mouse.
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
import type { RemoteVMRecord, VMProviderID } from "../providers/types.ts";
import type { TerminalSession } from "../model/terminal-session.ts";
import { providerBadge, providerLabel } from "../model/provider-label.ts";
import type { SidebarGrouping } from "../config/layout-store.ts";

type SidebarRow =
  | { kind: "header"; title: string; busy: boolean }
  | { kind: "session"; session: TerminalSession }
  | { kind: "vm"; vm: RemoteVMRecord }
  /** Why the list below is short — a failed listing, not an empty account. */
  | { kind: "notice"; text: string };

/** The stops Tab visits inside this pane, in order. */
const PARTS = ["list", "group", "new"] as const;
type Part = typeof PARTS[number];

/** The label shown for each grouping mode, and the order `g` cycles through. */
const GROUPINGS: Array<{ mode: SidebarGrouping; label: string }> = [
  { mode: "provider", label: "Provider" },
  { mode: "repo", label: "Repo" },
  { mode: "state", label: "State" },
  { mode: "none", label: "None" },
];

function groupingLabel(mode: SidebarGrouping): string {
  return GROUPINGS.find((entry) => entry.mode === mode)?.label ?? "None";
}

export { groupingLabel };

/**
 * A sortable key for a group, paired with the heading to show above it. Numbers
 * first so the ordering is stable and predictable across renders.
 */
interface Group {
  /** The sort order: lower comes first. */
  order: number;
  /** The section heading text, uppercase by the widget. */
  title: string;
}

/** The repo name a session is "in", inferred from its working directory. */
function repoOf(session: TerminalSession): string {
  const path = session.workingDirectory;
  if (!path) return "";
  // `/home/user/owner/repo` → `owner/repo` when there's a parent segment, else
  // the last segment alone. A bare `~` or `/` is no repo.
  const segments = path.replace(/\/+$/, "").split("/");
  if (segments.length < 2) return "";
  const last = segments[segments.length - 1];
  const parent = segments[segments.length - 2];
  // Heuristic: a `.git`-shaped pair like `owner/repo`. Without the repo list
  // being carried on the session, the cwd is the honest signal we have, and
  // `owner/repo` reads better than just `repo` when two sessions share a name.
  if (parent && parent !== "home" && parent !== "Users" && !parent.startsWith(".")) {
    return `${parent}/${last}`;
  }
  return last;
}

/** The human label for a session's lifecycle state. */
function stateLabel(session: TerminalSession): string {
  if (session.isDisconnected) return "Disconnected";
  if (session.isConnecting) return "Connecting";
  // `live` now: an agent that has printed something you haven't seen is "output
  // ready", otherwise it's waiting for input.
  if (session.hasUnseenOutput) return "Output ready";
  return "Waiting";
}

/** The human label for an unopened VM's state. */
function vmStateLabel(vm: RemoteVMRecord): string {
  return vm.status === "running" ? "Running" : "Stopped";
}

export class SessionSidebar {
  /** The row the keyboard is on, as an index into the flattened list. */
  selection = 0;
  /** Which control inside the pane has the keyboard. */
  part: Part = "list";
  /** How the rows are grouped, persisted with the rest of the layout. */
  grouping: SidebarGrouping = "provider";
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

  /** Move to the next grouping mode, wrapping. */
  cycleGrouping(): void {
    const modes = GROUPINGS.map((entry) => entry.mode);
    const current = modes.indexOf(this.grouping);
    this.grouping = modes[(current + 1 + modes.length) % modes.length];
  }

  render(rect: Rect, hits: HitMap, focused: boolean): string[] {
    const width = rect.width;
    this.rows = this.buildRows();

    const lines: string[] = [];
    // The list, the grouping toggle, the rule, and the new-session footer.
    const footerHeight = 3;
    const listHeight = rect.height - footerHeight;

    if (this.rows.length === 0) {
      // Nothing here and no token is a setup step, not an empty list.
      const configured = this.workspace.hasAnyToken;
      lines.push(
        ...placeholder(
          width,
          Math.max(0, listHeight),
          configured ? "No sessions" : "No token yet",
          configured ? "Start one on a fresh VM with Alt+N." : "Add one in Settings, with Alt+,",
          focused ? Color.paneFocus : undefined,
        ),
      );
    } else {
      this.selection = Math.min(Math.max(0, this.selection), this.rows.length - 1);
      this.offset = scrollToShow(this.offset, this.selection, listHeight, this.rows.length);
      const bar = scrollbar(this.offset, listHeight, this.rows.length);
      // The pane that has the keyboard lifts its empty rows and headings onto a
      // focus tint, so where the focus landed is legible without colouring the
      // content rows themselves (the selection bar and badges keep their own
      // colours).
      const paneBg = focused ? Color.paneFocus : undefined;
      for (let index = 0; index < listHeight; index += 1) {
        const entry = this.rows[this.offset + index];
        if (!entry) {
          lines.push(fit("", width, { bg: paneBg }));
          continue;
        }
        if (entry.kind === "header") {
          lines.push(sectionHeader(entry.title, width, entry.busy ? "◌" : "", paneBg));
          continue;
        }
        if (entry.kind === "notice") {
          // No hit region: there is nothing to click, and tinting it under the
          // pointer would promise otherwise.
          lines.push(
            fit(
              ` ${styled("!", { fg: Color.orange, bg: paneBg })} ` +
                styled(elideMiddle(entry.text, Math.max(6, width - 4)), {
                  fg: Color.dim,
                  bg: paneBg,
                }),
              width,
              { bg: paneBg },
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

    // The grouping toggle. `g` cycles it from the keyboard; the mouse clicks
    // the row, which is tinted on hover and when the pane has the keyboard.
    hits.add({ x: rect.x, y: rect.y + rect.height - 3, width, height: 1 }, "sidebar.group");
    const groupFocused = focused && this.part === "group";
    const groupBg = groupFocused
      ? Color.selection
      : this.hovered === "sidebar.group"
      ? Color.hover
      : focused
      ? Color.paneFocus
      : undefined;
    {
      const label = styled(`Group: ${groupingLabel(this.grouping)}`, {
        fg: Color.accent,
        bg: groupBg,
      });
      const hint = styled("g", { fg: Color.dimmer, bg: groupBg });
      const used = displayWidth(label) + 1 + displayWidth(hint);
      const gap = " ".repeat(Math.max(1, width - used));
      lines.push(fit(` ${label}${gap}${hint}`, width, { bg: groupBg }));
    }

    lines.push(rule(width, { bg: focused ? Color.paneFocus : undefined }));
    hits.add({ x: rect.x, y: rect.y + rect.height - 1, width, height: 1 }, "sidebar.new");
    const newFocused = focused && this.part === "new";
    const background = newFocused
      ? Color.selection
      : this.hovered === "sidebar.new"
      ? Color.hover
      : focused
      ? Color.paneFocus
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
    const sessions = this.workspace.sessions;
    const unopened = this.workspace.unopenedVMs;
    const failures = this.workspace.vmListErrors;

    // `none` keeps the original two-section shape: open sessions first, then
    // the Existing VMs, exactly as before grouping existed.
    if (this.grouping === "none") {
      const rows: SidebarRow[] = [];
      if (sessions.length > 0) {
        rows.push({ kind: "header", title: "Sessions", busy: false });
        for (const session of sessions) rows.push({ kind: "session", session });
      }
      if (unopened.length > 0 || this.workspace.loadingVMs || failures.length > 0) {
        rows.push({ kind: "header", title: "Existing", busy: this.workspace.loadingVMs });
        for (const failure of failures) {
          rows.push({
            kind: "notice",
            text: `${providerLabel(failure.provider)}: ${failure.reason}`,
          });
        }
        for (const vm of unopened) rows.push({ kind: "vm", vm });
      }
      return rows;
    }

    // Grouped: each group is a header followed by its sessions and VMs, so a
    // scan down the list reads "here's the bucket, here's what's in it". Open
    // sessions and reopenable VMs share a group when they share the key — the
    // point of grouping by provider is seeing, in one place, everything on
    // exe.dev whether it's open yet or not.
    type Item = { kind: "session"; session: TerminalSession } | { kind: "vm"; vm: RemoteVMRecord };
    const items: Item[] = [
      ...sessions.map((session) => ({ kind: "session", session }) as Item),
      ...unopened.map((vm) => ({ kind: "vm", vm }) as Item),
    ];

    const groups = new Map<string, Group>();
    const keyFor = (item: Item): string => {
      if (this.grouping === "provider") {
        if (item.kind === "session") {
          if (item.session.destination === null) return "local";
          // A session whose provider is somehow absent reads as unknown rather
          // than throwing, so a partial stub or a half-built session still
          // renders.
          return item.session.provider?.id ?? "unknown";
        }
        return item.vm.provider;
      }
      if (this.grouping === "repo") {
        if (item.kind === "session") return `repo:${repoOf(item.session) || "none"}`;
        // An unopened VM has no working directory, so its repo isn't known.
        return "repo:none";
      }
      // state
      if (item.kind === "session") return `state:${stateLabel(item.session)}`;
      return `state:${vmStateLabel(item.vm)}`;
    };
    const groupFor = (key: string): Group => {
      const cached = groups.get(key);
      if (cached) return cached;
      const group = this.groupFor(key);
      groups.set(key, group);
      return group;
    };

    // Sort items by group order, then by the group key so identical keys land
    // together (two sessions in the same repo, say), then keep sessions ahead
    // of VMs within a group — an open session is further along than a VM that's
    // never been opened.
    items.sort((left, right) => {
      const leftKey = keyFor(left);
      const rightKey = keyFor(right);
      const lg = groupFor(leftKey);
      const rg = groupFor(rightKey);
      if (lg.order !== rg.order) return lg.order - rg.order;
      if (leftKey !== rightKey) return leftKey < rightKey ? -1 : 1;
      if (left.kind !== right.kind) return left.kind === "session" ? -1 : 1;
      return 0;
    });

    const rows: SidebarRow[] = [];
    // Failed listings sit under their provider's group when grouping by it, so
    // the reason is beside the VMs it affects; otherwise they keep their own
    // spot up top, the way `none` shows them under Existing.
    const placedFailures = new Set<VMProviderID>();
    const failuresForGroup = (key: string): Array<{ provider: VMProviderID; reason: string }> => {
      if (this.grouping !== "provider") return [];
      const id = key as VMProviderID;
      const matching = failures.filter((failure) => failure.provider === id);
      matching.forEach((failure) => placedFailures.add(failure.provider));
      return matching;
    };

    let currentKey: string | null = null;
    for (const item of items) {
      const key = keyFor(item);
      if (key !== currentKey) {
        currentKey = key;
        const group = groupFor(key);
        rows.push({ kind: "header", title: group.title, busy: false });
        for (const failure of failuresForGroup(key)) {
          rows.push({
            kind: "notice",
            text: `${providerLabel(failure.provider)}: ${failure.reason}`,
          });
        }
      }
      if (item.kind === "session") rows.push({ kind: "session", session: item.session });
      else rows.push({ kind: "vm", vm: item.vm });
    }

    // Failures whose provider group had no items at all — or failures when the
    // grouping isn't by provider — still need to be seen. Put them under an
    // "Existing" header at the bottom so the reason isn't lost.
    const leftover = this.grouping === "provider"
      ? failures.filter((failure) => !placedFailures.has(failure.provider))
      : failures;
    if (leftover.length > 0) {
      rows.push({ kind: "header", title: "Existing", busy: this.workspace.loadingVMs });
      for (const failure of leftover) {
        rows.push({
          kind: "notice",
          text: `${providerLabel(failure.provider)}: ${failure.reason}`,
        });
      }
    } else if (this.workspace.loadingVMs && items.length === 0) {
      // Nothing listed yet but a load is in flight: keep the spinner visible.
      rows.push({ kind: "header", title: "Existing", busy: true });
    }

    return rows;
  }

  /**
   * The order and heading for a group key. Provider groups come in a fixed,
   * familiar order (default provider first); repo and state groups sort
   * alphabetically by their label, with a couple of pinned sentinels.
   */
  private groupFor(key: string): Group {
    if (this.grouping === "provider") {
      // Local sessions first — they're the odd ones out, not on any host —
      // then the configured providers in the workspace's preferred order, then
      // any provider that has VMs but no token (unusual, but possible if a
      // token was cleared while VMs were listed).
      if (key === "local") return { order: 0, title: "Local" };
      const preferred = this.workspace.configuredProviders;
      const index = preferred.indexOf(key as VMProviderID);
      if (index >= 0) return { order: 10 + index, title: providerLabel(key as VMProviderID) };
      return { order: 20, title: providerLabel(key as VMProviderID) };
    }
    if (this.grouping === "repo") {
      const name = key.slice("repo:".length);
      if (name === "none") return { order: 100, title: "No repo" };
      // Alphabetical by repo name; the `repo:` prefix keeps the sort stable.
      return { order: name.toLowerCase().charCodeAt(0), title: name };
    }
    // state
    const name = key.slice("state:".length);
    const order = ["Connecting", "Waiting", "Output ready", "Disconnected", "Running", "Stopped"]
      .indexOf(name);
    return { order: order >= 0 ? order : 50, title: name };
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
      // When the rows are grouped by provider the host is the heading, so the
      // per-row badge would just repeat it; otherwise a session on a non-local
      // host carries a badge when both providers are configured.
      const showBadge = this.grouping !== "provider" &&
        session.destination !== null &&
        this.workspace.configuredProviders.length > 1;
      const badge = showBadge ? providerBadge(session.provider.id) : "";
      const room = nameWidth - (badge ? badge.length + 1 : 0);
      const elided = elideMiddle(session.displayName, room);
      // An agent working in a session you aren't looking at is the reason to
      // keep several open, so a session that has printed something since you
      // last saw it carries a dot on the right until you go back to it.
      if (!session.hasUnseenOutput || this.isSelected(entry)) {
        return badge
          ? `${icon} ${styled(elided, style)}${
            " ".repeat(Math.max(1, room - displayWidth(elided) + 1))
          }${styled(badge, { fg: Color.dimmer })}`
          : `${icon} ${styled(name, style)}`;
      }
      const gap = " ".repeat(Math.max(1, nameWidth - displayWidth(name) + 1));
      return `${icon} ${styled(name, style)}${gap}${styled("●", { fg: Color.orange })}`;
    }
    if (entry.kind === "vm") {
      const running = entry.vm.status === "running";
      const dot = styled("•", { fg: running ? Color.green : Color.dimmer });
      // Which account a VM is on only matters — and only fits — when there is
      // more than one account in the list, and when the host isn't already the
      // group heading above it.
      const showBadge = this.grouping !== "provider" &&
        this.workspace.configuredProviders.length > 1;
      const badge = showBadge ? providerBadge(entry.vm.provider) : "";
      const nameWidth = Math.max(6, width - 4 - badge.length);
      const name = elideMiddle(entry.vm.name, nameWidth);
      const gap = badge ? " ".repeat(Math.max(1, nameWidth - displayWidth(name) + 1)) : "";
      return `${dot} ${styled(name, { fg: Color.dim })}${gap}` +
        (badge ? styled(badge, { fg: Color.dimmer }) : "");
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
  key(name: string): "activate" | "delete" | "group" | "handled" | "ignored" {
    if (this.part === "new") {
      return name === "enter" || name === "space" ? "activate" : "ignored";
    }
    if (this.part === "group") {
      // Enter or `g` cycles the grouping from the toggle row; anything else is
      // ignored so the focus ring's Tab still leaves the pane.
      if (name === "enter" || name === "space" || name === "g") return "group";
      return "ignored";
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
      case "g":
        // Plain `g` cycles the grouping while the list has the keyboard, the
        // same thing the footer toggle does — so the mouse and the keyboard
        // agree on one key for it.
        return "group";
      default:
        return "ignored";
    }
  }

  /** True when the New Session button is what Enter would press. */
  get onNewButton(): boolean {
    return this.part === "new";
  }

  /** True when the grouping toggle is what Enter would press. */
  get onGroupToggle(): boolean {
    return this.part === "group";
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
