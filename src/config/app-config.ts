/**
 * Persisted application configuration, stored as JSON alongside the session
 * list.
 *
 * Decoded field by field so a file written by an older build — or hand-edited,
 * which the format invites — still loads. Each field falls back independently
 * when its value is present but the wrong type: one bad entry should cost that
 * entry, not the token and environments alongside it.
 */

import { EnvVar, envVarsFrom } from "./env-var.ts";
import {
  builtInEnvironments,
  defaultEnvironments,
  SessionEnvironment,
  sessionEnvironmentFrom,
} from "./session-environment.ts";
import { configPath, readJSON, writeJSON } from "./paths.ts";
import type { GatewayModel } from "../model/llm-gateway.ts";
import type { VMProviderID } from "../providers/types.ts";
import { providerIDFrom } from "../model/provider-label.ts";

export const DEFAULT_CLAUDE_SETTINGS = `{
  "theme": "dark",
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "attribution": {
    "commit": "",
    "pr": "",
    "sessionUrl": false
  },
  "remoteControlAtStartup": true,
  "hasCompletedOnboarding": true,
  "disableWorkflows": false,
  "prefersReducedMotion": true,
  "skipDangerousModePermissionPrompt": true
}`;

/**
 * Seeded to `~/.pi/agent/settings.json` on a new machine, and editable in
 * Settings.
 *
 * Thinking blocks are hidden by default: a session here is watched through a
 * terminal pane in a sidebar, where the reasoning costs more room than it
 * repays. It is one key, so turning it back on is one edit.
 */
export const DEFAULT_PI_SETTINGS = `{
  "hideThinkingBlock": true
}`;

export interface AppConfigData {
  /** exe.dev HTTPS API bearer token. */
  exeToken: string;
  /** Which VM provider the app provisions and lists. */
  provider: VMProviderID;
  /** sprites.dev HTTPS API bearer token. */
  spritesToken: string;
  /** A `rename`-only exe.dev token, handed to VMs that name themselves. */
  renameToken: string;
  /** When it was minted, as epoch milliseconds. */
  renameTokenMinted: number | null;
  environments: SessionEnvironment[];
  selectedEnvironmentID: string | null;
  /** The gateway model new sessions are pointed at; null is "Custom". */
  model: GatewayModel | null;
  /** Variables set on each new VM host, whichever environment it runs. */
  globalEnvironment: EnvVar[];
  /** Written to `~/.claude/settings.json` on each new VM during bootstrap. */
  claudeSettings: string;
  /** Written to `~/.pi/agent/settings.json` on each new VM during bootstrap. */
  piSettings: string;
}

export function defaultConfigData(): AppConfigData {
  return {
    exeToken: "",
    provider: "exe",
    spritesToken: "",
    renameToken: "",
    renameTokenMinted: null,
    environments: defaultEnvironments(),
    selectedEnvironmentID: null,
    model: null,
    globalEnvironment: [],
    claudeSettings: DEFAULT_CLAUDE_SETTINGS,
    piSettings: DEFAULT_PI_SETTINGS,
  };
}

export function decodeConfig(raw: unknown): AppConfigData {
  const defaults = defaultConfigData();
  if (typeof raw !== "object" || raw === null) return defaults;
  const entry = raw as Record<string, unknown>;

  const text = (key: string, fallback: string) =>
    typeof entry[key] === "string" ? entry[key] as string : fallback;

  const environments = Array.isArray(entry.environments)
    ? entry.environments.map(sessionEnvironmentFrom).filter((one): one is SessionEnvironment =>
      one !== null
    )
    : [];

  // An empty list would leave nothing to select or edit, so it's treated as
  // absent rather than honoured. A stored list keeps every edit it carries, but
  // gains any default that has been added since it was written — those have
  // fixed ids precisely so a new one can be recognised as missing.
  const reconciled = environments.length > 0
    ? reconcileDefaults(environments)
    : { environments: defaults.environments, moved: new Map<string, string>() };

  const storedSelection = typeof entry.selectedEnvironmentID === "string"
    ? entry.selectedEnvironmentID
    : null;

  return {
    exeToken: text("exeToken", defaults.exeToken),
    // An unknown provider — a file from a newer build, or a typo — falls back
    // to exe.dev rather than leaving the app pointed at nothing.
    provider: providerIDFrom(entry.provider) ?? defaults.provider,
    spritesToken: text("spritesToken", defaults.spritesToken),
    renameToken: text("renameToken", defaults.renameToken),
    renameTokenMinted: decodeMinted(entry.renameTokenMinted),
    environments: reconciled.environments,
    // A selection pointing at a duplicate that was just removed follows the
    // entry that replaced it, rather than silently falling back to the first.
    selectedEnvironmentID: storedSelection === null
      ? null
      : reconciled.moved.get(storedSelection.toLowerCase()) ?? storedSelection,
    model: decodeModel(entry.model),
    globalEnvironment: envVarsFrom(entry.globalEnvironment),
    claudeSettings: text("claudeSettings", defaults.claudeSettings),
    piSettings: text("piSettings", defaults.piSettings),
  };
}

/**
 * UUIDs are case-insensitive, and this config file has been written by two
 * programs that disagree about the case: Swift's `UUID.uuidString` is upper
 * case, this app writes lower case. Comparing them literally is what made an
 * upgraded install grow a second "Claude Code".
 */
export function sameEnvironmentID(left: string, right: string): boolean {
  return left.toLowerCase() === right.toLowerCase();
}

/** Whether an environment is an untouched copy of a built-in, id aside. */
function isPristine(environment: SessionEnvironment, builtIn: SessionEnvironment): boolean {
  return environment.name === builtIn.name &&
    environment.setupScript === builtIn.setupScript &&
    environment.startCommand === builtIn.startCommand &&
    environment.environment.length === builtIn.environment.length &&
    environment.environment.every((variable, index) =>
      variable.key === builtIn.environment[index].key &&
      variable.value === builtIn.environment[index].value
    );
}

/**
 * The stored environments, minus duplicates an earlier build added, plus any
 * built-in they predate.
 *
 * Appended rather than merged: an environment the user has edited keeps every
 * edit, and one they deleted stays deleted only until the next upgrade — which
 * is the trade that lets a new default (pi, say) reach existing installs at
 * all.
 *
 * The removal half repairs the damage from comparing ids case-sensitively: a
 * config written by the Swift app carries upper-case ids, so every built-in
 * looked missing and was appended beside the one already there. Only an
 * *untouched* copy of a built-in that shares its name with an earlier entry is
 * dropped, so nothing the user has edited can be lost. `moved` reports what was
 * removed and what stood in its place, so a selection pointing at the casualty
 * follows the survivor.
 */
function reconcileDefaults(
  stored: SessionEnvironment[],
): { environments: SessionEnvironment[]; moved: Map<string, string> } {
  const defaults = defaultEnvironments();
  const known = builtInEnvironments();
  const moved = new Map<string, string>();

  const kept = stored.filter((environment, index) => {
    const builtIn = known.find((one) => sameEnvironmentID(one.id, environment.id));
    if (!builtIn || !isPristine(environment, builtIn)) return true;
    const earlier = stored.find((other, at) => at < index && other.name === environment.name);
    if (!earlier) return true;
    moved.set(environment.id.toLowerCase(), earlier.id);
    return false;
  });

  const present = new Set(kept.map((one) => one.id.toLowerCase()));
  const names = new Set(kept.map((one) => one.name));
  // Both an id and a name have to be new for a built-in to be worth adding: an
  // id can drift, and adding a second environment by the same name is exactly
  // the bug this is repairing.
  const added = defaults.filter((one) =>
    !present.has(one.id.toLowerCase()) && !names.has(one.name)
  );
  return { environments: added.length === 0 ? kept : [...kept, ...added], moved };
}

/** Accepts both the epoch number this app writes and the ISO date Swift wrote. */
function decodeMinted(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
  }
  return null;
}

function decodeModel(value: unknown): GatewayModel | null {
  if (typeof value !== "object" || value === null) return null;
  const entry = value as Record<string, unknown>;
  if (typeof entry.provider !== "string" || typeof entry.model !== "string") return null;
  return { provider: entry.provider, model: entry.model };
}

/**
 * Loads and persists `AppConfigData`. One instance is shared by the workspace,
 * the settings modal and the new-session modal, so a change made in one is
 * visible everywhere at once.
 */
export class AppConfig {
  data: AppConfigData;
  private path = configPath("config.json");

  private constructor(data: AppConfigData) {
    this.data = data;
  }

  static load(): AppConfig {
    return new AppConfig(decodeConfig(readJSON<unknown>(configPath("config.json"))));
  }

  save(): void {
    writeJSON(this.path, this.data);
  }

  /**
   * The environment new sessions run. Falls back to the first one, so a stale
   * or missing selection still yields something runnable.
   */
  get selectedEnvironment(): SessionEnvironment {
    const selected = this.data.selectedEnvironmentID;
    const chosen = selected === null
      ? undefined
      : this.data.environments.find((one) => sameEnvironmentID(one.id, selected));
    return chosen ?? this.data.environments[0] ?? {
      id: crypto.randomUUID(),
      name: "",
      setupScript: "",
      startCommand: "",
      environment: [],
    };
  }

  /** The token for the active provider: the configured one, or the fallback. */
  get effectiveToken(): string {
    return this.tokenFor(this.data.provider);
  }

  /**
   * Per-provider so a sprites.dev session opened while exe.dev was active still
   * authenticates with the sprites token.
   *
   * Namespace and Docker have no token at all — one's login lives in the
   * `devbox` CLI, the other has no account — so they have nothing to return
   * here.
   */
  tokenFor(provider: VMProviderID): string {
    switch (provider) {
      case "exe":
        return this.data.exeToken || Deno.env.get("EXE_DEV_TOKEN") || "";
      case "sprites":
        return this.data.spritesToken || Deno.env.get("SPRITE_TOKEN") || "";
      case "namespace":
      case "docker":
        return "";
    }
  }
}
