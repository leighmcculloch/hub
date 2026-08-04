/**
 * The server's write side: everything the client can ask hub to *do*.
 *
 * Read routes hand back a snapshot and are cheap; these change the world —
 * provisioning a machine, closing a session, saving settings — and so each one
 * ends by letting the workspace's own change signal reach every client. None of
 * them returns the new state: the client asks for that, once, the same way it
 * would after any other change.
 */

import type { AppConfig } from "../config/app-config.ts";
import type { Workspace } from "../model/workspace.ts";
import type { SessionProvisioner } from "../model/session-provisioner.ts";
import type { TerminalSession } from "../model/terminal-session.ts";
import { providerIDFrom } from "../model/provider-label.ts";
import { listGitHubRepos } from "../github/repos.ts";
import { listRepos, repoDiff, repoStatus } from "../git/remote-git.ts";
import type { VMProviderID } from "../providers/types.ts";

/** How a provisioning run looks while it is happening. */
export interface ProvisionView {
  active: boolean;
  phase: string;
  lines: string[];
  error: string | null;
}

/**
 * Creating a session, as a thing with a progress report.
 *
 * Provisioning takes minutes — an image build, a machine, a bootstrap — so the
 * request that starts it returns at once and the client watches this instead.
 * Exactly one runs at a time: two machines being made at once is not a workflow
 * hub has, and pretending otherwise would mean a job table for no one.
 */
export class Provisioning {
  private current: SessionProvisioner | null = null;
  private failure: string | null = null;

  constructor(private workspace: Workspace, private onChange: () => void) {}

  get view(): ProvisionView {
    return {
      active: this.current !== null,
      phase: this.current?.phase ?? "idle",
      lines: this.current?.statusLines ?? [],
      error: this.current?.errorMessage ?? this.failure,
    };
  }

  /** Start a machine. Returns whether there was room to start one. */
  start(options: { provider: VMProviderID; name: string; repos: string[] }): boolean {
    if (this.current) return false;
    this.failure = null;
    const provisioner = this.workspace.makeProvisioner(options.provider);
    provisioner.sessionName = options.name;
    for (const repo of options.repos) provisioner.toggleRepo(repo);
    this.current = provisioner;
    this.onChange();
    void this.run(provisioner, options.provider);
    return true;
  }

  private async run(provisioner: SessionProvisioner, provider: VMProviderID): Promise<void> {
    try {
      const result = await provisioner.provision(this.workspace.gitIdentity);
      if (result) {
        this.workspace.addSession({
          title: result.title,
          provider: this.workspace.providerFor(provider),
          destination: result.destination,
          bootstrap: result.bootstrap,
          vmName: result.vmName,
          webURL: result.webURL,
          autoName: result.autoName,
        });
      }
    } catch (error) {
      this.failure = error instanceof Error ? error.message : String(error);
    } finally {
      // Held one beat past the end so the client's next poll still sees why it
      // failed; a success is already visible as a session in the list.
      if (provisioner.errorMessage === null && this.failure === null) this.current = null;
      this.onChange();
    }
  }

  /** Put a finished run away, so the panel closes. */
  dismiss(): void {
    this.current = null;
    this.failure = null;
    this.onChange();
  }
}

/** The repos the picker offers, from the GitHub account this machine is signed into. */
export async function repoOptions(): Promise<{ repos: string[]; error: string | null }> {
  const listing = await listGitHubRepos();
  return { repos: listing.repos.map((one) => one.fullName), error: listing.error };
}

/** What the diff panel shows for a session: its repos, and one repo's diff. */
export async function diffView(
  session: TerminalSession,
  repo: string | null,
): Promise<{ repos: string[]; repo: string | null; status: string[]; diff: string }> {
  const transport = session.transport;
  const repos = await listRepos(transport);
  const chosen = repo && repos.includes(repo) ? repo : repos[0] ?? null;
  if (!chosen) return { repos, repo: null, status: [], diff: "" };
  const [status, diff] = await Promise.all([
    repoStatus(transport, chosen)
      .then((one) => one.changes.map((change) => `${change.status} ${change.path}`))
      .catch(() => [] as string[]),
    repoDiff(transport, chosen).catch(() => ""),
  ]);
  return { repos, repo: chosen, status, diff };
}

/** Settings, as the client edits them. */
export interface ConfigView {
  provider: string;
  exeToken: string;
  spritesToken: string;
  piSettings: string;
  environments: Array<{ id: string; name: string; startCommand: string; setupScript: string }>;
  selectedEnvironmentID: string | null;
  globalEnvironment: Array<{ key: string; value: string }>;
}

export function configView(config: AppConfig): ConfigView {
  return {
    provider: config.data.provider,
    exeToken: config.data.exeToken,
    spritesToken: config.data.spritesToken,
    piSettings: config.data.piSettings,
    environments: config.data.environments.map((one) => ({
      id: one.id,
      name: one.name,
      startCommand: one.startCommand,
      setupScript: one.setupScript,
    })),
    selectedEnvironmentID: config.selectedEnvironment.id,
    globalEnvironment: config.data.globalEnvironment.map((one) => ({ ...one })),
  };
}

/**
 * Apply an edit from the client, field by field.
 *
 * Only what was sent is changed: the settings window edits one thing at a time,
 * and a whole-object write would let a stale form blank a token someone set in
 * another window a moment ago.
 */
export function applyConfig(config: AppConfig, patch: Partial<ConfigView>): void {
  const provider = patch.provider === undefined ? null : providerIDFrom(patch.provider);
  if (provider) config.data.provider = provider;
  if (typeof patch.exeToken === "string") config.data.exeToken = patch.exeToken.trim();
  if (typeof patch.spritesToken === "string") config.data.spritesToken = patch.spritesToken.trim();
  if (typeof patch.piSettings === "string") config.data.piSettings = patch.piSettings;
  if (typeof patch.selectedEnvironmentID === "string") {
    config.data.selectedEnvironmentID = patch.selectedEnvironmentID;
  }
  if (Array.isArray(patch.globalEnvironment)) {
    config.data.globalEnvironment = patch.globalEnvironment
      .filter((one) => one && typeof one.key === "string" && one.key.trim())
      .map((one) => ({ key: one.key.trim(), value: String(one.value ?? "") }));
  }
  if (Array.isArray(patch.environments)) {
    for (const edited of patch.environments) {
      const stored = config.data.environments.find((one) => one.id === edited.id);
      if (!stored) continue;
      if (typeof edited.name === "string") stored.name = edited.name;
      if (typeof edited.startCommand === "string") stored.startCommand = edited.startCommand;
      if (typeof edited.setupScript === "string") stored.setupScript = edited.setupScript;
    }
  }
  config.save();
}
