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
  defaultEnvironments,
  SessionEnvironment,
  sessionEnvironmentFrom,
} from "./session-environment.ts";
import { configPath, readJSON, writeJSON } from "./paths.ts";
import type { GatewayModel } from "../model/llm-gateway.ts";
import type { VMProviderID } from "../providers/types.ts";

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

  return {
    exeToken: text("exeToken", defaults.exeToken),
    provider: entry.provider === "sprites" ? "sprites" : "exe",
    spritesToken: text("spritesToken", defaults.spritesToken),
    renameToken: text("renameToken", defaults.renameToken),
    renameTokenMinted: decodeMinted(entry.renameTokenMinted),
    // An empty list would leave nothing to select or edit, so it's treated as
    // absent rather than honoured.
    environments: environments.length > 0 ? environments : defaults.environments,
    selectedEnvironmentID: typeof entry.selectedEnvironmentID === "string"
      ? entry.selectedEnvironmentID
      : null,
    model: decodeModel(entry.model),
    globalEnvironment: envVarsFrom(entry.globalEnvironment),
    claudeSettings: text("claudeSettings", defaults.claudeSettings),
  };
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
    const chosen = this.data.environments.find((one) => one.id === this.data.selectedEnvironmentID);
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
   */
  tokenFor(provider: VMProviderID): string {
    if (provider === "exe") {
      return this.data.exeToken || Deno.env.get("EXE_DEV_TOKEN") || "";
    }
    return this.data.spritesToken || Deno.env.get("SPRITE_TOKEN") || "";
  }
}
