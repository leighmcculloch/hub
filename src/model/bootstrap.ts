/**
 * Pure helpers for turning app configuration into the command run on a VM.
 *
 * Free of any terminal or provider imports, so the script-building — the part
 * that is hard to eyeball and easy to break — can be exercised directly.
 */

import { encodeBase64 } from "@std/encoding/base64";
import { shellQuote } from "./shell.ts";
import * as AutoName from "./auto-name.ts";
import type { GatewaySelection } from "../providers/types.ts";

export { shellQuote };

/**
 * How `git clone` is run on a new VM. exe.dev clones through its
 * `github.int.exe.xyz` proxy, which needs no credentials in the VM;
 * sprites.dev and Namespace clone straight from `github.com` using a token in
 * the VM's environment.
 */
export interface CloneConfig {
  urlPrefix: string;
  /** Extra `git clone` arguments; empty for exe.dev. */
  extraConfig: string;
  failureHint: string;
}

/**
 * Cloning from github.com with the token the VM carries in `$GITHUB_TOKEN`,
 * passed as a header rather than in the URL so it stays out of the remote's
 * config and out of process listings. No token means public repos only.
 *
 * Shared by every provider that has no GitHub brokerage of its own, which is
 * every provider except exe.dev.
 */
export function tokenCloneConfig(token: string | null, failureHint: string): CloneConfig {
  return {
    urlPrefix: "https://github.com",
    extraConfig: token === null ? "" : `-c "http.extraheader=Authorization: Bearer $GITHUB_TOKEN"`,
    failureHint,
  };
}

export const EXE_CLONE: CloneConfig = {
  urlPrefix: "https://github.int.exe.xyz",
  extraConfig: "",
  failureHint: "check their GitHub integration on exe.dev, then clone again.",
};

/** tmux session every VM session attaches to. */
export const TMUX_SESSION = "exe";

/**
 * The local shell's own tmux session. Named apart from the VM one so opening a
 * local shell can't attach to — or create — a session someone is using on this
 * machine for something else.
 */
export const LOCAL_TMUX_SESSION = "hub-local";

export const SCRIPT_PATH = "/tmp/exe-bootstrap.sh";

export const MAX_VM_NAME_LENGTH = 52;

/**
 * A profile the bootstrap writes host env vars into for providers that can't
 * set them at create time (sprites.dev, Namespace). The first window sources it
 * so the harness inherits the vars; for exe.dev the file is never written and
 * the source is a guarded no-op.
 *
 * Named for the provider that needed it first: renaming the file now would
 * strand the profiles already sourcing it from `~/.bashrc` on live VMs.
 */
export const HOST_ENV_FILE = ".sprite-env.sh";

/**
 * Seeded to `~/.claude.json` on a fresh VM. Claude Code keeps onboarding state
 * here rather than in `settings.json`, so this is what actually suppresses the
 * first-run flow. The custom API key the app injects (the literal "implicit")
 * is pre-approved here, so Claude Code never prompts to trust it.
 */
export const CLAUDE_STATE = `{
  "hasCompletedOnboarding": true,
  "customApiKeyResponses": {
    "approved": [
      "implicit"
    ],
    "rejected": []
  }
}`;

/**
 * tmux has to exist before it can be started, and it can no longer be installed
 * by the bootstrap script — that now runs *inside* tmux. Output is discarded
 * because stdout is the control protocol; a failure surfaces as tmux failing to
 * start, with the transport's stderr shown on the session.
 */
export const INSTALL_TMUX = "command -v tmux >/dev/null 2>&1 ||" +
  " { sudo apt-get update -qq >/dev/null 2>&1 &&" +
  " sudo apt-get install -y -qq tmux >/dev/null 2>&1; } || true;";

/**
 * Terminals send the kitty keyboard protocol for modified keys (Shift+Enter,
 * Shift+Tab), but tmux only forwards it to a pane that asks for it first —
 * Claude Code never does, so those keys never reach it. `always` forces tmux to
 * report them unconditionally; `extkeys` is the matching terminal-features flag
 * tmux checks. Seeded here rather than from the bootstrap script because the
 * script runs *inside* tmux, by which time the server has read its config.
 */
export const ENABLE_EXTENDED_KEYS =
  `grep -qs '^set -g extended-keys always$' "$HOME/.tmux.conf" ||` +
  ` echo 'set -g extended-keys always' >> "$HOME/.tmux.conf";` +
  ` grep -qs '^set -as terminal-features .,\\*:extkeys.$' "$HOME/.tmux.conf" ||` +
  ` echo 'set -as terminal-features ",*:extkeys"' >> "$HOME/.tmux.conf";`;

/**
 * Turn a user-supplied session name into a valid VM name, falling back to a
 * generated one when empty.
 *
 * exe.dev rejects anything that isn't "5-52 characters: start with a lowercase
 * letter, then lowercase letters or digits, with optional single hyphen
 * separators" — so this must collapse hyphen runs, strip leading and trailing
 * hyphens, prefix a name starting with a digit, and pad a name that is short.
 */
export function vmNameFrom(sessionName: string): string {
  let name = sessionName.toLowerCase().replace(/[^a-z0-9]/g, "-");
  while (name.includes("--")) name = name.replaceAll("--", "-");
  name = trimHyphens(name);

  // Must begin with a lowercase letter.
  if (!/^[a-z]/.test(name)) name = name === "" ? "" : `vm-${name}`;

  // Long names are truncated; truncation can expose a trailing hyphen.
  if (name.length > MAX_VM_NAME_LENGTH) name = trimHyphens(name.slice(0, MAX_VM_NAME_LENGTH));

  // Minimum length is 5; pad (or generate) with a random suffix.
  if (name.length < 5) {
    const suffix = randomSuffix();
    name = name === "" ? `vm-${suffix}` : `${name}-${suffix}`;
  }
  return name;
}

/**
 * A VM name derived from `sessionName` that isn't one of `existing`.
 *
 * exe.dev rejects a duplicate name outright, so a second session called
 * "review" would otherwise fail with a raw API error after the integrations had
 * already been set up. Numbering the name keeps that invisible.
 */
export function uniqueVMName(sessionName: string, existing: Set<string>): string {
  const base = vmNameFrom(sessionName);
  if (!existing.has(base)) return base;
  for (let counter = 2; counter <= 99; counter += 1) {
    const candidate = appendSuffix(base, String(counter));
    if (!existing.has(candidate)) return candidate;
  }
  // Ninety-eight VMs sharing one name isn't worth counting past.
  return appendSuffix(base, randomSuffix());
}

/**
 * Join `suffix` onto `base` with a hyphen, shortening `base` so the result
 * stays inside the length limit and doesn't end up with a doubled hyphen.
 */
function appendSuffix(base: string, suffix: string): string {
  const room = MAX_VM_NAME_LENGTH - suffix.length - 1;
  return `${trimHyphens(base.slice(0, Math.max(0, room)))}-${suffix}`;
}

function trimHyphens(text: string): string {
  return text.replace(/^-+/, "").replace(/-+$/, "");
}

function randomSuffix(): string {
  return crypto.randomUUID().replaceAll("-", "").slice(0, 6).toLowerCase();
}

export interface BootstrapOptions {
  setupScript: string;
  claudeSettings: string;
  repos: string[];
  clone?: CloneConfig;
  startCommand?: string;
  gitIdentity?: { name: string; email: string } | null;
  gateway?: GatewaySelection | null;
  hostEnvironmentSetup?: string;
  autoName?: boolean;
}

/**
 * Build the remote command run over the transport: write the bootstrap script,
 * make sure tmux is installed and configured, and hand the connection to tmux
 * in control mode.
 *
 * Nothing may print to stdout before tmux does: stdout *is* the control
 * protocol the app parses. So, unlike an interactive attach, the bootstrap
 * script isn't run here — it is the command tmux runs in the session's first
 * window, where its output belongs to a pane and can be watched in a tab.
 *
 * The script is base64-encoded so arbitrary multi-line user content (setup
 * script, settings JSON) survives the trip through argument and remote-shell
 * parsing.
 */
/**
 * The shell fragment that puts host environment variables on a VM whose
 * provider has no API to set them at create time — sprites.dev and Namespace
 * both create a box and hand it over, with no `--env` to pass.
 *
 * The variables are written to a profile and sourced twice: once inside the
 * bootstrap, so the clones see `GITHUB_TOKEN`, and again from the first window,
 * so the harness inherits them. Future login shells pick it up from
 * `~/.profile`/`~/.bashrc`. Values are single-quoted, so a `$` or a backtick in
 * one stays literal instead of being expanded on the way in.
 */
export function profileEnvironmentSetup(
  environment: Array<{ key: string; value: string }>,
): string {
  const exports = environment
    .filter((variable) => variable.key)
    .map((variable) => `export ${variable.key}=${shellQuote(variable.value)}`)
    .join("\n");
  if (!exports) return "";
  return `
cat > "$HOME/${HOST_ENV_FILE}" <<'HOST_ENV_EOF'
${exports}
HOST_ENV_EOF
. "$HOME/${HOST_ENV_FILE}"
for _f in "$HOME/.profile" "$HOME/.bashrc"; do [ -f "$_f" ] || continue; grep -q '${HOST_ENV_FILE}' "$_f" 2>/dev/null || printf '\\n[ -f "$HOME/${HOST_ENV_FILE}" ] && . "$HOME/${HOST_ENV_FILE}"\\n' >> "$_f"; done

`;
}

export function bootstrapCommand(options: BootstrapOptions): string {
  const encoded = encodeBase64(new TextEncoder().encode(bootstrapScript(options)));
  return `printf %s '${encoded}' | base64 -d > ${SCRIPT_PATH}` +
    ` && chmod +x ${SCRIPT_PATH};` +
    ` ${INSTALL_TMUX}` +
    ` ${ENABLE_EXTENDED_KEYS}` +
    ` ${controlModeCommand(options.startCommand ?? "")}`;
}

/**
 * Attach the app to tmux as a control-mode client (`-C`), so each pane's output
 * arrives as a stream the app renders into its own terminal tab.
 *
 * `-A` attaches to the existing session or creates one, so a dropped connection
 * reattaches with work intact. The trailing command runs *only* when the
 * session is created, never on attach, so reconnecting never stacks a second
 * copy of it.
 */
export function controlModeCommand(
  startCommand: string,
  scriptPath: string | null = SCRIPT_PATH,
  session: string = TMUX_SESSION,
): string {
  const trimmed = startCommand.trim();
  // A local shell has no bootstrap script; running one that was never written
  // would print "no such file" as the pane's first line.
  let window = scriptPath === null ? "" : `${scriptPath};`;
  // Re-source the host env profile the bootstrap just wrote, so the start
  // command (and the shell that outlives it) inherit the provider's host
  // environment. Guarded so it's a no-op when the file doesn't exist.
  window += ` [ -f "$HOME/${HOST_ENV_FILE}" ] && . "$HOME/${HOST_ENV_FILE}";`;
  if (trimmed) window += ` ${trimmed};`;
  window += ` exec \${SHELL:-bash} -l`;
  const firstWindow = `\${SHELL:-bash} -l -c ${shellQuote(window)}`;
  return `exec tmux -C new-session -A -s ${session} ${shellQuote(firstWindow)}`;
}

/**
 * The script body that gets base64-encoded into `bootstrapCommand`.
 *
 * `autoName` arms the VM to name itself from the agent's first prompt. Only
 * passed on the connect that *creates* the VM, and only when the session was
 * created without a name; the wiring itself is re-applied on every connect,
 * because a reconnect rewrites the harness configuration it lives in.
 */
export function bootstrapScript(options: BootstrapOptions): string {
  const clone = options.clone ?? EXE_CLONE;
  let script = "#!/usr/bin/env bash\n";

  // Seed the commit identity from the GitHub account, so commits made on the VM
  // are attributed without any manual setup. Only when unset, so a deliberate
  // change on the VM survives reconnects.
  if (options.gitIdentity) {
    script += `git config --global user.name >/dev/null 2>&1 || ` +
      `git config --global user.name ${shellQuote(options.gitIdentity.name)}\n` +
      `git config --global user.email >/dev/null 2>&1 || ` +
      `git config --global user.email ${shellQuote(options.gitIdentity.email)}\n\n`;
  }

  // Seed Claude Code's settings, but never clobber one the user already
  // customized on the VM.
  if (options.claudeSettings.trim()) {
    const encodedSettings = encodeBase64(new TextEncoder().encode(options.claudeSettings));
    // Onboarding state lives in ~/.claude.json (Claude Code's state file), not
    // in settings.json, so seed it there as well or a fresh VM still shows the
    // onboarding flow.
    const encodedState = encodeBase64(new TextEncoder().encode(CLAUDE_STATE));
    script += `mkdir -p "$HOME/.claude"
if [ ! -f "$HOME/.claude/settings.json" ]; then
  printf %s '${encodedSettings}' | base64 -d > "$HOME/.claude/settings.json"
fi
if [ ! -f "$HOME/.claude.json" ]; then
  printf %s '${encodedState}' | base64 -d > "$HOME/.claude.json"
fi

`;
  }

  // Inject host environment for providers that can't set it at create time
  // (sprites.dev writes a profile here and sources it).
  script += options.hostEnvironmentSetup ?? "";

  // Point the harnesses that read a config file at the chosen gateway model.
  // Claude Code needs nothing here: it reads the ANTHROPIC_* variables set on
  // the VM host when it was created.
  if (options.gateway) {
    script += options.gateway.wiring.setup;
    script += harnessConfig(options.gateway);
  }

  // After the harness configuration, which rewrites the very file Codex's half
  // of the wiring goes into.
  if (options.autoName) script += AutoName.ARM_FRAGMENT;
  script += AutoName.installFragment();

  script += options.setupScript;
  script += "\n";

  // Trust $HOME and the directories already on the VM *before* the clones run,
  // so the harness — which starts the moment this script returns — never
  // prompts for $HOME on launch.
  script += TRUST_HOME_DIRECTORIES;

  // Clone in the background so the start command loads without waiting: this
  // script returns as soon as the subshell is launched. `--quiet` keeps a
  // successful clone off the harness's TUI, so only failures surface.
  //
  // One bad repo must not abort the rest of the bootstrap, so failures are
  // collected and reported together at the end. The URL is quoted: repo names
  // reach here from the picker but also from the free-text field.
  if (options.repos.length > 0) {
    script += "(\n";
    script += "exe_failed_clones=''\n";
    for (const repo of options.repos) {
      const url = shellQuote(`${clone.urlPrefix}/${repo}.git`);
      const extra = clone.extraConfig ? ` ${clone.extraConfig}` : "";
      script += `if ! git clone${extra} --depth 1 --quiet ${url}; then
  exe_failed_clones="$exe_failed_clones "${shellQuote(repo)}
fi

`;
    }
    script += `if [ -n "$exe_failed_clones" ]; then
  echo "" >&2
  echo "exe: these repositories did not clone:$exe_failed_clones" >&2
  echo "exe: ${clone.failureHint}" >&2
fi

`;
    // Re-run inside the subshell after the clones so the freshly cloned repos
    // are marked trusted too; it's idempotent.
    script += TRUST_HOME_DIRECTORIES;
    script += ") &\n";
  }
  return script;
}

/**
 * Configure Codex and pi for the selected model.
 *
 * This runs again on every reconnect, so it has to be safe to repeat and safe
 * to change your mind about. pi's two files are merged key by key, leaving
 * other providers and settings alone. Codex has no mergeable format here, so
 * its file is only rewritten when it's absent or already names our provider — a
 * `config.toml` someone wrote themselves is worth more than a model selection.
 *
 * The auto-naming hook counts as ours too: on a session with no model chosen it
 * is the only thing in the file, and treating that as the user's work would
 * refuse them a model ever after.
 */
export function harnessConfig(gateway: GatewaySelection): string {
  const encode = (text: string) => encodeBase64(new TextEncoder().encode(text));
  const codex = encode(gateway.wiring.codexConfig);
  const provider = encode(gateway.wiring.piProvider);
  const settings = encode(gateway.wiring.piSettings);
  const marker = gateway.wiring.marker;

  return `
mkdir -p "$HOME/.codex"
if [ ! -e "$HOME/.codex/config.toml" ] || grep -qF -e ${shellQuote(marker)} -e ${
    shellQuote(AutoName.SCRIPT_NAME)
  } "$HOME/.codex/config.toml"; then
  printf %s '${codex}' | base64 -d > "$HOME/.codex/config.toml"
else
  echo "exe: left ~/.codex/config.toml alone — it doesn't use the ${marker} provider." >&2
fi

python3 - <<'PYEOF' || true
import base64, json, os

directory = os.path.expanduser("~/.pi/agent")
os.makedirs(directory, exist_ok=True)

def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
    return data if isinstance(data, dict) else {}

def save(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

models_path = os.path.join(directory, "models.json")
models = load(models_path)
providers = models.get("providers")
if not isinstance(providers, dict):
    providers = {}
providers.update(json.loads(base64.b64decode("${provider}")))
models["providers"] = providers
save(models_path, models)

settings_path = os.path.join(directory, "settings.json")
settings = load(settings_path)
settings.update(json.loads(base64.b64decode("${settings}")))
save(settings_path, settings)
PYEOF

`;
}

/**
 * Merges `~/.claude.json` so a fresh VM — and a reconnect to one that's
 * accumulated real state — never hits the first-run flow, the custom API key
 * prompt, or the per-directory trust dialog.
 *
 * `hasTrustDialogAccepted` is set for `$HOME` and every repo cloned under it.
 * Hidden and heavy directories are skipped so the walk stays cheap on every
 * reconnect. Tolerates a missing or malformed file, and is a no-op without
 * python3.
 */
export const TRUST_HOME_DIRECTORIES = `
python3 - <<'PYEOF' || true
import json, os
home = os.path.expanduser("~")
path = os.path.join(home, ".claude.json")
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}

data["hasCompletedOnboarding"] = True

# Pre-approve the injected custom API key ("implicit"), non-destructively.
cap = data.setdefault("customApiKeyResponses", {})
if not isinstance(cap, dict):
    cap = data["customApiKeyResponses"] = {}
approved = cap.setdefault("approved", [])
if not isinstance(approved, list):
    approved = cap["approved"] = []
if "implicit" not in approved:
    approved.append("implicit")
rejected = cap.get("rejected")
if isinstance(rejected, list):
    if "implicit" in rejected:
        rejected.remove("implicit")
else:
    rejected = []
cap["rejected"] = rejected

# Trust $HOME and every repo cloned under it.
projects = data.setdefault("projects", {})
if not isinstance(projects, dict):
    projects = data["projects"] = {}
skip = {"node_modules", "__pycache__", "dist", "build", "target", "venv"}
targets = {home}
for name in sorted(os.listdir(home)):
    full = os.path.join(home, name)
    if not name.startswith(".") and os.path.isdir(full):
        targets.add(full)
for root, dirs, _ in os.walk(home, topdown=True):
    dirs[:] = [d for d in dirs if d not in skip and not d.startswith(".")]
    if os.path.isdir(os.path.join(root, ".git")):
        targets.add(root)
    if os.path.relpath(root, home).count(os.sep) >= 4:
        dirs[:] = []
for target in targets:
    entry = projects.setdefault(target, {})
    if isinstance(entry, dict):
        entry["hasTrustDialogAccepted"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

`;
