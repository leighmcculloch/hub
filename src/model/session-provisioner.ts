/**
 * Drives the new-session flow: pick repos, ensure their GitHub access, create a
 * VM tagged for those integrations, and produce the launch descriptor that
 * clones the repos on connect.
 */

import { AppConfig } from "../config/app-config.ts";
import { bootstrapCommand, uniqueVMName } from "./bootstrap.ts";
import { mergeEnv } from "../config/env-var.ts";
import { describe, type GatewayModel } from "./llm-gateway.ts";
import { normalizeRepo } from "../github/repo-reference.ts";
import { cachedRepos, type GitHubRepo, listGitHubRepos } from "../github/repos.ts";
import { TOKEN_VARIABLE, tokenIsStale } from "./auto-name.ts";
import type { GatewaySelection, RemoteVMRecord, VMProvider } from "../providers/types.ts";

export type ProvisionPhase = "picking" | "working" | "failed" | "done";

export interface ProvisionResult {
  destination: string;
  bootstrap: string;
  title: string;
  vmName: string;
  webURL: string | null;
  autoName: boolean;
}

export class SessionProvisioner {
  phase: ProvisionPhase = "picking";

  /** User-supplied name; also used as the VM name. */
  sessionName = "";

  // Existing VMs that can be reopened.
  existingVMs: RemoteVMRecord[] = [];
  loadingVMs = false;

  // Model picker state. The catalogue is remote, so it can be slow or absent;
  // "Custom" is always offered regardless.
  models: GatewayModel[] = [];
  modelsError: string | null = null;
  loadingModels = false;

  // Repo picker state.
  repos: GitHubRepo[] = [];
  reposError: string | null = null;
  loadingRepos = false;
  search = "";
  selected = new Set<string>();
  manualRepo = "";

  // Provisioning state.
  statusLines: string[] = [];
  errorMessage: string | null = null;

  constructor(
    private provider: VMProvider,
    private config: AppConfig,
    private onChange: () => void,
  ) {}

  /**
   * Filtered by the search box, with selected repos hoisted to the top so the
   * current selection stays visible and grouped.
   */
  get filteredRepos(): GitHubRepo[] {
    const needle = this.search.toLowerCase();
    const matching = needle
      ? this.repos.filter((repo) => repo.fullName.toLowerCase().includes(needle))
      : this.repos;
    const chosen = matching.filter((repo) => this.selected.has(repo.fullName));
    const rest = matching.filter((repo) => !this.selected.has(repo.fullName));
    return [...chosen, ...rest];
  }

  /** The repos to provision: checked ones plus a manually typed one. */
  get chosenRepos(): string[] {
    const set = new Set(this.selected);
    const manual = normalizeRepo(this.manualRepo);
    if (manual) set.add(manual);
    return [...set].sort();
  }

  /** Whether the typed text will be used, for the hint under the field. */
  get manualRepoIsUsable(): boolean {
    return this.manualRepo.trim() === "" || normalizeRepo(this.manualRepo) !== null;
  }

  /**
   * The catalogue plus whatever is already selected: a model that has since
   * left the catalogue would otherwise leave the picker showing nothing.
   */
  get modelOptions(): GatewayModel[] {
    const selected = this.config.data.model;
    if (!selected) return this.models;
    const present = this.models.some((model) =>
      model.provider === selected.provider && model.model === selected.model
    );
    return present ? this.models : [...this.models, selected];
  }

  toggleRepo(fullName: string): void {
    if (this.selected.has(fullName)) this.selected.delete(fullName);
    else this.selected.add(fullName);
    this.onChange();
  }

  async loadModels(): Promise<void> {
    this.loadingModels = true;
    this.onChange();
    const result = await this.provider.listModels();
    this.models = result.models;
    this.modelsError = result.error;
    this.loadingModels = false;
    this.onChange();
  }

  async loadRepos(): Promise<void> {
    // Show the last fetch right away so the picker isn't blank while the
    // network answers; the list refreshes seamlessly when this returns.
    if (this.repos.length === 0) {
      const cached = cachedRepos();
      if (cached) this.repos = cached;
    }
    this.loadingRepos = true;
    this.onChange();
    const result = await listGitHubRepos();
    this.loadingRepos = false;
    if (result.error === null) {
      this.repos = result.repos;
      this.reposError = null;
    } else if (this.repos.length === 0) {
      // Nothing cached to fall back on — show the failure.
      this.reposError = result.error;
    } else {
      // A stale list beats a blank one, so keep the cached repos and drop the
      // error rather than wiping the picker on a transient failure.
      this.reposError = null;
    }
    this.onChange();
  }

  /** Existing VMs on the account, offered for reconnection. */
  async loadExistingVMs(): Promise<void> {
    this.loadingVMs = true;
    this.onChange();
    try {
      this.existingVMs = await this.provider.listVMs();
    } catch {
      this.existingVMs = [];
    }
    this.loadingVMs = false;
    this.onChange();
  }

  /**
   * Run provisioning. On success returns the launch descriptor and a tab title;
   * on failure sets `errorMessage` and returns null. Repos are optional — a
   * session with none is just a bare VM.
   */
  async provision(gitIdentity: { name: string; email: string } | null): Promise<
    ProvisionResult | null
  > {
    const chosen = this.chosenRepos;

    this.phase = "working";
    this.statusLines = [];
    this.errorMessage = null;
    this.onChange();

    try {
      this.log(
        `Preparing GitHub access for ${chosen.length} repo${chosen.length === 1 ? "" : "s"}…`,
      );
      const setup = await this.provider.prepareGitHub(chosen);
      const tags = setup.tags;

      // Re-read the VM list rather than trusting `existingVMs`, which is only
      // populated while the reconnect list is on screen. A failed lookup just
      // means no names to avoid.
      const taken = new Set(
        await this.provider.listVMs().then((vms) => vms.map((vm) => vm.name)).catch(() => []),
      );
      const vmName = uniqueVMName(this.sessionName, taken);
      const environment = this.config.selectedEnvironment;
      const model = this.config.data.model;
      const gateway: GatewaySelection | null = model
        ? { model, wiring: this.provider.harnessWiring(model) }
        : null;

      // A session nobody named gets its name from the work: the VM renames
      // itself once the agent has a prompt to name it after. A name that was
      // typed is left alone, hostname and all. Providers without auto-naming
      // never arm, so an unnamed sprites session keeps its generated name.
      const unnamed = this.sessionName.trim() === "";
      const autoNameToken = unnamed && this.provider.supportsAutoNaming
        ? await this.renameToken()
        : null;

      // The model's variables come last so they win: pointing Claude Code at
      // the gateway means blanking the token the environment sets.
      const merged = mergeEnv([
        this.config.data.globalEnvironment,
        environment.environment,
        setup.cloneEnvironment,
        gateway?.wiring.hostEnvironment ?? [],
        autoNameToken ? [{ key: TOKEN_VARIABLE, value: autoNameToken }] : [],
      ]);

      let creating = `Creating VM ${vmName} (tags: ${tags.join(", ")}`;
      creating += `; environment: ${environment.name}`;
      if (model) creating += `; model: ${model.provider}/${model.model}`;
      if (merged.length > 0) {
        creating += `; env: ${merged.map((variable) => variable.key).join(", ")}`;
      }
      this.log(`${creating})…`);

      const vm = await this.provider.createVM(vmName, tags, merged);
      this.log(`VM ready at ${vm.destination}. Opening session…`);

      const bootstrap = bootstrapCommand({
        setupScript: environment.setupScript,
        claudeSettings: this.config.data.claudeSettings,
        repos: chosen,
        clone: setup.clone,
        startCommand: environment.startCommand,
        gitIdentity,
        gateway,
        hostEnvironmentSetup: this.provider.hostEnvironmentSetup(merged),
        autoName: autoNameToken !== null,
      });
      this.phase = "done";
      this.onChange();

      const trimmed = this.sessionName.trim();
      return {
        destination: vm.destination,
        bootstrap,
        title: trimmed || vmName,
        vmName,
        webURL: vm.webURL,
        autoName: autoNameToken !== null,
      };
    } catch (error) {
      this.errorMessage = describe(error);
      this.phase = "failed";
      this.onChange();
      return null;
    }
  }

  /**
   * The token a VM renames itself with, cached between sessions: minting it
   * creates a key on the account, so one is reused until it nears expiry.
   *
   * Null when the account's token may not mint one. Auto-naming is a
   * convenience, so that costs the name and nothing else — the session is
   * created either way, with a line on the log saying what to change.
   */
  private async renameToken(): Promise<string | null> {
    const cached = this.config.data.renameToken;
    if (cached && !tokenIsStale(this.config.data.renameTokenMinted)) return cached;
    this.log("Minting a rename-only token, so the VM can name itself…");
    try {
      const token = await this.provider.generateRenameToken();
      this.config.data.renameToken = token;
      this.config.data.renameTokenMinted = Date.now();
      this.config.save();
      return token;
    } catch (error) {
      this.log(
        `Auto-naming off (${describe(error)}) — add \`ssh-key generate-api-key\`` +
          ` to your exe.dev token's cmds.`,
      );
      return null;
    }
  }

  private log(line: string): void {
    this.statusLines.push(line);
    this.onChange();
  }
}
