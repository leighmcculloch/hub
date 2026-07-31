/**
 * Naming a session after the work in it: the VM renames itself, once, from the
 * first prompt its coding agent is given.
 *
 * A session created without a name gets a generated VM name like `vm-3f9a1c`,
 * which says nothing in the sidebar or in `ls`. The app can't do better on its
 * own — the prompt goes down tmux into a pane, and the app only sees bytes — so
 * the naming happens on the VM: Claude Code's `UserPromptSubmit` hook and
 * Codex's `notify` program both run one script, which asks the exe.dev LLM
 * gateway for a name and calls `rename` on the exe.dev API.
 *
 * Everything here is text destined for the VM, plus the rules for the token
 * that lets it rename itself. Kept out of `bootstrap.ts`, which decides only
 * *when* this is installed and armed.
 */

import { encodeBase64 } from "@std/encoding/base64";
import { shellQuote } from "./shell.ts";

// MARK: - The token a VM renames itself with

/**
 * The only command the VM's token may run. An agent runs unattended on that VM
 * with permissions bypassed, so it gets a token that can rename its own machine
 * and nothing else.
 */
export const TOKEN_COMMANDS = "rename";

/** Label the minted token's key carries on the account. */
export const TOKEN_LABEL = "exe-desktop-autoname";

/** Asked for when minting. exe.dev's own advice is to always set an expiry. */
export const TOKEN_LIFETIME = "1y";

/**
 * Replaced well before that year is up: a token that expires quietly turns
 * auto-naming off with nothing to see.
 */
export const TOKEN_MAX_AGE_MS = 300 * 24 * 60 * 60 * 1000;

/** The variable the script reads the token from, set on the VM host. */
export const TOKEN_VARIABLE = "EXE_RENAME_TOKEN";

/** Whether a cached token should be replaced before it is handed to a VM. */
export function tokenIsStale(minted: number | null, now: number = Date.now()): boolean {
  if (minted === null) return true;
  const age = now - minted;
  // A negative age is a clock that moved, not a token minted in the future;
  // mint again rather than trusting it until next year.
  return age < 0 || age > TOKEN_MAX_AGE_MS;
}

/** The exe.dev command that mints it. */
export const MINT_TOKEN_COMMAND =
  `ssh-key generate-api-key --label=${TOKEN_LABEL} --cmds=${TOKEN_COMMANDS}` +
  ` --exp=${TOKEN_LIFETIME} --json`;

// MARK: - Files on the VM

/** The script itself. */
export const SCRIPT_NAME = ".exe-autoname";

/**
 * Present only on a VM the app armed, which it does for a session created
 * without a name. Everything is gated on it, so a VM whose name someone typed
 * is never renamed out from under them.
 */
export const ARMED_NAME = ".exe-autoname-armed";

/**
 * Written before the rename is attempted and holding its outcome after, so one
 * VM gets one attempt no matter how many prompts arrive.
 */
export const MARKER_NAME = ".exe-autoname-done";

/** Tells the script to wire itself up rather than to name anything. */
export const INSTALL_FLAG = "--install";

// MARK: - Bootstrap fragments

/**
 * Arms this VM. Emitted once, when a session is created without a name.
 *
 * The flag lives on the VM rather than in the app because every later connect
 * has to know, and the VM is the only party present for all of them.
 */
export const ARM_FRAGMENT = `
: > "$HOME/${ARMED_NAME}"

`;

/**
 * Installs the script and lets it wire itself into both harnesses.
 *
 * Emitted on every connect — a reconnect rewrites the harness configuration
 * this lives in, so it has to be re-applied or it lasts exactly one session —
 * and gated on the armed flag, so an unarmed VM gets nothing but a failed test.
 */
export function installFragment(): string {
  const encoded = encodeBase64(new TextEncoder().encode(autoNameScript()));
  return `
if [ -e "$HOME/${ARMED_NAME}" ]; then
  printf %s '${encoded}' | base64 -d > "$HOME/${SCRIPT_NAME}"
  chmod +x "$HOME/${SCRIPT_NAME}"
  python3 "$HOME/${SCRIPT_NAME}" ${INSTALL_FLAG} || true
fi

`;
}

/**
 * The remote command that feeds a captured prompt to the rename script — the
 * same `{"prompt": …}` payload Codex's `notify` delivers, just sent over the
 * transport from the app instead of by a harness hook.
 *
 * Run under `bash -l` because the rename token is exported by
 * `/etc/profile.d`, so only a login shell sees it. The script's own
 * armed/marker gates still decide whether a rename happens.
 */
export function renameCommand(prompt: string): string {
  const payload = JSON.stringify({ prompt });
  const inner = `python3 "$HOME/${SCRIPT_NAME}" ${shellQuote(payload)}`;
  return `bash -l -c ${shellQuote(inner)}`;
}

// MARK: - The script

/**
 * The script installed on the VM, run by both harnesses.
 *
 * Python rather than shell because the payloads are JSON, the gateway speaks
 * JSON, and `jq` is not on every image — while `python3` is already relied on
 * elsewhere in the bootstrap.
 */
export function autoNameScript(): string {
  return `#!/usr/bin/env python3
# Rename this exe.dev VM after the first prompt its coding agent gets.
#
# Installed by the hub app and run by Claude Code's UserPromptSubmit hook
# (payload on stdin) and Codex's notify (payload as an argument). The name comes
# from the exe.dev LLM gateway, which needs no credentials inside a VM; the
# rename goes through the exe.dev API with a token that may do nothing else.
#
# Nothing here reports a failure anywhere a person would see it: a VM that kept
# its generated name is a better outcome than a traceback printed over the
# agent's first answer. The marker file says what happened, for anyone who comes
# looking.

import json
import os
import re
import sys
import urllib.error
import urllib.request

# Absent unless the app armed this VM, which it does only for a session the user
# left unnamed.
ARMED = os.path.expanduser("~/${ARMED_NAME}")
# Claimed before the work starts; holds the outcome afterwards.
MARKER = os.path.expanduser("~/${MARKER_NAME}")

# Both keyless from inside a VM: the metadata service authenticates the machine
# itself.
REFLECTION = "https://reflection.int.exe.xyz/"
GATEWAY = "http://169.254.169.254/gateway/llm/anthropic/v1/messages"
# Naming one session is a one-line job, so it goes to the cheapest, fastest
# model on the gateway rather than the session's own.
MODEL = "claude-haiku-4-5"
# The exe.dev API is its CLI: the request body is the command.
EXEC = "https://exe.dev/exec"
TOKEN = os.environ.get("${TOKEN_VARIABLE}", "")

# exe.dev names: 5-52 characters, starting with a lowercase letter, then
# lowercase letters or digits with single hyphens between. Checked here as well
# as server-side, because a rejected name is a rename that quietly didn't
# happen.
NAME = re.compile(r"[a-z][a-z0-9]*(-[a-z0-9]+)*")
MIN_LENGTH = 5
MAX_LENGTH = 52

# Enough of the prompt to name the work. The rest is detail no name holds.
MAX_PROMPT = 2000

INSTRUCTIONS = (
    "You name cloud VMs after the work being done on them. Read the "
    "prompt a coding agent was just given and answer with a name for "
    "its VM: two to four lowercase words, joined by hyphens, naming "
    "the task. Answer with the name alone - no quotes, no punctuation, "
    "no explanation. Example: add-oauth-login"
)


def install():
    # Point both harnesses at this script. Merged into their configuration
    # rather than written over it: both files can hold settings of the user's
    # own, and this runs again on every connect.
    script = os.path.abspath(__file__)

    settings_path = os.path.expanduser("~/.claude/settings.json")
    try:
        with open(settings_path) as handle:
            settings = json.load(handle)
    except Exception:
        settings = {}
    if not isinstance(settings, dict):
        settings = {}
    hooks = settings.setdefault("hooks", {})
    if isinstance(hooks, dict):
        groups = hooks.setdefault("UserPromptSubmit", [])
        # Matched against the group as a whole rather than against a shape of
        # our own, so a hook already naming this script isn't added twice.
        if isinstance(groups, list) and script not in json.dumps(groups):
            groups.append({"hooks": [{"type": "command", "command": script}]})
            os.makedirs(os.path.dirname(settings_path), exist_ok=True)
            with open(settings_path, "w") as handle:
                json.dump(settings, handle, indent=2)

    # Codex is wired through notify rather than through its own UserPromptSubmit
    # hook, which would be skipped until someone ran /hooks and trusted it by
    # hash — no use on a machine nobody is going to configure by hand.
    codex_path = os.path.expanduser("~/.codex/config.toml")
    try:
        with open(codex_path) as handle:
            codex = handle.read()
    except Exception:
        codex = ""
    # A notify of the user's own is worth more than auto-naming.
    if not re.search(r"(?m)^[ \\t]*notify[ \\t]*=", codex):
        os.makedirs(os.path.dirname(codex_path), exist_ok=True)
        with open(codex_path, "w") as handle:
            # A root key has to come before the file's tables, so it goes on
            # top. A TOML basic string is spelled like a JSON one.
            handle.write("notify = [%s]\\n" % json.dumps(script) + codex)


def payload():
    # Codex passes the JSON as an argument, Claude Code on stdin. Reading stdin
    # is conditional because notify inherits Codex's own, which may be a
    # terminal that never reaches EOF.
    if len(sys.argv) > 1:
        return sys.argv[1]
    if sys.stdin.isatty():
        return ""
    return sys.stdin.read()


def task(text):
    # The prompt out of either harness's payload.
    try:
        data = json.loads(text)
    except Exception:
        return ""
    if not isinstance(data, dict):
        return ""
    prompt = data.get("prompt")
    if isinstance(prompt, str) and prompt.strip():
        return prompt.strip()[:MAX_PROMPT]
    # Codex's keys are hyphenated; the underscored spelling is accepted too
    # rather than betting the feature on which one a version uses.
    messages = data.get("input-messages") or data.get("input_messages")
    if isinstance(messages, list):
        joined = "\\n".join(m for m in messages if isinstance(m, str))
        return joined.strip()[:MAX_PROMPT]
    return ""


def sanitize(suggestion):
    # A model told to answer in two to four words will still sometimes answer
    # with a sentence, a quoted string, or a trailing full stop.
    name = re.sub(r"[^a-z0-9]+", "-", suggestion.strip().lower())
    name = name.strip("-")
    if name and not name[0].isalpha():
        name = "vm-" + name
    if len(name) > MAX_LENGTH:
        name = name[:MAX_LENGTH].rstrip("-")
    if len(name) < MIN_LENGTH or not NAME.fullmatch(name):
        return ""
    return name


def post(url, body, headers, timeout=30):
    request = urllib.request.Request(
        url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def current_name():
    # The reflection integration publishes the VM's own name.
    with urllib.request.urlopen(REFLECTION, timeout=10) as response:
        return json.loads(response.read()).get("name") or ""


def suggestion(prompt):
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 32,
        "system": INSTRUCTIONS,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    answer = json.loads(post(GATEWAY, body, {
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
    }))
    blocks = answer.get("content") or []
    return "".join(block.get("text", "") for block in blocks
                   if isinstance(block, dict))


def rename(old, new):
    post(EXEC, ("rename %s %s" % (old, new)).encode(), {
        "authorization": "Bearer " + TOKEN,
        "content-type": "text/plain",
    })


def claim():
    # One attempt per VM, decided before any of the work: both harnesses can run
    # this again while the first run is still waiting on the gateway.
    try:
        os.close(os.open(MARKER, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        return True
    except OSError:
        return False


def record(outcome):
    try:
        with open(MARKER, "w") as marker:
            marker.write(outcome + "\\n")
    except OSError:
        pass


def detach():
    # The agent's first prompt shouldn't wait on the gateway, and the hook's
    # output is read until it closes, so the work happens in a child with
    # nothing of the harness left attached to it.
    if os.fork() != 0:
        return False
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    return True


def apply(prompt):
    old = current_name()
    new = sanitize(suggestion(prompt))
    if not new:
        return "no usable name suggested"
    if not old or new == old:
        return "kept " + (old or "the current name")
    # exe.dev refuses a name another VM already has, and this is exactly the
    # kind of naming where two sessions land on "fix-login-bug".
    for candidate in [new] + ["%s-%d" % (new, n) for n in range(2, 5)]:
        try:
            rename(old, candidate)
            return "renamed %s to %s" % (old, candidate)
        except urllib.error.HTTPError as error:
            # 422 is the command itself failing, which is what a name already
            # taken looks like. Anything else is ours to report.
            if error.code != 422:
                raise
    return "no free name near " + new


def main():
    if sys.argv[1:2] == ["${INSTALL_FLAG}"]:
        install()
        return
    if not os.path.exists(ARMED) or os.path.exists(MARKER):
        return
    prompt = task(payload())
    if not prompt or not TOKEN:
        return
    if not claim() or not detach():
        return
    try:
        outcome = apply(prompt)
    except Exception as error:
        outcome = "failed: %r" % (error,)
    record(outcome)
    # This is a forked hook process, so it ends here rather than returning into
    # whatever the parent was in the middle of.
    os._exit(0)


if __name__ == "__main__":
    main()
`;
}
