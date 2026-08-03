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
 * What a fresh install starts with: pi, and nothing else. Anything else is
 * added in Settings.
 *
 * There is no setup script, because installing pi is the bootstrap's job now —
 * on every provider, including one whose image is bare. A setup script is
 * configuration the user owns, and a default stored in an existing install is
 * never revisited, which is the wrong place for something that has to work.
 *
 * Claude Code and Codex were here too, and an install that has them keeps them:
 * only what a *fresh* config starts with is decided here.
 *
 * The ids are fixed rather than generated, so a config file that records only
 * which environment is selected still points at the same one after a restart.
 */
export function defaultEnvironments(): SessionEnvironment[] {
  return [
    {
      id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000003",
      name: "pi",
      setupScript: "",
      startCommand: "pi",
      environment: [],
    },
  ];
}

/**
 * Every environment this app has ever shipped as a default, including the two
 * it no longer starts with.
 *
 * Kept because "is this stored entry an untouched built-in?" is how a config
 * written by the Swift app is stopped from growing a second copy of each — and
 * an entry stops being recognisable the moment its built-in is forgotten. What
 * a *fresh* install starts with is `defaultEnvironments`; this is only for
 * recognising what's already there.
 */
export function builtInEnvironments(): SessionEnvironment[] {
  return [
    ...defaultEnvironments(),
    {
      id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000001",
      name: "Claude Code",
      setupScript: "",
      startCommand: "claude",
      environment: [{ key: "CLAUDE_CODE_OAUTH_TOKEN", value: "" }],
    },
    {
      id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000002",
      name: "Codex",
      setupScript: "",
      startCommand: "codex",
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
