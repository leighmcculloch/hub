/**
 * One VM provider's behaviour: how to list, create and delete VMs; how to set
 * up GitHub cloning; how to reach a model gateway; and how to run commands on a
 * VM. The rest of the app talks to this instead of any one service, so a second
 * provider (sprites.dev) is an additional implementation rather than a fork.
 */

import type { EnvVar } from "../config/env-var.ts";
import type { GatewayModel } from "../model/llm-gateway.ts";
import type { CloneConfig } from "../model/bootstrap.ts";

/**
 * Which VM provider a session runs on. Persisted per session so a stored tab
 * reconnects the same way it was opened, even after the active provider in
 * Settings has changed.
 */
export type VMProviderID = "exe" | "sprites" | "namespace";

/**
 * How a provider is authenticated — and what the UI has to say when it isn't.
 *
 * exe.dev and sprites.dev take an API token, which Settings can hold and an
 * environment variable can supply. Namespace's login lives inside its own
 * `devbox` CLI: there is no token to paste, so "configured" means that CLI is
 * installed and logged in, and the fix for "it isn't" is a command to run
 * rather than a field to fill.
 */
export type ProviderCredential =
  | { kind: "token"; envVar: string }
  | { kind: "cli"; binary: string; loginCommand: string };

/**
 * Whether a thrown failure means the credential itself is no longer good, as
 * opposed to the request being wrong. Read structurally so the workspace needn't
 * know one provider's error class from another's.
 */
export function isCredentialFailure(error: unknown): boolean {
  return typeof error === "object" && error !== null &&
    (error as { credentialFailure?: unknown }).credentialFailure === true;
}

/**
 * The configuration a chosen gateway model needs, per provider. exe.dev's
 * gateway is `https://llm.int.exe.xyz`; sprites.dev reaches OpenRouter through
 * an on-sprite proxy. Both share the logic in `llm-gateway.ts`.
 */
export interface LLMGatewayConfig {
  baseURL: string;
  /**
   * The name written into Codex's `model_provider` and pi's `providers` map,
   * and the marker that says a config file on the VM is ours to rewrite.
   */
  providerName: string;
  catalogURL: string;
}

/** exe.dev's gateway, shared by the provider and the tests. */
export const EXE_GATEWAY: LLMGatewayConfig = {
  baseURL: "https://llm.int.exe.xyz",
  providerName: "exe-llm",
  catalogURL: "https://exe.dev/llm-gateway-models.json",
};

/**
 * How a chosen model is wired into the VM's harnesses. Each provider builds
 * one: exe.dev points the harnesses at `llm.int.exe.xyz`; sprites.dev points
 * them at an on-sprite proxy, and includes the shell fragment that starts it.
 */
export interface HarnessWiring {
  /** The marker that says a config file on the VM is ours to rewrite. */
  marker: string;
  /** Shell fragment run before the harness config is written. */
  setup: string;
  /** Variables set on the VM host, so every process sees them. */
  hostEnvironment: EnvVar[];
  /** `~/.codex/config.toml` contents. */
  codexConfig: string;
  /** The `providers` entry merged into `~/.pi/agent/models.json` (JSON). */
  piProvider: string;
  /** The keys merged into `~/.pi/agent/settings.json` (JSON). */
  piSettings: string;
}

/**
 * A model chosen from a provider's gateway catalogue, paired with that
 * provider's harness wiring for it. Bundled so the bootstrap can't be handed a
 * model without the wiring its harness configuration depends on.
 */
export interface GatewaySelection {
  model: GatewayModel;
  wiring: HarnessWiring;
}

/**
 * A VM, as the app cares about it regardless of provider: a name to show and
 * delete by, a `destination` the transport connects to (an SSH host for
 * exe.dev, a sprite name for sprites.dev), and an optional public web URL.
 */
export interface RemoteVMRecord {
  name: string;
  destination: string;
  webURL: string | null;
  status: string | null;
  /**
   * Which provider this VM lives on. Carried on the record because both
   * providers are listed at once when both are configured, and reopening or
   * deleting one has to reach the account it actually belongs to.
   */
  provider: VMProviderID;
}

/**
 * What cloning the chosen repos on a new VM takes. exe.dev brokers GitHub
 * access through an integration bound by a tag and a proxy URL; sprites.dev
 * puts credentials in the VM's environment and clones from github.com.
 */
export interface GitHubSetup {
  /** Tags to attach the VM to (exe.dev only; empty for sprites.dev). */
  tags: string[];
  /** Environment variables the VM needs to clone with (sprites.dev only). */
  cloneEnvironment: EnvVar[];
  /** How `git clone` is run: URL prefix, extra auth, and the failure hint. */
  clone: CloneConfig;
}

/**
 * A remote command the transport will run: the executable plus its argv —
 * `ssh` with connection options for exe.dev, `sprite exec …` for sprites.dev.
 */
export interface RemoteProcessSpec {
  executable: string;
  arguments: string[];
}

/**
 * How the app runs commands on a VM. exe.dev uses `ssh` (with ControlMaster
 * multiplexing); sprites.dev uses the `sprite` CLI. Each instance is bound to
 * one destination and produces process specs the callers spawn, plus a one-line
 * summary of a failed command for the UI.
 */
export interface RemoteTransport {
  /** A long-lived interactive session: `tmux -C` runs over this. */
  interactiveSpec(command: string): RemoteProcessSpec;
  /** A one-shot command: the diff sidebar's git calls and the rename poll. */
  oneshotSpec(command: string): RemoteProcessSpec;
  /** One readable line for a failed one-shot, in the provider's vocabulary. */
  summarize(stderr: string, exit: number): string;
}

export interface ModelListing {
  models: GatewayModel[];
  error: string | null;
}

export interface VMProvider {
  readonly id: VMProviderID;
  /** Shown in Settings and the new-session modal. */
  readonly displayName: string;
  /** The public site, for the browser shortcut's fallback address. */
  readonly defaultBrowserURL: string;
  /**
   * Whether sessions on this provider can name themselves from the agent's
   * first prompt. exe.dev can (rename + reflection); sprites.dev cannot.
   */
  readonly supportsAutoNaming: boolean;
  /** Where this provider's credential comes from, for the UI to explain. */
  readonly credential: ProviderCredential;
  /**
   * The command that asks a VM its current name (reflection), if the provider
   * supports renaming. null otherwise.
   */
  readonly reflectionNameCommand: string | null;

  /** The API token: the configured value, or the environment fallback. */
  effectiveToken(): string;

  /**
   * Whether the provider can be used right now. Async because a CLI-held login
   * can only be answered by asking the CLI; the workspace probes once and
   * caches, so rendering never waits on it.
   */
  checkAvailable(): Promise<boolean>;

  // LLM gateway
  listModels(): Promise<ModelListing>;
  /**
   * How to point the VM's harnesses at `model`, or null on a provider with no
   * model gateway — Namespace has none, and its agents authenticate
   * themselves, so a model chosen for another provider must not rewrite their
   * configuration.
   */
  harnessWiring(model: GatewayModel): HarnessWiring | null;

  // VM lifecycle
  listVMs(): Promise<RemoteVMRecord[]>;
  createVM(name: string, tags: string[], environment: EnvVar[]): Promise<RemoteVMRecord>;
  deleteVM(name: string): Promise<void>;

  // GitHub
  prepareGitHub(repos: string[]): Promise<GitHubSetup>;

  /**
   * Mint the `rename`-only token a VM renames itself with. Rejects on providers
   * that don't support auto-naming — call only when `supportsAutoNaming`.
   */
  generateRenameToken(): Promise<string>;

  // Naming and reachability
  destinationForVMName(name: string): string;
  webURLForDestination(destination: string): string | null;
  parseReflectedName(output: string): string | null;

  // Transport
  transportFor(destination: string): RemoteTransport;

  /**
   * A shell fragment that injects `environment` onto the VM so every process
   * sees it, for providers that can't set host env at create time. exe.dev sets
   * env via `new --env`, so this is "" and the bootstrap doesn't inject.
   */
  hostEnvironmentSetup(environment: EnvVar[]): string;
}
