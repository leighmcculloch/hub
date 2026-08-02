/**
 * The workspace layout and the event loop: sessions on the left, the active
 * terminal in the middle, and the worktree diff on the right. Both sidebars are
 * resizable (drag the divider) and hideable (Alt+S / Alt+R).
 *
 * Every shortcut is Alt-based so that plain keystrokes — including Ctrl chords,
 * arrows and Tab — reach the program running in the terminal pane untouched.
 */

import { Color, displayWidth, elideHead, fit, overlay, stripAnsi, styled } from "../tui/ansi.ts";
import { Screen } from "../tui/screen.ts";
import { InputDecoder, type InputEvent, type KeyEvent, type MouseEvent } from "../tui/input.ts";
import { HitMap, type Rect } from "../tui/widgets.ts";
import { AppConfig } from "../config/app-config.ts";
import { LayoutStore } from "../config/layout-store.ts";
import { Workspace } from "../model/workspace.ts";
import { openInBrowser } from "../providers/process.ts";
import { groupingLabel, SessionSidebar } from "./session-sidebar.ts";
import { TerminalPane } from "./terminal-pane.ts";
import { DiffSidebar } from "./diff-sidebar.ts";
import { NewSessionModal } from "./new-session-modal.ts";
import { SettingsModal } from "./settings-modal.ts";
import { ConfirmModal, HelpModal, PromptModal } from "./overlays.ts";
import { SelectPopup } from "./select-popup.ts";
import { availableCommands, type Command, commandOptions } from "./commands.ts";
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
  private prompt: PromptModal | null = null;
  private help: HelpModal | null = null;
  /** The list a dropdown opened; drawn over whatever opened it. */
  private popup: SelectPopup | null = null;
  /** The hit region under the pointer, so anything clickable can tint. */
  private hovered: string | null = null;

  private focus: Focus = "terminal";
  private layoutStore = new LayoutStore();
  private sidebarWidth: number;
  private diffWidth: number;
  /** What the sidebars were doing before zen mode hid them. */
  private beforeZen: { sessions: boolean; diff: boolean } | null = null;
  private dragging: "left" | "right" | "scopeSplit" | "filesSplit" | null = null;
  private dragOrigin = 0;
  private dragBase = 0;

  private status = "";
  private statusUntil = 0;
  private renderQueued = false;
  private running = true;
  /** Runs only while something is connecting; see `syncAnimation`. */
  private animation: ReturnType<typeof setInterval> | null = null;
  /** The pane rect tmux is sized to, so a resize is reported once. */
  private terminalContent: Rect = { x: 0, y: 0, width: 0, height: 0 };

  constructor() {
    this.workspace = new Workspace(this.config, () => this.requestRender());
    this.sessions = new SessionSidebar(this.workspace);
    this.diff = new DiffSidebar(() => this.requestRender());

    // The panes come back the size you left them: a layout dragged to suit one
    // screen is worth exactly nothing if it resets on every launch.
    const layout = this.layoutStore.load();
    this.sidebarWidth = layout.sidebarWidth;
    this.diffWidth = layout.diffWidth;
    this.diff.scopeHeight = layout.scopeHeight;
    this.diff.filesHeight = layout.filesHeight;
    this.workspace.showSessionSidebar = layout.showSessionSidebar;
    this.workspace.showDiffSidebar = layout.showDiffSidebar;
    this.sessions.grouping = layout.sidebarGrouping;
  }

  private persistLayout(): void {
    this.layoutStore.save({
      sidebarWidth: this.sidebarWidth,
      diffWidth: this.diffWidth,
      scopeHeight: this.diff.scopeHeight,
      filesHeight: this.diff.filesHeight,
      showSessionSidebar: this.workspace.showSessionSidebar,
      showDiffSidebar: this.workspace.showDiffSidebar,
      sidebarGrouping: this.sessions.grouping,
    });
  }

  async run(): Promise<void> {
    this.screen.start();
    this.installSignalHandlers();

    // Populate the sidebar with existing VMs, then restore the tabs that were
    // open when the app last quit — after the VM list, so tabs whose VM is gone
    // are dropped. The CLI-held logins are probed first, since which providers
    // are listed at all depends on the answer.
    void this.workspace.loadGitHubUser();
    await this.workspace.refreshCLICredentials();
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
    if (this.animation !== null) clearInterval(this.animation);
    this.animation = null;
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

  /**
   * Repaint on a timer while anything is connecting, so the progress panel's
   * spinner turns and its clock counts. Stopped as soon as nothing needs it —
   * an idle app should draw only when something actually changes.
   */
  private syncAnimation(): void {
    // Anything with a clock on screen: the connecting panel's spinner and
    // elapsed count, and a disconnected session's retry countdown.
    const wanted = this.workspace.sessions.some((session) =>
      session.isConnecting || session.secondsUntilRetry !== null
    );
    if (wanted && this.animation === null) {
      this.animation = setInterval(() => this.requestRender(), 120);
    } else if (!wanted && this.animation !== null) {
      clearInterval(this.animation);
      this.animation = null;
    }
  }

  private render(): void {
    this.syncAnimation();
    this.screen.measure();
    const cols = this.screen.cols;
    const rows = this.screen.rows;
    this.hits.clear();

    const contentHeight = rows - 1;
    const layout = this.layout(cols, contentHeight);

    this.diff.bind(this.workspace.selectedSession);

    // Each pane's whole rectangle takes clicks, registered before the pane
    // renders so its own rows and buttons — added after — win where they
    // overlap. Clicking a pane's empty space is still clicking that pane, and
    // it moves the keyboard there rather than doing nothing at all.
    if (layout.left) this.hits.add(layout.left, "pane.sessions");
    this.hits.add(layout.middle, "pane.terminal");
    if (layout.right) this.hits.add(layout.right, "pane.diff");

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
      this.workspace.hasAnyToken,
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

    this.screen.setTitle(this.windowTitle());

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
    let rightWidth = this.workspace.diffSidebarVisible ? Math.max(MIN_DIFF, this.diffWidth) : 0;
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
    // A divider borders two panes and lights up when either has the keyboard,
    // so the focused pane is fenced by its own edges whichever of the three it
    // is — the terminal sits between both, and lights both.
    const borders = which === "left"
      ? this.focus === "sessions" || this.focus === "terminal"
      : this.focus === "diff" || this.focus === "terminal";
    const fg = active ? Color.accent : borders ? Color.dim : Color.border;
    return styled(active ? "┃" : "│", { fg });
  }

  private statusBar(cols: number): string {
    const session = this.workspace.selectedSession;
    const name = session ? session.displayName : "no session";
    const where = session?.destination ?? "local";
    const message = Date.now() < this.statusUntil ? this.status : "";

    // Sessions that have moved while you weren't looking. The sidebar marks
    // them individually, but the sidebar may well be hidden, and this is the
    // one strip that never is.
    const busy = this.workspace.sessions.filter((one) => one.hasUnseenOutput).length;
    const left = ` ${styled(name, { fg: Color.fg, bold: true })} ` +
      styled(where, { fg: Color.dimmer }) +
      (busy > 0 ? ` ${styled(`● ${busy} active`, { fg: Color.orange })}` : "");
    // With no message to show, the slot carries where the pane's shell actually
    // is — the one piece of state you otherwise have to type `pwd` to learn.
    const middle = message
      ? `  ${styled(message, { fg: Color.accent })}`
      : this.workingDirectoryLabel(session, Math.max(8, cols - 60));
    const right = this.focusHint();
    const used = displayWidth(left) + displayWidth(middle) + displayWidth(right);
    const gap = Math.max(1, cols - used);
    return fit(`${left}${middle}${" ".repeat(gap)}${right}`, cols, { bg: Color.panel });
  }

  /**
   * The bar's right-hand end: where the keyboard is, then the keys that matter
   * from there.
   *
   * It names the pane because that is the question a keyboard interface has to
   * keep answering — the panes say it themselves in their title bars, and this
   * is the one strip that is on screen even in zen mode.
   */
  private focusHint(): string {
    const where = this.focus === "sessions"
      ? "Sessions"
      : this.focus === "diff"
      ? "Diff"
      : this.terminal.inBody
      ? "Terminal"
      : "Tabs";
    const keys = this.focus === "terminal"
      ? (this.terminal.inBody
        ? "Alt+F leaves · Alt+P commands · F1 keys "
        : "← → switch · Enter types · F1 keys ")
      : "Tab moves · Enter selects · Esc terminal ";
    return styled(`${where} `, { fg: Color.accent, bold: true }) +
      styled(`· ${keys}`, { fg: Color.dimmer });
  }

  /**
   * What the surrounding terminal calls this window. Named after the session
   * you're on, with a dot when another session has moved — so hub tells you
   * something even when it isn't the window you're looking at.
   */
  private windowTitle(): string {
    const session = this.workspace.selectedSession;
    const busy = this.workspace.sessions.some((one) => one.hasUnseenOutput);
    const name = session ? session.displayName : "no session";
    // Plain ASCII: title bars are shown by everything from a tab strip to a
    // taskbar, and not all of them agree on what to do with the fancier glyphs.
    return `${busy ? "* " : ""}${name} - hub`;
  }

  /** The pane's working directory, with the home prefix shortened to `~`. */
  private workingDirectoryLabel(
    session: { workingDirectory: string | null } | null,
    room: number,
  ): string {
    const path = session?.workingDirectory;
    if (!path) return "";
    const short = path.replace(/^\/(?:home|Users)\/[^/]+/, "~");
    return `  ${styled(elideHead(short, room), { fg: Color.dimmer })}`;
  }

  /**
   * Overlays, innermost last: a dropdown opened from a modal is drawn over it,
   * and each layer is registered after the one below so it takes the clicks.
   */
  private renderOverlay(cols: number, rows: number): Array<{ lines: string[]; rect: Rect }> {
    const layers: Array<{ lines: string[]; rect: Rect }> = [];
    if (this.settings) layers.push(this.settings.render(cols, rows, this.hits));
    if (this.newSession) layers.push(this.newSession.render(cols, rows, this.hits));
    if (this.help) layers.push(this.help.render(cols, rows, this.hits));
    if (this.prompt) layers.push(this.prompt.render(cols, rows, this.hits));
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
      (this.confirm ? null : this.prompt?.cursorPosition()) ??
      (this.confirm || this.prompt || this.help ? null : this.settings?.cursorPosition()) ??
      (this.confirm || this.prompt || this.help || this.settings
        ? null
        : this.newSession?.cursorPosition()) ??
      (modalOpen || this.focus !== "diff" ? null : this.diff.cursorPosition());
    if (field) return { x: field.x, y: field.y, visible: true };

    const session = this.workspace.selectedSession;
    const tab = session?.selectedTab;
    // Scrolled back, the cursor isn't on screen at all; drawing it where it
    // would have been would point at the wrong line of old output.
    if (modalOpen || this.focus !== "terminal" || !tab || !tab.cursor.visible || tab.scrollback) {
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
        // app was in the background — or a `devbox login` run in the terminal
        // next door.
        if (event.focused) {
          this.workspace.reconnectDisconnectedSessions();
          void this.workspace.refreshCLICredentials().then(() => this.workspace.loadAvailableVMs());
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
    if (this.prompt) {
      if (this.prompt.key(event)) this.prompt = null;
      return;
    }
    if (this.help) {
      // Anything that isn't a scroll closes it, so it never becomes a mode.
      if (this.help.key(event.name)) this.help = null;
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
      this.help = new HelpModal();
      return;
    }
    if (event.alt && await this.globalShortcut(event)) return;

    // While the terminal pane's body has the keyboard, every key belongs to the
    // program running there — Tab included, or a shell loses completion. Alt+F
    // is how you step back out.
    if (this.focus === "terminal" && this.terminal.inBody) {
      this.workspace.selectedSession?.sendKeys(event.bytes);
      return;
    }

    // Everywhere else Tab walks the focus ring, so the whole interface is
    // reachable without the mouse.
    if (event.name === "tab") {
      this.moveFocus(event.shift ? -1 : 1);
      return;
    }
    if (event.name === "escape") {
      // A search in the diff pane claims Esc first: dropping the query is what
      // you mean, and the Esc after that still leaves for the terminal.
      if (this.focus === "diff" && this.diff.searchActive) {
        await this.diffKey(event);
        return;
      }
      this.enterTerminal();
      return;
    }

    switch (this.focus) {
      case "sessions":
        this.sessionSidebarKey(event);
        return;
      case "terminal":
        switch (this.terminal.key(this.workspace.selectedSession, event.name)) {
          case "enterBody":
            this.enterTerminal();
            return;
          case "newTab":
            this.workspace.selectedSession?.newTab();
            return;
          default:
            return;
        }
      case "diff":
        await this.diffKey(event);
        return;
    }
  }

  /** Run a key through the diff pane and do whatever it couldn't do itself. */
  private async diffKey(event: KeyEvent): Promise<void> {
    switch (await this.diff.key(event)) {
      case "openRepos":
        this.openRepoPopup();
        return;
      case "copy":
        this.copyFromDiff();
        return;
    }
  }

  /**
   * Put the diff pane's current selection on the *terminal's* clipboard, which
   * is the one on the desk in front of you even when hub is running over SSH.
   */
  private copyFromDiff(): void {
    const text = this.diff.clipboardText();
    if (!text) {
      this.say("Nothing to copy here");
      return;
    }
    const sent = this.screen.copyToClipboard(text);
    this.say(
      sent < text.length
        ? `Copied the first ${sent} characters — the rest is too long for the terminal`
        : text.includes("\n")
        ? `Copied ${text.split("\n").length} lines`
        : `Copied ${text}`,
    );
  }

  /**
   * Move to the next control, stepping into the next pane when the current one
   * runs out. Hidden panes are skipped.
   */
  private moveFocus(step: number): void {
    const pane = this.pane(this.focus);
    if (pane.advance(step)) return;

    const available = this.focusablePanes();
    const current = available.indexOf(this.focus);
    const next = available[(current + step + available.length) % available.length];
    this.focus = next;
    const entered = this.pane(next);
    if (step > 0) entered.focusFirst();
    else entered.focusLast();
  }

  private pane(
    focus: Focus,
  ): {
    advance(step: number): boolean;
    focusFirst(): void;
    focusLast(): void;
    focusMain(): void;
  } {
    if (focus === "sessions") return this.sessions;
    if (focus === "diff") return this.diff;
    return this.terminal;
  }

  private focusablePanes(): Focus[] {
    const order: Focus[] = ["sessions", "terminal", "diff"];
    return order.filter((one) =>
      one === "terminal" ||
      (one === "sessions" && this.workspace.showSessionSidebar) ||
      (one === "diff" && this.workspace.diffSidebarVisible)
    );
  }

  /** Put the keyboard in the terminal itself, where keys reach the program. */
  private enterTerminal(): void {
    this.focus = "terminal";
    this.terminal.enterBody();
  }

  /** Returns whether the shortcut was handled. */
  private async globalShortcut(event: KeyEvent): Promise<boolean> {
    const session = this.workspace.selectedSession;
    switch (event.name) {
      case "n":
        this.openNewSession();
        return true;
      case "l":
        this.workspace.newLocalSession();
        return true;
      case "w":
        // Closes the window you're looking at. On the last one there is no
        // window left to close without also ending the session, so it does
        // that instead — which is what "close this" means at that point.
        this.closeCurrentTab();
        return true;
      case "W":
        if (session) this.workspace.closeSession(session);
        return true;
      case "d":
        this.confirmDelete();
        return true;
      case "o":
        await this.openBrowser();
        return true;
      case "s":
        this.toggleSessionSidebar();
        return true;
      case "r":
        this.toggleDiffSidebar();
        return true;
      case "p":
        this.openCommandPalette();
        return true;
      case "z":
        this.toggleZen();
        return true;
      case "m":
        this.renameSession();
        return true;
      case "g":
        this.openSessionSwitcher();
        return true;
      case "c":
        this.copyTerminalScreen();
        return true;
      case "t":
        session?.newTab();
        return true;
      case "k":
        this.workspace.reconnectDisconnectedSessions();
        this.say("Reconnecting…");
        return true;
      case "f":
        // The way out of the terminal body, where Tab belongs to the program.
        this.moveFocus(event.shift ? -1 : 1);
        return true;
      case ",":
        this.settings = new SettingsModal(
          this.config,
          this.workspace,
          (popup) => this.openPopup(popup),
        );
        return true;
      case "q":
        this.quit();
        return true;
      // The arrows navigate the layout: left and right across the three panes,
      // up and down within whichever one you're in. The brackets stay inside
      // the session, on its tmux windows.
      case "[":
        session?.selectAdjacentTab(-1);
        return true;
      case "]":
        session?.selectAdjacentTab(1);
        return true;
      case "left":
      case "right": {
        const step = event.name === "left" ? -1 : 1;
        // Shift resizes the pane you're in rather than leaving it.
        if (event.shift && this.resizeFocusedSidebar(step * 2)) return true;
        this.focusAdjacentPane(step);
        return true;
      }
      case "up":
      case "down":
        this.moveWithinPane(event.name === "up" ? -1 : 1);
        return true;
      case "pageup":
        // Scrollback from the keyboard, in the app's own namespace so the
        // program in the pane keeps its own PageUp.
        session?.scrollTab(this.terminalContent.height - 1);
        return true;
      case "pagedown":
        session?.scrollTab(-(this.terminalContent.height - 1));
        return true;
      case "end":
        session?.resetScroll();
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

  private toggleSessionSidebar(): void {
    this.workspace.showSessionSidebar = !this.workspace.showSessionSidebar;
    // Hiding the pane the keyboard is in would strand it somewhere invisible.
    if (!this.workspace.showSessionSidebar && this.focus === "sessions") this.enterTerminal();
    this.beforeZen = null;
    this.screen.invalidate();
    this.persistLayout();
  }

  private toggleDiffSidebar(): void {
    this.workspace.showDiffSidebar = !this.workspace.showDiffSidebar;
    // A local shell has no remote worktree, so the diff sidebar stays hidden
    // on local tabs — flip the preference, but say so when it can't take
    // effect here.
    const session = this.workspace.selectedSession;
    if (session !== null && session.destination === null) {
      this.say("Diff sidebar is hidden on local sessions");
    }
    if (!this.workspace.showDiffSidebar && this.focus === "diff") this.enterTerminal();
    this.beforeZen = null;
    this.screen.invalidate();
    this.persistLayout();
  }

  /**
   * Both sidebars away, the terminal edge to edge, in one keystroke — and back
   * to exactly what was showing before.
   *
   * "In zen mode" is read off the panes rather than a flag of its own, so
   * hiding both with Alt+S and Alt+R leaves Alt+Z meaning what it looks like it
   * should mean.
   */
  private toggleZen(): void {
    if (!this.workspace.showSessionSidebar && !this.workspace.showDiffSidebar) {
      const restore = this.beforeZen ?? { sessions: true, diff: true };
      this.workspace.showSessionSidebar = restore.sessions;
      this.workspace.showDiffSidebar = restore.diff;
      this.beforeZen = null;
    } else {
      this.beforeZen = {
        sessions: this.workspace.showSessionSidebar,
        diff: this.workspace.showDiffSidebar,
      };
      this.workspace.showSessionSidebar = false;
      this.workspace.showDiffSidebar = false;
      this.enterTerminal();
    }
    this.screen.invalidate();
    this.persistLayout();
  }

  /**
   * Everything the app can do, in one filterable list. The shortcut beside each
   * entry is the point as much as the entry is: the palette is discoverable, and
   * using it teaches the chord that skips it next time.
   */
  private commands(): Command[] {
    const session = this.workspace.selectedSession;
    return availableCommands([
      { label: "Go to Session or VM…", shortcut: "Alt+G", run: () => this.openSessionSwitcher() },
      { label: "New Session…", shortcut: "Alt+N", run: () => this.openNewSession() },
      { label: "New Local Shell", shortcut: "Alt+L", run: () => this.workspace.newLocalSession() },
      {
        label: "New Terminal Tab",
        shortcut: "Alt+T",
        enabled: session !== null,
        run: () => session?.newTab(),
      },
      {
        label: "Rename Session…",
        shortcut: "Alt+M",
        enabled: session !== null,
        run: () => this.renameSession(),
      },
      {
        label: (session?.tabs.length ?? 0) > 1
          ? "Close Terminal Window"
          : "Close Terminal Window (the last — ends the session)",
        shortcut: "Alt+W",
        enabled: session !== null,
        run: () => this.closeCurrentTab(),
      },
      {
        label: "Close Session",
        shortcut: "Alt+Shift+W",
        enabled: session !== null,
        run: () => {
          if (session) this.workspace.closeSession(session);
        },
      },
      {
        label: "Delete Session and VM…",
        shortcut: "Alt+D",
        enabled: session !== null,
        run: () => this.confirmDelete(),
      },
      { label: "Open VM in Browser", shortcut: "Alt+O", run: () => this.openBrowser() },
      {
        label: "Copy Terminal Screen",
        shortcut: "Alt+C",
        enabled: session !== null,
        run: () => this.copyTerminalScreen(),
      },
      {
        label: this.workspace.showSessionSidebar
          ? "Hide Sessions Sidebar"
          : "Show Sessions Sidebar",
        shortcut: "Alt+S",
        run: () => this.toggleSessionSidebar(),
      },
      {
        label: `Group Sessions by ${groupingLabel(this.sessions.grouping)} → Next`,
        enabled: this.workspace.showSessionSidebar,
        run: () => {
          this.sessions.cycleGrouping();
          this.persistLayout();
          this.say(`Grouped by ${groupingLabel(this.sessions.grouping)}`);
        },
      },
      {
        label: this.workspace.showDiffSidebar ? "Hide Diff Sidebar" : "Show Diff Sidebar",
        shortcut: "Alt+R",
        run: () => this.toggleDiffSidebar(),
      },
      {
        label: !this.workspace.showSessionSidebar && !this.workspace.showDiffSidebar
          ? "Leave Zen Mode"
          : "Zen Mode — Terminal Only",
        shortcut: "Alt+Z",
        run: () => this.toggleZen(),
      },
      {
        label: "Reconnect Dropped Sessions",
        shortcut: "Alt+K",
        run: () => {
          this.workspace.reconnectDisconnectedSessions();
          this.say("Reconnecting…");
        },
      },
      {
        label: "Refresh VM List",
        run: async () => {
          this.say("Refreshing VMs…");
          await this.workspace.loadAvailableVMs();
        },
      },
      {
        label: "Settings…",
        shortcut: "Alt+,",
        run: () => {
          this.settings = new SettingsModal(
            this.config,
            this.workspace,
            (popup) => this.openPopup(popup),
          );
        },
      },
      {
        label: "Keyboard Shortcuts",
        shortcut: "F1",
        run: () => {
          this.help = new HelpModal();
        },
      },
      { label: "Quit", shortcut: "Alt+Q", run: () => this.quit() },
    ]);
  }

  /**
   * Copy what the terminal pane is showing. tmux's own colours come with the
   * capture, so they're stripped — what you want on the clipboard is the text,
   * not the escape sequences that drew it.
   */
  private copyTerminalScreen(): void {
    const tab = this.workspace.selectedSession?.selectedTab;
    if (!tab || tab.screen.length === 0) {
      this.say("Nothing on screen to copy");
      return;
    }
    const text = tab.screen.map((line) => stripAnsi(line).trimEnd()).join("\n").trimEnd();
    if (!text) {
      this.say("Nothing on screen to copy");
      return;
    }
    const sent = this.screen.copyToClipboard(text);
    this.say(
      sent < text.length
        ? `Copied the first ${sent} characters — the rest is too long for the terminal`
        : `Copied ${text.split("\n").length} lines from the pane`,
    );
  }

  /**
   * Close the tmux window on screen, leaving the session and its other windows
   * running. The tab goes when tmux reports the pane gone, so a refused kill
   * leaves it where it was.
   *
   * On the last window it closes the session instead: killing that pane would
   * end the tmux session anyway, and leaving a tab that can't be closed would
   * be a worse answer than doing the obvious thing.
   */
  private closeCurrentTab(): void {
    const session = this.workspace.selectedSession;
    if (!session) {
      this.say("No session to close");
      return;
    }
    const tab = session.selectedTab;
    if (!tab || session.tabs.length <= 1) {
      this.workspace.closeSession(session);
      return;
    }
    session.closeTab(tab);
  }

  /**
   * Move the keyboard to the pane left or right of this one, wrapping. Hidden
   * panes are skipped, and every pane is entered at the thing it is *for* —
   * its list, or the terminal itself — rather than at whichever end of its
   * controls the arrow came from. This is a pane switcher, so it puts you where
   * the work is; Tab is what walks the controls once you're there.
   */
  private focusAdjacentPane(step: number): void {
    const available = this.focusablePanes();
    if (available.length === 0) return;
    const current = available.indexOf(this.focus);
    const next = available[(current + step + available.length) % available.length];
    if (next === "terminal") {
      this.enterTerminal();
      return;
    }
    this.focus = next;
    this.pane(next).focusMain();
  }

  /**
   * Up and down mean "the next thing down in this pane". In the diff sidebar
   * that's its stacked panes; everywhere else — the session list, the terminal
   * — it's the next session, which is the list running down the left.
   */
  private moveWithinPane(step: number): void {
    if (this.focus === "diff") {
      this.diff.cyclePart(step);
      return;
    }
    this.workspace.selectAdjacentSession(step);
    this.sessions.syncSelection();
  }

  /** Widen or narrow whichever sidebar has the keyboard. */
  private resizeFocusedSidebar(delta: number): boolean {
    if (this.focus === "sessions") {
      this.sidebarWidth = Math.max(MIN_SIDEBAR, this.sidebarWidth + delta);
    } else if (this.focus === "diff") {
      // The diff sidebar is anchored to the right edge, so it grows against
      // the arrow: Left widens it.
      this.diffWidth = Math.max(MIN_DIFF, this.diffWidth - delta);
    } else {
      return false;
    }
    this.screen.invalidate();
    this.persistLayout();
    return true;
  }

  /**
   * Everything you might want on screen, in one list: the sessions already
   * open, then the VMs that aren't. Typing a VM's name and pressing Enter
   * connects to it, which is the shortest path from "where was that box" to
   * looking at it.
   */
  private openSessionSwitcher(): void {
    const sessions = this.workspace.sessions;
    const unopened = this.workspace.unopenedVMs;
    if (sessions.length === 0 && unopened.length === 0) {
      this.say("No sessions or VMs to switch to");
      return;
    }
    const options = [
      ...sessions.map((one) => ({
        label: one.displayName,
        detail: one.hasUnseenOutput ? "open · new output" : "open",
      })),
      ...unopened.map((vm) => ({ label: vm.name, detail: vm.status ?? "not connected" })),
    ];
    const current = sessions.findIndex((one) => one.id === this.workspace.selectedSessionID);
    this.openPopup(
      new SelectPopup("Go to", options, current, (index) => {
        if (index < sessions.length) this.workspace.selectSession(sessions[index].id);
        else this.workspace.reopen(unopened[index - sessions.length]);
        this.sessions.syncSelection();
      }),
    );
  }

  /**
   * Name the open session yourself. Left empty it goes back to being named by
   * its VM — which is what names it while an agent is still deciding.
   */
  private renameSession(): void {
    const session = this.workspace.selectedSession;
    if (!session) {
      this.say("No session to rename");
      return;
    }
    this.prompt = new PromptModal(
      "Rename session",
      session.vmName ?? "Name this session…",
      session.title,
      (title) => this.workspace.renameSession(session, title),
    );
  }

  private openCommandPalette(): void {
    const commands = this.commands();
    // No option is "current", so -1: the list opens on the first entry without
    // marking any of them as the value already chosen.
    this.openPopup(
      new SelectPopup("Commands", commandOptions(commands), -1, (index) => {
        void commands[index].run();
      }),
    );
  }

  private sessionSidebarKey(event: KeyEvent): void {
    switch (this.sessions.key(event.name)) {
      case "activate":
        if (this.sessions.onNewButton) this.openNewSession();
        else this.activateSidebarRow(this.sessions.current);
        return;
      case "delete":
        this.confirmDeleteRow(this.sessions.current);
        return;
      case "group":
        this.sessions.cycleGrouping();
        this.persistLayout();
        this.say(`Grouped by ${groupingLabel(this.sessions.grouping)}`);
        return;
      default:
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
      // Written once the handle is let go rather than on every pixel of the
      // drag, so resizing a pane isn't a file write per mouse event.
      if (this.dragging) this.persistLayout();
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
    if (this.prompt) {
      // Clicking away is a cancel; the field itself already has the keyboard.
      if (!region?.id.startsWith("prompt.")) this.prompt = null;
      return;
    }
    if (this.help) {
      this.help = null;
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

    // A pane's own background: the click means "work here now", and nothing
    // more — no row is selected, nothing is opened.
    if (id === "pane.sessions" || id === "pane.diff") {
      this.focus = id === "pane.sessions" ? "sessions" : "diff";
      return;
    }
    if (id === "pane.terminal") {
      this.enterTerminal();
      return;
    }

    if (id.startsWith("sidebar.")) {
      // Clicking moves the keyboard there too, so the two never disagree about
      // what Enter would press.
      this.focus = "sessions";
      if (id === "sidebar.new") {
        this.sessions.focusLast();
        this.openNewSession();
        return;
      }
      if (id === "sidebar.group") {
        this.sessions.part = "group";
        this.sessions.cycleGrouping();
        this.persistLayout();
        this.say(`Grouped by ${groupingLabel(this.sessions.grouping)}`);
        return;
      }
      // The keyboard lands on the row that was clicked, not on whichever row it
      // was on before: after a click, ↑ and ↓ carry on from what you pointed at.
      this.sessions.focusList(this.sessions.indexFor(id) ?? undefined);
      this.activateSidebarRow(this.sessions.rowFor(id));
      return;
    }

    if (id.startsWith("terminal.")) {
      this.focus = "terminal";
      const session = this.workspace.selectedSession;
      if (id === "terminal.newTab") {
        this.terminal.focusLast();
        session?.newTab();
        return;
      }
      if (id.startsWith("terminal.tab:")) {
        this.terminal.focusFirst();
        const tab = session?.tabs[Number(id.slice("terminal.tab:".length))];
        if (tab) session?.selectTab(tab.paneID);
        return;
      }
      // Clicking the pane itself is how you get back to typing.
      this.enterTerminal();
      return;
    }

    if (id.startsWith("diff.")) {
      this.focus = "diff";
      if (id === "diff.repo") {
        this.diff.part = "repo";
        this.openRepoPopup();
        return;
      }
      if (id.startsWith("diff.scope:")) this.diff.part = "scope";
      else if (id.startsWith("diff.file:")) this.diff.part = "files";
      else if (id === "diff.body") this.diff.part = "diff";
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
    if (this.help) {
      this.help.scroll(delta);
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
    // Over a pane's empty space the wheel still belongs to that pane's list:
    // the pointer is in the sidebar, so the sidebar scrolls.
    if (id?.startsWith("sidebar.") || id === "pane.sessions") {
      this.sessions.scroll(delta);
      return;
    }
    if (id?.startsWith("diff.") || id === "pane.diff") {
      this.diff.scroll(id, delta);
      return;
    }
    // Over the terminal the wheel means what it means in a terminal: it walks
    // the pane's scrollback. A full-screen program — an editor, an agent's UI —
    // owns the wheel instead, so it gets the arrows it is listening for.
    if (id === "terminal.body") {
      const session = this.workspace.selectedSession;
      if (!session) return;
      if (!session.selectedTab?.alternate && session.scrollTab(-delta)) return;
      const bytes = new TextEncoder().encode(delta < 0 ? "\x1b[A".repeat(3) : "\x1b[B".repeat(3));
      session.sendKeys(bytes);
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
