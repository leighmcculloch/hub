/**
 * hub's server: the workspace, over HTTP.
 *
 * Everything that talks to a provider, a VM, a git worktree or the config file
 * lives behind this. The client — the window, the browser tab — holds no state
 * of its own beyond what it is showing, and reaches for all of it here.
 *
 * The split is what makes a desktop app possible at all: `deno desktop` renders
 * a WebView, and a WebView cannot spawn `docker`, hold a tmux control client or
 * read `~/.pi/agent/auth.json`. It can talk to a server on localhost that does.
 * The same boundary means hub can run headless with a browser pointed at it.
 *
 * Pane output is the one thing that isn't request/response: tmux's control
 * protocol already hands us `%output %<pane> <bytes>` as it happens, so a
 * socket per session carries those bytes straight to a terminal emulator in the
 * client. The terminal grid is the client's problem; this end stays bytes.
 */

import { AppConfig } from "../config/app-config.ts";
import { Workspace } from "../model/workspace.ts";
import { ALL_PROVIDERS, providerLabel } from "../model/provider-label.ts";
import type { TerminalSession } from "../model/terminal-session.ts";

/** What the client is told about a session. */
export interface SessionView {
  id: string;
  title: string;
  destination: string | null;
  provider: string;
  hasUnseenOutput: boolean;
  tabs: Array<{ paneID: string; title: string }>;
  selectedTabID: string | null;
}

/** What the client is told about a machine it could open. */
export interface VMView {
  name: string;
  destination: string;
  provider: string;
  status: string | null;
}

/** One snapshot of everything the client renders from. */
export interface StateView {
  sessions: SessionView[];
  selectedSessionID: string | null;
  vms: VMView[];
  providers: Array<{ id: string; label: string; configured: boolean }>;
  errors: Array<{ provider: string; reason: string }>;
}

export function sessionView(session: TerminalSession): SessionView {
  return {
    id: session.id,
    title: session.displayName,
    destination: session.destination,
    provider: session.provider.id,
    hasUnseenOutput: session.hasUnseenOutput,
    tabs: session.tabs.map((tab) => ({ paneID: tab.paneID, title: tab.title })),
    selectedTabID: session.selectedTab?.paneID ?? null,
  };
}

export function stateView(workspace: Workspace): StateView {
  return {
    sessions: workspace.sessions.map(sessionView),
    selectedSessionID: workspace.selectedSession?.id ?? null,
    vms: workspace.unopenedVMs.map((vm) => ({
      name: vm.name,
      destination: vm.destination,
      provider: vm.provider,
      status: vm.status,
    })),
    providers: ALL_PROVIDERS.map((id) => ({
      id,
      label: providerLabel(id),
      configured: workspace.isConfigured(id),
    })),
    errors: workspace.vmListErrors.map((one) => ({
      provider: one.provider,
      reason: one.reason,
    })),
  };
}

/**
 * The server. One workspace, one set of routes over it, and the client's files.
 *
 * `onChange` from the workspace is broadcast rather than rendered: every
 * connected client is told the state moved and asks for it again. That is the
 * whole of the push protocol, and it means a client that reconnects is never
 * out of date.
 */
export class HubServer {
  readonly config = AppConfig.load();
  readonly workspace: Workspace;
  private watchers = new Set<WebSocket>();

  constructor(private clientRoot: URL) {
    this.workspace = new Workspace(this.config, () => this.broadcast());
  }

  /** Load what the app needs before a client asks: VMs, the GitHub identity. */
  async start(): Promise<void> {
    this.workspace.restoreSessions();
    await this.workspace.refreshCLICredentials();
    await Promise.all([
      this.workspace.loadAvailableVMs(),
      this.workspace.loadGitHubUser(),
    ]);
  }

  handler = (request: Request): Response | Promise<Response> => {
    const url = new URL(request.url);
    if (url.pathname === "/api/state") return json(stateView(this.workspace));
    if (url.pathname === "/api/watch") return this.watch(request);
    if (url.pathname.startsWith("/api/session/")) {
      return this.sessionSocket(request, url.pathname.slice("/api/session/".length));
    }
    if (url.pathname === "/xterm.js" || url.pathname === "/xterm.css") {
      return this.vendored(url.pathname);
    }
    return this.file(url.pathname);
  };

  /**
   * A socket that says only "something changed". The client answers by asking
   * for the state again, which keeps one description of the world rather than
   * one per event.
   */
  private watch(request: Request): Response {
    if (request.headers.get("upgrade") !== "websocket") {
      return new Response("expected a websocket", { status: 400 });
    }
    const { socket, response } = Deno.upgradeWebSocket(request);
    socket.onopen = () => this.watchers.add(socket);
    socket.onclose = () => this.watchers.delete(socket);
    socket.onerror = () => this.watchers.delete(socket);
    return response;
  }

  private broadcast(): void {
    for (const socket of this.watchers) {
      if (socket.readyState === WebSocket.OPEN) socket.send("changed");
    }
  }

  /**
   * A session's terminal: pane bytes out, keystrokes in.
   *
   * Bytes rather than a rendered screen. The terminal in the client is a real
   * emulator, and handing it the stream tmux already produces is both less work
   * and more faithful than shipping it a grid of characters.
   */
  private sessionSocket(request: Request, id: string): Response {
    const session = this.workspace.sessions.find((one) => one.id === id);
    if (!session) return new Response("no such session", { status: 404 });
    if (request.headers.get("upgrade") !== "websocket") {
      return new Response("expected a websocket", { status: 400 });
    }
    const { socket, response } = Deno.upgradeWebSocket(request);
    socket.binaryType = "arraybuffer";

    const stop = session.onPaneOutput((bytes) => {
      if (socket.readyState === WebSocket.OPEN) socket.send(bytes);
    });
    socket.onclose = stop;
    socket.onerror = stop;
    socket.onmessage = (event) => {
      if (typeof event.data === "string") {
        // Anything that isn't a keystroke is a small JSON instruction.
        this.sessionCommand(session, event.data);
        return;
      }
      session.sendKeys(new Uint8Array(event.data as ArrayBuffer));
    };
    return response;
  }

  private sessionCommand(session: TerminalSession, text: string): void {
    let message: { type?: string; cols?: number; rows?: number; paneID?: string };
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    if (message.type === "resize" && message.cols && message.rows) {
      session.reportSize(message.cols, message.rows);
    } else if (message.type === "selectTab" && message.paneID) {
      session.selectTab(message.paneID);
    } else if (message.type === "newTab") {
      session.newTab();
    }
  }

  /**
   * The terminal emulator, served out of the npm package rather than a CDN.
   *
   * A desktop app that needs the network to draw its own window is not a
   * desktop app, and the package is already on disk because the server imports
   * it — `import.meta.resolve` says where.
   */
  private async vendored(pathname: string): Promise<Response> {
    const base = import.meta.resolve("@xterm/xterm");
    const file = pathname === "/xterm.js" ? "lib/xterm.js" : "css/xterm.css";
    try {
      const body = await Deno.readFile(new URL(`../${file}`, base));
      return new Response(body, { headers: { "content-type": contentType(pathname) } });
    } catch (error) {
      return new Response(`xterm is not installed: ${error}`, { status: 500 });
    }
  }

  /** The client's own files. Anything unrecognised is the page itself. */
  private async file(pathname: string): Promise<Response> {
    const name = pathname === "/" ? "index.html" : pathname.replace(/^\//, "");
    try {
      const body = await Deno.readFile(new URL(name, this.clientRoot));
      return new Response(body, { headers: { "content-type": contentType(name) } });
    } catch {
      const index = await Deno.readFile(new URL("index.html", this.clientRoot));
      return new Response(index, { headers: { "content-type": "text/html; charset=utf-8" } });
    }
  }
}

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
  });
}

export function contentType(name: string): string {
  if (name.endsWith(".html")) return "text/html; charset=utf-8";
  if (name.endsWith(".css")) return "text/css; charset=utf-8";
  if (name.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (name.endsWith(".json")) return "application/json";
  return "application/octet-stream";
}
