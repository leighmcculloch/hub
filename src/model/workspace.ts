/**
 * Top-level app state: the terminal sessions shown in the left sidebar, plus
 * the VM provider used to provision them.
 */

import { AppConfig } from "../config/app-config.ts";
import {
  type PersistedWorkspace,
  restorable,
  restorableSelection,
  SessionStore,
} from "../config/session-store.ts";
import { bootstrapCommand, controlModeCommand, LOCAL_TMUX_SESSION } from "./bootstrap.ts";
import { TerminalSession } from "./terminal-session.ts";
import { SessionProvisioner } from "./session-provisioner.ts";
import { indexForShortcut, indexFrom } from "./tab-navigation.ts";
import { ExeProvider } from "../providers/exe-provider.ts";
import { SpritesProvider } from "../providers/sprites-provider.ts";
import { run as runRemote } from "../git/remote-git.ts";
import {
  currentGitHubUser,
  type GitHubUser,
  userDisplayName,
  userNoreplyEmail,
} from "../github/repos.ts";
import type { RemoteVMRecord, VMProvider, VMProviderID } from "../providers/types.ts";
import type { GatewaySelection } from "../providers/types.ts";

/** How often each connected VM is asked whether it has renamed itself. */
const RENAME_POLL_MS = 10_000;

/** A one-line reason from a thrown value, short enough for a sidebar row. */
function failureReason(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  const line = message.split("\n")[0].trim();
  return line || "Couldn't reach the provider";
}

export class Workspace {
  sessions: TerminalSession[] = [];
  selectedSessionID: string | null = null;

  showSessionSidebar = true;
  showDiffSidebar = true;

  /**
   * VMs that exist on the active provider's account. Listed in the sidebar at
   * launch so a previous session can be reopened; none is connected until
   * clicked.
   */
  availableVMs: RemoteVMRecord[] = [];
  loadingVMs = false;
  /**
   * Why the last listing failed, if it did. An empty "Existing" section and a
   * provider that is refusing the token look identical otherwise, and only one
   * of them is something you can act on.
   */
  vmListError: string | null = null;

  /** The signed-in GitHub account, used to seed git config on new VMs. */
  githubUser: GitHubUser | null = null;

  readonly config: AppConfig;
  private sessionStore: SessionStore;
  private renameTimer: ReturnType<typeof setInterval> | null = null;

  constructor(config: AppConfig, private onChange: () => void, store = new SessionStore()) {
    this.config = config;
    this.sessionStore = store;
  }

  /**
   * The provider the app is configured to use. Rebuilt on each read so
   * switching provider in Settings takes effect without rebuilding anything.
   */
  get provider(): VMProvider {
    return this.providerFor(this.config.data.provider);
  }

  providerFor(id: VMProviderID): VMProvider {
    if (id === "exe") return new ExeProvider(() => this.config.tokenFor("exe"));
    return new SpritesProvider(() => this.config.tokenFor("sprites"));
  }

  get selectedSession(): TerminalSession | null {
    return this.sessions.find((session) => session.id === this.selectedSessionID) ?? null;
  }

  /**
   * Tell each session whether it is the one on screen, so output arriving in a
   * background session can be flagged as unseen.
   */
  private syncForeground(): void {
    for (const session of this.sessions) {
      session.setForeground(session.id === this.selectedSessionID);
    }
  }

  /** Known VMs that aren't already open as a tab. */
  get unopenedVMs(): RemoteVMRecord[] {
    const open = new Set(
      this.sessions.map((session) => session.destination).filter((one): one is string =>
        one !== null
      ),
    );
    return this.availableVMs.filter((vm) => !open.has(vm.destination));
  }

  makeProvisioner(): SessionProvisioner {
    return new SessionProvisioner(this.provider, this.config, this.onChange);
  }

  /** The commit identity to seed on a VM, if the GitHub user is known. */
  get gitIdentity(): { name: string; email: string } | null {
    if (!this.githubUser) return null;
    return {
      name: userDisplayName(this.githubUser),
      email: userNoreplyEmail(this.githubUser),
    };
  }

  // MARK: - Loading

  async loadGitHubUser(): Promise<void> {
    this.githubUser = await currentGitHubUser();
    this.onChange();
  }

  /**
   * Refresh the list of existing VMs. Deliberately does *not* connect to or
   * select any of them.
   */
  async loadAvailableVMs(): Promise<void> {
    if (!this.config.effectiveToken) return;
    this.loadingVMs = true;
    this.onChange();
    try {
      this.availableVMs = await this.provider.listVMs();
      this.vmListError = null;
    } catch (error) {
      // The last known VMs stay on screen — they probably still exist — but the
      // reason goes in the sidebar, where the missing ones would have been.
      this.vmListError = failureReason(error);
    }
    this.loadingVMs = false;
    this.onChange();
  }

  // MARK: - Sessions

  addSession(options: {
    title: string;
    provider: VMProvider;
    destination: string | null;
    bootstrap: string;
    vmName?: string | null;
    webURL?: string | null;
    autoName?: boolean;
    persist?: boolean;
  }): TerminalSession {
    const session = new TerminalSession({
      title: options.title,
      provider: options.provider,
      destination: options.destination,
      bootstrap: options.bootstrap,
      vmName: options.vmName ?? null,
      webURL: options.webURL ?? null,
      autoNameArmed: options.autoName ?? false,
    }, this.onChange);
    this.sessions.push(session);
    this.selectedSessionID = session.id;
    this.syncForeground();
    session.start();
    if (options.persist !== false) this.persistSessions();
    this.onChange();
    return session;
  }

  /**
   * The bootstrap run when connecting to an already-provisioned VM. Repos are
   * already cloned, so it only re-applies the idempotent setup steps.
   *
   * Auto-naming isn't armed here — that is a decision made once, when the VM is
   * created, and the VM has been carrying it ever since. Its wiring is
   * re-applied regardless, by the bootstrap itself.
   */
  private reconnectBootstrap(provider: VMProvider): string {
    const environment = this.config.selectedEnvironment;
    const model = this.config.data.model;
    const gateway: GatewaySelection | null = model
      ? { model, wiring: provider.harnessWiring(model) }
      : null;
    return bootstrapCommand({
      setupScript: environment.setupScript,
      claudeSettings: this.config.data.claudeSettings,
      repos: [],
      startCommand: environment.startCommand,
      gitIdentity: this.gitIdentity,
      gateway,
    });
  }

  /** Restore the tabs that were open when the app last quit. */
  restoreSessions(): void {
    if (this.sessions.length > 0) return;
    const stored = this.sessionStore.load();
    const known = new Set(this.availableVMs.map((vm) => vm.destination));
    const entries = restorable(stored.sessions, known);
    if (entries.length === 0) return;

    for (const entry of entries) {
      const provider = this.providerFor(entry.provider);
      this.addSession({
        title: entry.title,
        provider,
        destination: entry.destination,
        bootstrap: this.reconnectBootstrap(provider),
        vmName: entry.vmName,
        persist: false,
      });
    }
    const selected = restorableSelection(stored.selected, entries);
    this.selectedSessionID =
      this.sessions.find((session) => session.destination === selected)?.id ??
        this.sessions[0]?.id ?? null;
    this.persistSessions();
  }

  /**
   * Write the open VM tabs out. Local shells aren't restorable, so they're left
   * out rather than reopening as something they weren't.
   */
  private persistSessions(): void {
    const workspace: PersistedWorkspace = {
      sessions: this.sessions
        .filter((session) => session.destination !== null)
        .map((session) => ({
          destination: session.destination!,
          title: session.title,
          vmName: session.vmName,
          provider: session.provider.id,
        })),
      selected: this.selectedSession?.destination ?? null,
    };
    this.sessionStore.save(workspace);
  }

  /**
   * Reconnect to an existing VM, running the same bootstrap so the setup script
   * and clones are re-applied idempotently.
   */
  reopen(vm: RemoteVMRecord): void {
    if (!vm.destination) return;
    // If this VM already has a tab, just focus it.
    const existing = this.sessions.find((session) => session.destination === vm.destination);
    if (existing) {
      this.selectSession(existing.id);
      return;
    }
    const provider = this.provider;
    this.addSession({
      title: vm.name,
      provider,
      destination: vm.destination,
      bootstrap: this.reconnectBootstrap(provider),
      vmName: vm.name,
      webURL: vm.webURL,
    });
  }

  /** A plain local shell tab — handy when offline or without a token. */
  newLocalSession(): void {
    this.addSession({
      title: "Local",
      provider: this.provider,
      destination: null,
      // No bootstrap script on the local machine: this is a shell, not a
      // provisioned VM, so it goes straight into tmux control mode.
      bootstrap: controlModeCommand("", null, LOCAL_TMUX_SESSION),
      persist: false,
    });
  }

  closeSession(session: TerminalSession): void {
    const index = this.sessions.findIndex((entry) => entry.id === session.id);
    if (index === -1) return;
    session.stop();
    this.sessions.splice(index, 1);
    if (this.selectedSessionID === session.id) {
      this.selectedSessionID = (this.sessions[index] ?? this.sessions[this.sessions.length - 1])
        ?.id ?? null;
    }
    this.syncForeground();
    this.persistSessions();
    this.onChange();
  }

  /**
   * Destroy a VM that has no tab open, without connecting to it first.
   * Irreversible — the VM's disk and anything uncommitted on it are lost.
   */
  async deleteVM(vm: RemoteVMRecord): Promise<void> {
    // Drop it from the sidebar immediately; the refresh below is the authority
    // if the delete actually failed.
    this.availableVMs = this.availableVMs.filter((entry) => entry.name !== vm.name);
    this.onChange();
    try {
      await this.provider.deleteVM(vm.name);
    } catch {
      // The refresh is the authority.
    }
    await this.loadAvailableVMs();
  }

  /**
   * Close the tab *and* destroy the backing VM. Irreversible — the VM's disk
   * and anything uncommitted on it are lost.
   */
  async deleteSession(session: TerminalSession): Promise<void> {
    const name = session.vmName;
    const provider = session.provider;
    this.closeSession(session);
    if (!name) return;
    try {
      await provider.deleteVM(name);
    } catch {
      // The refresh below is the authority.
    }
    await this.loadAvailableVMs();
  }

  // MARK: - Selection

  selectSession(id: string): void {
    if (this.selectedSessionID === id) return;
    this.selectedSessionID = id;
    this.syncForeground();
    this.persistSessions();
    this.onChange();
  }

  /** Select the tab bound to Alt+1…Alt+9. */
  selectSessionByShortcut(number: number): void {
    const index = indexForShortcut(number, this.sessions.length);
    if (index === null) return;
    this.selectSession(this.sessions[index].id);
  }

  /** Move the selection forwards or backwards through the tabs, wrapping. */
  selectAdjacentSession(offset: number): void {
    const current = this.sessions.findIndex((session) => session.id === this.selectedSessionID);
    const index = indexFrom(current === -1 ? null : current, offset, this.sessions.length);
    if (index === null) return;
    this.selectSession(this.sessions[index].id);
  }

  // MARK: - Renames and recovery

  /**
   * Keep the sidebar and the stored workspace on the names the VMs actually
   * have. A session created without a name is named by its VM, from the agent's
   * first prompt, and nothing tells the app when.
   *
   * Each pass is one cheap command per connected VM over the connection the
   * terminal already holds. Providers without auto-naming are skipped — their
   * VMs never rename.
   */
  startRenamePolling(): void {
    if (this.renameTimer !== null) return;
    this.renameTimer = setInterval(() => void this.adoptVMRenames(), RENAME_POLL_MS);
  }

  stopRenamePolling(): void {
    if (this.renameTimer !== null) clearInterval(this.renameTimer);
    this.renameTimer = null;
  }

  private async adoptVMRenames(): Promise<void> {
    let renamed = false;
    for (const session of this.sessions) {
      if (session.isDisconnected || session.destination === null) continue;
      const command = session.provider.reflectionNameCommand;
      if (!session.provider.supportsAutoNaming || !command) continue;
      const output = await runRemote(session.transport, command);
      if (output === null) continue;
      const name = session.provider.parseReflectedName(output);
      if (name && session.adoptVMName(name)) renamed = true;
    }
    if (!renamed) return;
    this.persistSessions();
    this.onChange();
    // The sidebar's list of VMs to reopen still holds the old name.
    await this.loadAvailableVMs();
  }

  /** Re-establish any dropped connections. */
  reconnectDisconnectedSessions(): void {
    for (const session of this.sessions) {
      if (session.isDisconnected) session.reconnect();
    }
  }

  /** Stop every session's process — called on the way out. */
  shutdown(): void {
    this.stopRenamePolling();
    for (const session of this.sessions) session.stop();
  }
}
