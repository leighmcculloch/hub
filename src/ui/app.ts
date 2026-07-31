/**
 * The workspace layout and the event loop: sessions on the left, the active
 * terminal in the middle, and the worktree diff on the right. Both sidebars are
 * resizable (drag the divider) and hideable (Alt+S / Alt+R).
 *
 * Every shortcut is Alt-based so that plain keystrokes — including Ctrl chords,
 * arrows and Tab — reach the program running in the terminal pane untouched.
 */

import { Color, displayWidth, fit, overlay, styled } from "../tui/ansi.ts";
import { Screen } from "../tui/screen.ts";
import { InputDecoder, type InputEvent, type KeyEvent, type MouseEvent } from "../tui/input.ts";
import { HitMap, type Rect } from "../tui/widgets.ts";
import { AppConfig } from "../config/app-config.ts";
import { Workspace } from "../model/workspace.ts";
import { openInBrowser } from "../providers/process.ts";
import { SessionSidebar } from "./session-sidebar.ts";
import { TerminalPane } from "./terminal-pane.ts";
import { DiffSidebar } from "./diff-sidebar.ts";
import { NewSessionModal } from "./new-session-modal.ts";
import { SettingsModal } from "./settings-modal.ts";
import { ConfirmModal, HelpModal } from "./overlays.ts";
import { SelectPopup } from "./select-popup.ts";
import { isWorktree, shortRepoLabel } from "../model/repo-label.ts";

type Focus = "sessions" | "terminal" | "diff";

const MIN_SIDEBAR = 18;
const MIN_DIFF = 30;
const MIN_TERMINAL = 20;
/** How long a status message stays on the bar before it fades out. */
const STATUS_MS = 4000;

export class App {
  private screen = new Screen();
  private decoder = new InputDecoder();
  private hits = new HitMap();

  private config = AppConfig.load();
  private workspace: Workspace;
  private sessions: SessionSidebar;
  private terminal = new TerminalPane();
  private diff: DiffSidebar;

  private newSession: NewSessionModal | null = null;
  private settings: SettingsModal | null = null;
  private confirm: ConfirmModal | null = null;
  private help = false;
  /** The list a dropdown opened; drawn over whatever opened it. */
  private popup: SelectPopup | null = null;
  /** The hit region under the pointer, so anything clickable can tint. */
  private hovered: string | null = null;

  private focus: Focus = "terminal";
  private sidebarWidth = 26;
  private diffWidth = 46;
  private dragging: "left" | "right" | "scopeSplit" | "filesSplit" | null = null;
  private dragOrigin = 0;
  private dragBase = 0;

  private status = "";
  private statusUntil = 0;
  private renderQueued = false;
  private running = true;
  /** The pane rect tmux is sized to, so a resize is reported once. */
  private terminalContent: Rect = { x: 0, y: 0, width: 0, height: 0 };

  constructor() {
    this.workspace = new Workspace(this.config, () => this.requestRender());
    this.sessions = new SessionSidebar(this.workspace);
    this.diff = new DiffSidebar(() => this.requestRender());
  }

  async run(): Promise<void> {
    this.screen.start();
    this.installSignalHandlers();

    // Populate the sidebar with existing VMs, then restore the tabs that were
    // open when the app last quit — after the VM list, so tabs whose VM is gone
    // are dropped.
    void this.workspace.loadGitHubUser();
    await this.workspace.loadAvailableVMs();
    this.workspace.restoreSessions();
    this.workspace.startRenamePolling();
    this.requestRender();

    try {
      for await (const chunk of Deno.stdin.readable) {
        if (!this.running) break;
        for (const event of this.decoder.feed(chunk)) {
          await this.handle(event);
        }
        this.requestRender();
      }
    } finally {
      this.shutdown();
    }
  }

  private shutdown(): void {
    this.running = false;
    this.diff.stop();
    this.workspace.shutdown();
    this.screen.stop();
  }

  private installSignalHandlers(): void {
    const resize = () => {
      if (this.screen.measure()) this.requestRender();
    };
    try {
      Deno.addSignalListener("SIGWINCH", resize);
    } catch {
      // Not available on this platform; the render loop re-measures anyway.
    }
    for (const signal of ["SIGINT", "SIGTERM"] as const) {
      try {
        Deno.addSignalListener(signal, () => this.quit());
      } catch {
        // Same.
      }
    }
  }

  private quit(): void {
    this.shutdown();
    Deno.exit(0);
  }

  // MARK: - Rendering

  private requestRender(): void {
    if (this.renderQueued || !this.running) return;
    this.renderQueued = true;
    // Coalesced to one frame per turn of the event loop: a busy pane produces
    // many events per read, and they all describe the same next frame.
    queueMicrotask(() => {
      this.renderQueued = false;
      this.render();
    });
  }

  private render(): void {
    this.screen.measure();
    const cols = this.screen.cols;
    const rows = this.screen.rows;
    this.hits.clear();

    const contentHeight = rows - 1;
    const layout = this.layout(cols, contentHeight);

    this.diff.bind(this.workspace.selectedSession);

    const left = layout.left
      ? this.sessions.render(layout.left, this.hits, this.focus === "sessions")
      : [];
    const right = layout.right
      ? this.diff.render(layout.right, this.hits, this.focus === "diff")
      : [];
    const middle = this.terminal.render(
      this.workspace.selectedSession,
      layout.middle,
      this.hits,
      this.focus === "terminal",
    );
    this.terminalContent = middle.content;
    this.reportTerminalSize();

    const composed: string[] = [];
    for (let y = 0; y < contentHeight; y += 1) {
      let row = "";
      if (layout.left) {
        row += left[y] ?? fit("", layout.left.width);
        row += this.divider(layout.left.x + layout.left.width, y, "left");
      }
      row += middle.lines[y] ?? fit("", layout.middle.width);
      if (layout.right) {
        row += this.divider(layout.right.x - 1, y, "right");
        row += right[y] ?? fit("", layout.right.width);
      }
      composed.push(fit(row, cols));
    }
    composed.push(this.statusBar(cols));

    const overlays = this.renderOverlay(cols, rows);
    const cursor = this.cursor(overlays.length > 0);
    this.screen.render(
      overlays.length > 0 ? this.applyOverlays(composed, overlays, cols) : composed,
      cursor,
    );
  }

  /** Where the three panes go, given the terminal's size and what's shown. */
  private layout(cols: number, height: number): {
    left: Rect | null;
    middle: Rect;
    right: Rect | null;
  } {
    // Sidebars give way to the terminal before the terminal gives way to them:
    // a narrow window is still usable with one pane, not with three slivers.
    let leftWidth = this.workspace.showSessionSidebar
      ? Math.max(MIN_SIDEBAR, this.sidebarWidth)
      : 0;
    let rightWidth = this.workspace.showDiffSidebar ? Math.max(MIN_DIFF, this.diffWidth) : 0;
    const dividers = (leftWidth > 0 ? 1 : 0) + (rightWidth > 0 ? 1 : 0);

    if (cols - leftWidth - rightWidth - dividers < MIN_TERMINAL) {
      rightWidth = 0;
    }
    if (cols - leftWidth - (leftWidth > 0 ? 1 : 0) < MIN_TERMINAL) {
      leftWidth = 0;
    }
    const usedDividers = (leftWidth > 0 ? 1 : 0) + (rightWidth > 0 ? 1 : 0);
    const middleWidth = Math.max(1, cols - leftWidth - rightWidth - usedDividers);

    const left = leftWidth > 0 ? { x: 0, y: 0, width: leftWidth, height } : null;
    const middleX = leftWidth + (leftWidth > 0 ? 1 : 0);
    const middle = { x: middleX, y: 0, width: middleWidth, height };
    const right = rightWidth > 0
      ? { x: middleX + middleWidth + 1, y: 0, width: rightWidth, height }
      : null;
    return { left, middle, right };
  }

  /**
   * The draggable rule between two panes. Tinted under the pointer so it reads
   * as a handle rather than a border.
   */
  private divider(x: number, y: number, which: "left" | "right"): string {
    const id = `divider.${which}`;
    this.hits.add({ x, y, width: 1, height: 1 }, id);
    const active = this.hovered === id || this.dragging === which;
    return styled(active ? "┃" : "│", { fg: active ? Color.accent : Color.border });
  }

  private statusBar(cols: number): string {
    const session = this.workspace.selectedSession;
    const name = session ? session.displayName : "no session";
    const where = session?.destination ?? "local";
    const message = Date.now() < this.statusUntil ? this.status : "";

    const left = ` ${styled(name, { fg: Color.fg, bold: true })} ` +
      styled(where, { fg: Color.dimmer });
    const middle = message ? `  ${styled(message, { fg: Color.accent })}` : "";
    const right = styled("Alt+T new · Alt+O browser · F1 keys ", { fg: Color.dimmer });
    const used = displayWidth(left) + displayWidth(middle) + displayWidth(right);
    const gap = Math.max(1, cols - used);
    return fit(`${left}${middle}${" ".repeat(gap)}${right}`, cols, { bg: Color.panel });
  }

  /**
   * Overlays, innermost last: a dropdown opened from a modal is drawn over it,
   * and each layer is registered after the one below so it takes the clicks.
   */
  private renderOverlay(cols: number, rows: number): Array<{ lines: string[]; rect: Rect }> {
    const layers: Array<{ lines: string[]; rect: Rect }> = [];
    if (this.settings) layers.push(this.settings.render(cols, rows, this.hits));
    if (this.newSession) layers.push(this.newSession.render(cols, rows, this.hits));
    if (this.help) layers.push(new HelpModal().render(cols, rows, this.hits));
    if (this.confirm) layers.push(this.confirm.render(cols, rows, this.hits, this.hovered));
    if (this.popup) layers.push(this.popup.render(cols, rows, this.hits));
    return layers;
  }

  private applyOverlays(
    rows: string[],
    overlays: Array<{ lines: string[]; rect: Rect }>,
    cols: number,
  ): string[] {
    const composed = [...rows];
    for (const overlay of overlays) {
      for (let index = 0; index < overlay.lines.length; index += 1) {
        const y = overlay.rect.y + index;
        if (y < 0 || y >= composed.length) continue;
        composed[y] = overlayRow(composed[y], overlay.rect.x, overlay.lines[index], cols);
      }
    }
    return composed;
  }

  /**
   * Where the caret goes: the focused text field of whatever overlay is on top,
   * else the pane's own cursor as tmux reports it.
   *
   * A field that has the keyboard always carries the terminal's real caret, so
   * it blinks where the next character will land — including an empty field
   * that is still showing its hint.
   */
  private cursor(modalOpen: boolean): { x: number; y: number; visible: boolean } {
    const field = this.popup?.cursorPosition() ??
      (this.confirm || this.help ? null : this.settings?.cursorPosition()) ??
      (this.confirm || this.help || this.settings ? null : this.newSession?.cursorPosition());
    if (field) return { x: field.x, y: field.y, visible: true };

    const session = this.workspace.selectedSession;
    const tab = session?.selectedTab;
    if (modalOpen || this.focus !== "terminal" || !tab || !tab.cursor.visible) {
      return { x: 0, y: 0, visible: false };
    }
    const content = this.terminalContent;
    const x = content.x + tab.cursor.x;
    const y = content.y + tab.cursor.y;
    if (x < content.x || x >= content.x + content.width) return { x: 0, y: 0, visible: false };
    if (y < content.y || y >= content.y + content.height) return { x: 0, y: 0, visible: false };
    return { x, y, visible: true };
  }

  private reportTerminalSize(): void {
    const session = this.workspace.selectedSession;
    if (!session) return;
    session.reportSize(this.terminalContent.width, this.terminalContent.height);
  }

  private say(message: string): void {
    this.status = message;
    this.statusUntil = Date.now() + STATUS_MS;
  }

  // MARK: - Events

  private async handle(event: InputEvent): Promise<void> {
    switch (event.type) {
      case "key":
        await this.handleKey(event);
        return;
      case "mouse":
        await this.handleMouse(event);
        return;
      case "paste":
        // A paste belongs to whatever is taking text: the terminal, or the
        // field a modal has focused.
        if (this.newSession || this.settings) {
          for (const character of event.text) {
            await this.handle({
              type: "key",
              name: character === " " ? "space" : character,
              ctrl: false,
              alt: false,
              shift: false,
              bytes: new Uint8Array(),
            });
          }
          return;
        }
        this.workspace.selectedSession?.sendKeys(new TextEncoder().encode(event.text));
        return;
      case "focus":
        // Regaining focus is the moment to notice a VM that dropped while the
        // app was in the background.
        if (event.focused) {
          this.workspace.reconnectDisconnectedSessions();
          void this.workspace.loadAvailableVMs();
        }
        return;
    }
  }

  private async handleKey(event: KeyEvent): Promise<void> {
    // Overlays take the keyboard whole, so a modal's text field can hold
    // characters that would otherwise be shortcuts.
    if (this.popup) {
      if (this.popup.key(event)) this.popup = null;
      return;
    }
    if (this.confirm) {
      if (this.confirm.key(event.name)) this.confirm = null;
      return;
    }
    if (this.help) {
      if (event.name === "escape" || event.name === "f1" || event.name === "q") this.help = false;
      return;
    }
    if (this.settings) {
      if (this.settings.key(event)) this.settings = null;
      return;
    }
    if (this.newSession) {
      if (await this.newSession.key(event)) this.newSession = null;
      return;
    }

    if (event.name === "f1") {
      this.help = true;
      return;
    }
    if (event.alt && await this.globalShortcut(event)) return;

    // Anything else belongs to whatever has focus.
    switch (this.focus) {
      case "terminal":
        this.workspace.selectedSession?.sendKeys(event.bytes);
        return;
      case "sessions":
        this.sessionSidebarKey(event);
        return;
      case "diff":
        if (event.name === "escape") {
          this.focus = "terminal";
          return;
        }
        if (event.name === "tab") {
          this.cycleFocus(event.shift ? -1 : 1);
          return;
        }
        await this.diff.key(event.name, event.shift);
        return;
    }
  }

  /** Returns whether the shortcut was handled. */
  private async globalShortcut(event: KeyEvent): Promise<boolean> {
    const session = this.workspace.selectedSession;
    switch (event.name) {
      case "t":
        this.openNewSession();
        return true;
      case "l":
        this.workspace.newLocalSession();
        return true;
      case "w":
        if (session) this.workspace.closeSession(session);
        return true;
      case "d":
        this.confirmDelete();
        return true;
      case "o":
        await this.openBrowser();
        return true;
      case "s":
        this.workspace.showSessionSidebar = !this.workspace.showSessionSidebar;
        this.screen.invalidate();
        return true;
      case "r":
        this.workspace.showDiffSidebar = !this.workspace.showDiffSidebar;
        this.screen.invalidate();
        return true;
      case "n":
        session?.newTab();
        return true;
      case "k":
        this.workspace.reconnectDisconnectedSessions();
        this.say("Reconnecting…");
        return true;
      case "f":
        this.cycleFocus(1);
        return true;
      case ",":
        this.settings = new SettingsModal(this.config, (popup) => this.openPopup(popup));
        return true;
      case "q":
        this.quit();
        return true;
      case "[":
        this.workspace.selectAdjacentSession(-1);
        this.sessions.syncSelection();
        return true;
      case "]":
        this.workspace.selectAdjacentSession(1);
        this.sessions.syncSelection();
        return true;
      case "left":
        session?.selectAdjacentTab(-1);
        return true;
      case "right":
        session?.selectAdjacentTab(1);
        return true;
      default:
        if (/^[1-9]$/.test(event.name)) {
          this.workspace.selectSessionByShortcut(Number(event.name));
          this.sessions.syncSelection();
          return true;
        }
        return false;
    }
  }

  private sessionSidebarKey(event: KeyEvent): void {
    switch (event.name) {
      case "escape":
        this.focus = "terminal";
        return;
      case "tab":
        this.cycleFocus(event.shift ? -1 : 1);
        return;
      case "up":
        this.sessions.move(-1);
        return;
      case "down":
        this.sessions.move(1);
        return;
      case "enter":
      case "space":
        this.activateSidebarRow(this.sessions.current);
        return;
      case "delete":
      case "backspace":
        this.confirmDeleteRow(this.sessions.current);
        return;
    }
  }

  /**
   * Record what the pointer is over and tell every pane, so hover tinting is
   * decided in one place rather than each component tracking the mouse.
   */
  private setHover(id: string | null): void {
    if (this.hovered === id) return;
    this.hovered = id;
    this.sessions.setHover(id);
    this.diff.setHover(id);
    this.terminal.setHover(id);
    this.newSession?.setHover(id);
    this.settings?.setHover(id);
    this.popup?.setHover(id);
  }

  /** Open a dropdown's list over whatever is on screen. */
  private openPopup(popup: SelectPopup): void {
    this.popup = popup;
    this.requestRender();
  }

  private cycleFocus(step: number): void {
    const order: Focus[] = ["sessions", "terminal", "diff"];
    const available = order.filter((one) =>
      one === "terminal" ||
      (one === "sessions" && this.workspace.showSessionSidebar) ||
      (one === "diff" && this.workspace.showDiffSidebar)
    );
    const current = available.indexOf(this.focus);
    this.focus = available[(current + step + available.length) % available.length];
  }

  private async handleMouse(event: MouseEvent): Promise<void> {
    const region = this.hits.hit(event.x, event.y);

    if (event.kind === "move") {
      if (this.dragging) {
        this.applyDrag(event);
        return;
      }
      this.setHover(region?.id ?? null);
      return;
    }

    if (event.kind === "up") {
      this.dragging = null;
      return;
    }

    if (event.kind === "wheel") {
      this.wheel(region?.id ?? null, event.button * 3);
      return;
    }

    if (event.kind !== "down") return;

    // A modal swallows clicks outside it, so the thing behind can't be driven
    // while something is asking a question.
    if (this.popup) {
      if (region?.id.startsWith("popup.") && this.popup.click(region.id)) this.popup = null;
      return;
    }
    if (this.confirm) {
      if (region?.id === "confirm.accept") {
        this.confirm.key("y");
        this.confirm = null;
      } else if (region?.id === "confirm.cancel") {
        this.confirm = null;
      }
      return;
    }
    if (this.help) {
      this.help = false;
      return;
    }
    if (this.settings) {
      if (region?.id.startsWith("settings.")) this.settings.click(region.id);
      return;
    }
    if (this.newSession) {
      if (region?.id.startsWith("new.")) {
        if (await this.newSession.click(region.id, event.shift)) this.newSession = null;
      }
      return;
    }

    if (!region) return;
    const id = region.id;

    if (id === "divider.left" || id === "divider.right") {
      this.dragging = id === "divider.left" ? "left" : "right";
      this.dragOrigin = event.x;
      this.dragBase = id === "divider.left" ? this.sidebarWidth : this.diffWidth;
      return;
    }
    if (id === "diff.splitScope" || id === "diff.splitFiles") {
      this.dragging = id === "diff.splitScope" ? "scopeSplit" : "filesSplit";
      this.dragOrigin = event.y;
      this.dragBase = 0;
      return;
    }

    if (id.startsWith("sidebar.")) {
      this.focus = "sessions";
      if (id === "sidebar.new") {
        this.openNewSession();
        return;
      }
      const row = this.sessions.rowFor(id);
      this.activateSidebarRow(row);
      return;
    }

    if (id.startsWith("terminal.")) {
      this.focus = "terminal";
      const session = this.workspace.selectedSession;
      if (id === "terminal.newTab") {
        session?.newTab();
        return;
      }
      if (id.startsWith("terminal.tab:")) {
        const tab = session?.tabs[Number(id.slice("terminal.tab:".length))];
        if (tab) session?.selectTab(tab.paneID);
      }
      return;
    }

    if (id.startsWith("diff.")) {
      this.focus = "diff";
      if (id === "diff.repo") {
        this.openRepoPopup();
        return;
      }
      await this.diff.click(id, event.shift);
    }
  }

  /** The repo filter's list: every repo on the VM, plus "All repos". */
  private openRepoPopup(): void {
    const repos = this.diff.repos;
    if (repos.length === 0) return;
    const options = [
      { label: "All repos", detail: `${repos.length} in ~` },
      ...repos.map((repo) => ({
        label: shortRepoLabel(repo),
        detail: isWorktree(repo) ? "worktree" : undefined,
      })),
    ];
    const current = this.diff.selectedRepo === null ? 0 : repos.indexOf(this.diff.selectedRepo) + 1;
    this.openPopup(
      new SelectPopup("Repository", options, Math.max(0, current), (index) => {
        this.diff.selectRepo(index === 0 ? null : repos[index - 1]);
      }),
    );
  }

  private applyDrag(event: MouseEvent): void {
    switch (this.dragging) {
      case "left":
        this.sidebarWidth = Math.max(MIN_SIDEBAR, this.dragBase + (event.x - this.dragOrigin));
        this.screen.invalidate();
        return;
      case "right":
        this.diffWidth = Math.max(MIN_DIFF, this.dragBase - (event.x - this.dragOrigin));
        this.screen.invalidate();
        return;
      case "scopeSplit":
      case "filesSplit": {
        const delta = event.y - this.dragOrigin;
        if (delta === 0) return;
        this.dragOrigin = event.y;
        this.diff.dragSplit(this.dragging === "scopeSplit" ? "scope" : "files", delta);
        return;
      }
      case null:
        return;
    }
  }

  private wheel(id: string | null, delta: number): void {
    if (this.popup) {
      this.popup.scroll(delta);
      return;
    }
    if (this.newSession) {
      this.newSession.scroll(delta);
      return;
    }
    if (this.settings) {
      this.settings.scroll(delta);
      return;
    }
    if (id?.startsWith("sidebar.")) {
      this.sessions.scroll(delta);
      return;
    }
    if (id?.startsWith("diff.")) {
      this.diff.scroll(id, delta);
      return;
    }
    // The terminal's own scrollback belongs to tmux; forwarding the wheel lets
    // whatever is running in the pane decide what scrolling means.
    if (id === "terminal.body") {
      const session = this.workspace.selectedSession;
      const bytes = new TextEncoder().encode(delta < 0 ? "\x1b[A".repeat(3) : "\x1b[B".repeat(3));
      session?.sendKeys(bytes);
    }
  }

  private activateSidebarRow(row: ReturnType<SessionSidebar["rowFor"]>): void {
    if (!row) return;
    if (row.kind === "session") {
      this.workspace.selectSession(row.session.id);
      this.sessions.syncSelection();
      return;
    }
    if (row.kind === "vm") {
      this.workspace.reopen(row.vm);
      this.sessions.syncSelection();
    }
  }

  private confirmDeleteRow(row: ReturnType<SessionSidebar["rowFor"]>): void {
    if (!row) return;
    if (row.kind === "session") {
      const session = row.session;
      if (session.vmName === null) {
        // A local shell has nothing to destroy, so it just closes.
        this.workspace.closeSession(session);
        return;
      }
      this.confirm = new ConfirmModal(
        `Delete VM ${session.vmName}?`,
        "This destroys the VM and its disk. Anything not pushed is lost.",
        "Delete VM",
        () => void this.workspace.deleteSession(session),
      );
      return;
    }
    if (row.kind === "vm") {
      const vm = row.vm;
      this.confirm = new ConfirmModal(
        `Delete VM ${vm.name}?`,
        "This destroys the VM and its disk. Anything not pushed is lost.",
        "Delete VM",
        () => void this.workspace.deleteVM(vm),
      );
    }
  }

  private confirmDelete(): void {
    const session = this.workspace.selectedSession;
    if (!session) return;
    if (session.vmName === null) {
      this.workspace.closeSession(session);
      return;
    }
    this.confirm = new ConfirmModal(
      `Delete VM ${session.vmName}?`,
      "This destroys the VM and its disk. Anything not pushed is lost.",
      "Delete VM",
      () => void this.workspace.deleteSession(session),
    );
  }

  private openNewSession(): void {
    const modal = new NewSessionModal(
      this.workspace,
      this.config,
      this.workspace.makeProvisioner(),
      () => {
        this.newSession = null;
      },
      (popup) => this.openPopup(popup),
    );
    modal.load();
    this.newSession = modal;
  }

  /**
   * The stand-in for the desktop app's embedded browser: rather than rendering
   * a page in the terminal, hand this VM's URL to the real browser.
   */
  private async openBrowser(): Promise<void> {
    const session = this.workspace.selectedSession;
    const url = session?.webURL ?? this.workspace.provider.defaultBrowserURL;
    this.say(`Opening ${url}…`);
    this.requestRender();
    const opened = await openInBrowser(url);
    this.say(opened ? `Opened ${url}` : `Couldn't open ${url}`);
  }
}

/** Write `replacement` over `row` starting at cell `x`. */
function overlayRow(row: string, x: number, replacement: string, total: number): string {
  return overlay(row, x, replacement, total);
}
