import { EnvVar, envVarsFrom } from "./env-var.ts";
import { PI_PACKAGE } from "../model/bootstrap.ts";

/**
 * The pi installer this app used to write into the pi environment's setup
 * script, and what it becomes.
 *
 * pi.dev's install script is a terminal program — it prompts, and a bootstrap
 * has no one to answer — so the app stopped using it. But a setup script is
 * configuration the user owns: the old line is stored in every install that
 * ever ran that version, where changing a default would never reach it. So it
 * is rewritten on the way in, and only when it is still exactly what the app
 * put there.
 *
 * Installing pi is the bootstrap's job now, which makes this line redundant
 * rather than wrong: it finds pi already installed and does nothing.
 */
const LEGACY_PI_SETUP =
  "command -v pi >/dev/null 2>&1 || curl -fsSL https://pi.dev/install.sh | sh";

export const PI_SETUP_SCRIPT =
  `command -v pi >/dev/null 2>&1 || npm install -g --ignore-scripts ${PI_PACKAGE}`;

/** Rewrite a stored setup script the app has since changed its mind about. */
export function migrateSetupScript(script: string): string {
  return script.trim() === LEGACY_PI_SETUP ? PI_SETUP_SCRIPT : script;
}

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
 * The setup script installs pi. The bootstrap does that too, and does it first,
 * so this line finds pi already there and does nothing — but it is here to be
 * read and changed: someone who wants a different version, a private registry,
 * or something else installed alongside has somewhere obvious to say so. It is
 * also what a reset restores, which is the same text an older install's script
 * is migrated to.
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
      setupScript: PI_SETUP_SCRIPT,
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
    setupScript: migrateSetupScript(
      typeof entry.setupScript === "string" ? entry.setupScript : "",
    ),
    startCommand: typeof entry.startCommand === "string" ? entry.startCommand : "",
    environment: envVarsFrom(entry.environment),
  };
}
