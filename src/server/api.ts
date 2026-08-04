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
import {
  applyConfig,
  configView,
  diffView,
  Provisioning,
  type ProvisionView,
  repoOptions,
} from "./routes.ts";
import { providerIDFrom } from "../model/provider-label.ts";

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
  provisioning: ProvisionView;
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

export function stateView(workspace: Workspace, provisioning: ProvisionView): StateView {
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
    provisioning,
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
  readonly provisioning: Provisioning;
  private watchers = new Set<WebSocket>();

  constructor(private clientRoot: URL) {
    this.workspace = new Workspace(this.config, () => this.broadcast());
    this.provisioning = new Provisioning(this.workspace, () => this.broadcast());
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
    if (url.pathname === "/api/state") {
      return json(stateView(this.workspace, this.provisioning.view));
    }
    if (url.pathname === "/api/watch") return this.watch(request);
    // Before the catch-all below: this one is a socket upgrade, and answering
    // it with a JSON 404 leaves a client whose terminal never receives a byte.
    if (url.pathname.startsWith("/api/session/")) {
      return this.sessionSocket(request, url.pathname.slice("/api/session/".length));
    }
    if (url.pathname.startsWith("/api/")) return this.api(request, url);
    if (url.pathname === "/xterm.js" || url.pathname === "/xterm.css") {
      return this.vendored(url.pathname);
    }
    return this.file(url.pathname);
  };

  /** Everything the client asks hub to do, and the two lists it reads. */
  private async api(request: Request, url: URL): Promise<Response> {
    const path = url.pathname;
    const body = request.method === "POST" || request.method === "PUT"
      ? await request.json().catch(() => ({}))
      : {};

    if (path === "/api/repos") return json(await repoOptions());
    if (path === "/api/config") {
      if (request.method === "PUT") {
        applyConfig(this.config, body);
        this.broadcast();
        return json(configView(this.config));
      }
      return json(configView(this.config));
    }
    if (path === "/api/sessions" && request.method === "POST") {
      const provider = providerIDFrom(body.provider) ?? this.config.data.provider;
      const started = this.provisioning.start({
        provider,
        name: String(body.name ?? ""),
        repos: Array.isArray(body.repos) ? body.repos.map(String) : [],
      });
      return json({ started });
    }
    if (path === "/api/sessions/local" && request.method === "POST") {
      this.workspace.newLocalSession();
      return json({ ok: true });
    }
    if (path === "/api/sessions/open" && request.method === "POST") {
      const vm = this.workspace.unopenedVMs.find((one) =>
        one.name === body.name && one.provider === body.provider
      );
      if (!vm) return new Response("no such machine", { status: 404 });
      this.workspace.reopen(vm);
      return json({ ok: true });
    }
    if (path === "/api/provisioning/dismiss" && request.method === "POST") {
      this.provisioning.dismiss();
      return json({ ok: true });
    }

    const session = this.sessionFrom(path);
    if (session) {
      if (path.endsWith("/select")) {
        this.workspace.selectSession(session.id);
        return json({ ok: true });
      }
      if (path.endsWith("/rename")) {
        this.workspace.renameSession(session, String(body.title ?? ""));
        return json({ ok: true });
      }
      if (path.endsWith("/close")) {
        this.workspace.closeSession(session);
        return json({ ok: true });
      }
      if (path.endsWith("/delete")) {
        await this.workspace.deleteSession(session);
        return json({ ok: true });
      }
      if (path.endsWith("/diff")) {
        return json(await diffView(session, url.searchParams.get("repo")));
      }
    }
    return new Response("not found", { status: 404 });
  }

  /** The session an `/api/sessions/<id>/…` path names. */
  private sessionFrom(path: string): TerminalSession | null {
    const match = /^\/api\/sessions\/([^/]+)\//.exec(path);
    if (!match) return null;
    return this.workspace.sessions.find((one) => one.id === match[1]) ?? null;
  }

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

/**
 * Start listening, on a port that is actually free.
 *
 * The default is fixed so the address is memorable and a bookmark keeps
 * working, but a port already in use is not a reason to refuse to start — a
 * second copy of hub, or anything else that got to 8000 first, would otherwise
 * end the process with a stack trace. `PORT` overrides; a taken port falls back
 * to whichever one the system hands out, and either way the URL is printed
 * because it is the one thing the user needs next.
 */
export function serve(handler: Deno.ServeHandler, preferred = DEFAULT_PORT): Deno.HttpServer {
  const announce = ({ port }: { port: number }) => {
    console.log(`hub is at http://localhost:${port}`);
  };
  try {
    return Deno.serve({ port: preferred, onListen: announce }, handler);
  } catch (error) {
    if (!(error instanceof Deno.errors.AddrInUse)) throw error;
    console.log(`port ${preferred} is taken; using another`);
    return Deno.serve({ port: 0, onListen: announce }, handler);
  }
}

/** Where hub listens unless `PORT` says otherwise. */
export const DEFAULT_PORT = Number(Deno.env.get("PORT") ?? "8000") || 8000;
