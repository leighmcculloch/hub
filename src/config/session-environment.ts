import { EnvVar, envVarsFrom } from "./env-var.ts";

/**
 * One named way to run a session: the setup script, the command started inside
 * tmux, and environment variables set on the VM host.
 *
 * A session picks one when it is created, so a Claude Code VM and a Codex VM
 * can differ without editing Settings in between.
 */
export interface SessionEnvironment {
  id: string;
  name: string;
  /** Run on the VM as the first command, before the repos are cloned. */
  setupScript: string;
  /** Run inside tmux when the session is first created, e.g. `claude`. */
  startCommand: string;
  /** Set on the VM host on top of the global variables. */
  environment: EnvVar[];
}

/**
 * What a fresh install starts with: the two harnesses this app is used with.
 * Anything else is added in Settings.
 *
 * The ids are fixed rather than generated, so a config file that records only
 * which environment is selected still points at the same one after a restart.
 */
export function defaultEnvironments(): SessionEnvironment[] {
  return [
    {
      id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000001",
      name: "Claude Code",
      setupScript: "",
      startCommand: "claude",
      // Present but blank on purpose: it's the variable to paste a token into,
      // and an empty row is the prompt to do so.
      environment: [{ key: "CLAUDE_CODE_OAUTH_TOKEN", value: "" }],
    },
    {
      id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000002",
      name: "Codex",
      setupScript: "",
      startCommand: "codex",
      environment: [],
    },
    {
      id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000003",
      name: "pi",
      // The pi.dev CLI isn't on the VM images, so the setup step installs it;
      // the installer is idempotent, and this runs again on every reconnect.
      setupScript: "command -v pi >/dev/null 2>&1 || curl -fsSL https://pi.dev/install.sh | sh",
      startCommand: "pi",
      environment: [],
    },
  ];
}

/**
 * Decode one environment, falling back field by field. A missing or mistyped
 * field costs that field rather than the whole environment.
 */
export function sessionEnvironmentFrom(value: unknown): SessionEnvironment | null {
  if (typeof value !== "object" || value === null) return null;
  const entry = value as Record<string, unknown>;
  return {
    id: typeof entry.id === "string" ? entry.id : crypto.randomUUID(),
    name: typeof entry.name === "string" ? entry.name : "",
    setupScript: typeof entry.setupScript === "string" ? entry.setupScript : "",
    startCommand: typeof entry.startCommand === "string" ? entry.startCommand : "",
    environment: envVarsFrom(entry.environment),
  };
}
