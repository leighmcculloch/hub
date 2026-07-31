/**
 * One session: a VM (or the local machine) whose tmux session the app drives
 * itself over tmux's control protocol.
 *
 * There is no tmux *on screen* — the app is the tmux client. Every pane in the
 * session appears as a tab above the terminal, so tmux's windows and splits
 * arrive as tabs and its status bar and prefix key never come into it. Panes
 * keep running whichever tab is showing, and a dropped connection reattaches to
 * the same panes.
 *
 * The screen itself comes from `capture-pane -e`: tmux already maintains the
 * pane's state, so the app renders what tmux says is on it rather than carrying
 * a terminal emulator of its own.
 */

import { TmuxClient } from "../tmux/client.ts";
import {
  capturePaneCommand,
  cursorCommand,
  killPaneCommand,
  listPanesCommand,
  newWindowCommand,
  paneTitle,
  parseCursor,
  parsePanes,
  refreshClientCommand,
  selectPaneCommands,
  sendKeysCommands,
  type TmuxEvent,
  type TmuxPane,
} from "../tmux/control.ts";
import { LocalTransport } from "../providers/local-transport.ts";
import type { RemoteTransport, VMProvider } from "../providers/types.ts";

/** How long output is allowed to pile up before the pane is re-captured. */
const CAPTURE_DEBOUNCE_MS = 16;

export interface TerminalTab {
  /** tmux's pane id, e.g. `%3`. */
  paneID: string;
  /** The tmux window the pane belongs to, e.g. `@1`. */
  windowID: string | null;
  title: string;
  /** The pane's visible screen, one styled string per row, from capture-pane. */
  screen: string[];
  cursor: { x: number; y: number; visible: boolean };
}

export function tabDisplayName(tab: TerminalTab): string {
  return tab.title || "Terminal";
}

type PendingReply =
  | { kind: "panes" }
  | { kind: "capture"; paneID: string }
  | { kind: "cursor"; paneID: string }
  | { kind: "ignored" };

export class TerminalSession {
  readonly id = crypto.randomUUID();

  title: string;
  /** The VM this session runs on, if any. Needed to delete it. */
  vmName: string | null;
  /** The VM's public web URL — what the browser shortcut opens. */
  webURL: string | null;
  /**
   * The transport handle for VM-backed sessions (null for the local shell).
   *
   * Not fixed for the session's lifetime: a VM that renames itself takes its
   * hostname with it. See `adoptVMName`.
   */
  destination: string | null;
  readonly provider: VMProvider;
  /**
   * True for a session created without a name, whose VM was armed to name
   * itself from the agent's first prompt. Set once, at creation.
   */
  readonly autoNameArmed: boolean;

  /** The current working directory, as tmux reports it for the active pane. */
  workingDirectory: string | null = null;
  /** True once the session's process has exited. */
  isDisconnected = false;
  /**
   * What the transport or tmux said on the way out. Without it a VM that has
   * been deleted, and a tmux that failed to install, look the same.
   */
  disconnectReason: string | null = null;

  /** One tab per tmux pane, in tmux's own window and pane order. */
  tabs: TerminalTab[] = [];
  selectedTabID: string | null = null;

  /** Replaced when the VM is renamed, so a reconnect dials a host that exists. */
  private bootstrap: string;
  private client: TmuxClient | null = null;
  /**
   * What each in-flight command's reply is for, oldest first. tmux answers
   * commands in order and says nothing about which reply is which, so this
   * queue is what pairs them up.
   */
  private pendingReplies: PendingReply[] = [];
  /** Set while a pane listing is queued, so a burst costs one `list-panes`. */
  private refreshQueued = false;
  private captureTimer: ReturnType<typeof setTimeout> | null = null;
  /** The size last reported to tmux; an unchanged layout must not resend it. */
  private reportedSize: { cols: number; rows: number } | null = null;
  /** The pane tmux last reported as active, so a real focus change is followed. */
  private lastActivePaneID: string | null = null;

  constructor(
    options: {
      title: string;
      provider: VMProvider;
      destination: string | null;
      bootstrap: string;
      vmName?: string | null;
      webURL?: string | null;
      autoNameArmed?: boolean;
    },
    private onChange: () => void,
  ) {
    this.title = options.title;
    this.provider = options.provider;
    this.destination = options.destination;
    this.bootstrap = options.bootstrap;
    this.vmName = options.vmName ?? null;
    this.autoNameArmed = options.autoNameArmed ?? false;
    this.webURL = options.webURL ??
      (options.destination ? options.provider.webURLForDestination(options.destination) : null);
  }

  /** A short label for the session list. */
  get displayName(): string {
    if (this.title) return this.title;
    if (this.workingDirectory) return this.workingDirectory.split("/").pop() ?? "Terminal";
    return "Terminal";
  }

  get selectedTab(): TerminalTab | null {
    return this.tabs.find((tab) => tab.paneID === this.selectedTabID) ?? this.tabs[0] ?? null;
  }

  /**
   * The transport this session's commands run over — the provider's for a VM,
   * the local shell's for a local session. The diff sidebar and the rename poll
   * ride on this, so their work shares the terminal's own connection.
   */
  get transport(): RemoteTransport {
    if (this.destination === null) return new LocalTransport();
    return this.provider.transportFor(this.destination);
  }

  // MARK: - Lifecycle

  start(): void {
    this.isDisconnected = false;
    this.disconnectReason = null;
    this.pendingReplies = [];
    this.reportedSize = null;
    this.lastActivePaneID = null;
    // Pane tabs are rebuilt from the pane listing rather than reused: on a
    // reconnect the panes have moved on without us, and each tab's screen is
    // restored as it reappears.
    this.tabs = [];
    this.selectedTabID = null;

    const client = new TmuxClient(this.transport, this.bootstrap, {
      onEvents: (events) => {
        for (const event of events) this.handle(event);
        this.onChange();
      },
      onExit: (message) => {
        this.disconnected(message);
        this.onChange();
      },
    });
    this.client = client;
    client.start();
    this.send(listPanesCommand(), { kind: "panes" });
  }

  /** Re-run the launch command, recovering a dropped connection. */
  reconnect(): void {
    if (!this.isDisconnected) return;
    this.start();
  }

  stop(): void {
    if (this.captureTimer !== null) clearTimeout(this.captureTimer);
    this.captureTimer = null;
    this.client?.stop();
    this.client = null;
  }

  /**
   * Follow the VM's own name. A session created without one is named by the VM
   * itself, from the agent's first prompt, and the transport handle moves with
   * the name.
   *
   * The live connection is left running: it is already established, and tmux is
   * still on the other end of it. Only what a *future* connection needs
   * changes — along with the title, when the title was the name being replaced
   * rather than one the user chose.
   *
   * Returns whether anything changed, so the workspace persists a real rename
   * and not every poll.
   */
  adoptVMName(newName: string): boolean {
    if (this.destination === null || !newName || newName === this.vmName) return false;
    const previous = this.vmName;
    this.vmName = newName;
    this.destination = this.provider.destinationForVMName(newName);
    this.webURL = this.provider.webURLForDestination(this.destination);
    if (!this.title || this.title === previous) this.title = newName;
    return true;
  }

  // MARK: - Tabs

  /** Open another tmux window. The tab appears when tmux announces the pane. */
  newTab(): void {
    this.send(newWindowCommand());
  }

  /**
   * Kill the pane behind a tab. The tab goes when tmux reports the pane gone, so
   * a refused kill leaves the tab where it was.
   */
  closeTab(tab: TerminalTab): void {
    this.send(killPaneCommand(tab.paneID));
  }

  selectTab(paneID: string): void {
    if (this.selectedTabID === paneID) return;
    this.selectedTabID = paneID;
    this.focusSelectedPane();
  }

  selectAdjacentTab(offset: number): void {
    if (this.tabs.length === 0) return;
    const current = this.tabs.findIndex((tab) => tab.paneID === this.selectedTabID);
    const from = current === -1 ? (offset >= 0 ? -1 : 0) : current;
    const next = (from + offset + this.tabs.length * 2) % this.tabs.length;
    this.selectTab(this.tabs[next].paneID);
  }

  // MARK: - Input and sizing

  /** Forward raw keystrokes to the selected pane, byte for byte. */
  sendKeys(bytes: Uint8Array): void {
    const tab = this.selectedTab;
    if (!tab) return;
    for (const command of sendKeysCommands(tab.paneID, bytes)) this.send(command);
    // Typing moves the cursor and redraws the pane without any notification, so
    // a capture is scheduled off the keystroke rather than waiting for output.
    this.scheduleCapture();
  }

  /**
   * tmux sizes the session's windows to fit its client, and a control client has
   * no size at all until it says so.
   */
  reportSize(cols: number, rows: number): void {
    if (this.client === null || cols <= 0 || rows <= 0) return;
    if (this.reportedSize?.cols === cols && this.reportedSize?.rows === rows) return;
    this.reportedSize = { cols, rows };
    this.send(refreshClientCommand(cols, rows));
    this.scheduleCapture();
  }

  // MARK: - tmux plumbing

  private send(command: string, expecting: PendingReply = { kind: "ignored" }): void {
    if (this.client === null) return;
    this.pendingReplies.push(expecting);
    this.client.send(command);
  }

  private handle(event: TmuxEvent): void {
    switch (event.type) {
      case "output":
        // The bytes themselves aren't rendered — tmux's own screen is, via
        // capture-pane — so output is only a signal that the pane changed.
        if (event.pane === this.selectedTabID) this.scheduleCapture();
        break;
      case "paneListChanged":
        this.scheduleRefresh();
        break;
      case "reply":
        this.handleReply(event.reply.lines, event.reply.isError);
        break;
      case "exit":
        this.client?.stop();
        this.client = null;
        this.disconnected(event.reason);
        break;
    }
  }

  private handleReply(lines: string[], isError: boolean): void {
    const expectation = this.pendingReplies.shift() ?? { kind: "ignored" };
    // An error is tmux refusing a command — a pane that died first, say. There
    // is nothing to apply, and its notification will say what is true.
    if (isError) return;
    switch (expectation.kind) {
      case "panes":
        this.applyPanes(parsePanes(lines));
        break;
      case "capture": {
        const tab = this.tabs.find((entry) => entry.paneID === expectation.paneID);
        if (tab) tab.screen = lines;
        break;
      }
      case "cursor": {
        const tab = this.tabs.find((entry) => entry.paneID === expectation.paneID);
        const cursor = parseCursor(lines);
        if (tab && cursor) tab.cursor = cursor;
        break;
      }
      case "ignored":
        break;
    }
  }

  /**
   * Ask for the pane list once per turn: one tmux action emits several
   * notifications, and they all mean the same thing here.
   */
  private scheduleRefresh(): void {
    if (this.refreshQueued) return;
    this.refreshQueued = true;
    queueMicrotask(() => {
      this.refreshQueued = false;
      if (this.client === null) return;
      this.send(listPanesCommand(), { kind: "panes" });
    });
  }

  /**
   * Re-read the visible pane, coalescing a burst of output into one round trip.
   * Only the pane on screen is captured: a background pane's contents aren't
   * drawn, and it is re-captured the moment it is selected.
   */
  scheduleCapture(): void {
    if (this.captureTimer !== null) return;
    this.captureTimer = setTimeout(() => {
      this.captureTimer = null;
      this.captureSelected();
      this.onChange();
    }, CAPTURE_DEBOUNCE_MS);
  }

  private captureSelected(): void {
    const tab = this.selectedTab;
    if (!tab || this.client === null) return;
    this.send(capturePaneCommand(tab.paneID), { kind: "capture", paneID: tab.paneID });
    this.send(cursorCommand(tab.paneID), { kind: "cursor", paneID: tab.paneID });
  }

  /**
   * Reconcile the tabs with what tmux says exists: new panes become tabs, closed
   * ones drop out, and the order follows tmux's windows and panes rather than
   * the order the app happened to hear about them.
   */
  private applyPanes(panes: TmuxPane[]): void {
    const hadPanes = this.tabs.length > 0;
    const existing = new Map(this.tabs.map((tab) => [tab.paneID, tab]));
    const ordered: TerminalTab[] = [];

    const sorted = [...panes].sort((left, right) =>
      left.windowIndex !== right.windowIndex
        ? left.windowIndex - right.windowIndex
        : left.index - right.index
    );
    for (const pane of sorted) {
      const tab = existing.get(pane.id) ?? {
        paneID: pane.id,
        windowID: pane.windowID,
        title: "",
        screen: [],
        cursor: { x: 0, y: 0, visible: true },
      };
      tab.title = paneTitle(pane);
      tab.windowID = pane.windowID;
      tab.cursor = { x: pane.cursorX, y: pane.cursorY, visible: tab.cursor.visible };
      ordered.push(tab);
    }
    this.tabs = ordered;

    const active = panes.find((pane) => pane.isActive)?.id ?? null;
    if (!this.tabs.some((tab) => tab.paneID === this.selectedTabID)) {
      // The selected tab dropped out of the listing — its pane was closed, or a
      // reconnect is rebuilding the panes — so fall in behind tmux's active
      // pane.
      this.selectedTabID = this.tabs.find((tab) => tab.paneID === active)?.paneID ??
        this.tabs[0]?.paneID ?? null;
      this.lastActivePaneID = active;
      this.scheduleCapture();
    } else if (active && hadPanes && active !== this.lastActivePaneID) {
      // tmux moved to a different active pane — a new window, a split, or a
      // `select-window` run on the VM — so follow it: the newly current tab
      // takes focus instead of opening in the background.
      if (this.tabs.some((tab) => tab.paneID === active)) {
        this.selectedTabID = active;
        this.lastActivePaneID = active;
        this.scheduleCapture();
      }
    }

    // tmux consumes OSC 7, so the working directory can only come from here.
    const selected = this.selectedTabID;
    const path = panes.find((pane) => pane.id === selected)?.currentPath;
    if (path) this.workingDirectory = path;
  }

  /**
   * Point tmux at the pane the user just switched to, so another attached
   * client — and anything that acts on the "current" pane — agrees with what's
   * on screen.
   */
  private focusSelectedPane(): void {
    const tab = this.selectedTab;
    if (!tab) return;
    // A tab built from output alone doesn't know its window yet; the next pane
    // listing fills that in.
    if (tab.windowID) {
      for (const command of selectPaneCommands(tab.windowID, tab.paneID)) this.send(command);
    }
    this.scheduleCapture();
  }

  private disconnected(reason: string | null): void {
    this.client = null;
    this.pendingReplies = [];
    this.isDisconnected = true;
    this.disconnectReason = reason;
  }
}
