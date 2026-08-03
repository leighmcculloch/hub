import { assert, assertEquals, assertMatch, assertStringIncludes } from "@std/assert";
import { decodeBase64 } from "@std/encoding/base64";
import {
  bootstrapCommand,
  bootstrapScript,
  controlModeCommand,
  MAX_VM_NAME_LENGTH,
  PI_PACKAGE,
  shellQuote,
  uniqueVMName,
  vmNameFrom,
} from "../src/model/bootstrap.ts";
import { gatewayWiring } from "../src/model/llm-gateway.ts";
import { EXE_GATEWAY } from "../src/providers/types.ts";

const EXE_NAME = /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/;

function assertValidVMName(name: string) {
  assertMatch(name, EXE_NAME);
  assert(name.length >= 5, `${name} is shorter than 5 characters`);
  assert(name.length <= MAX_VM_NAME_LENGTH, `${name} is longer than ${MAX_VM_NAME_LENGTH}`);
}

Deno.test("vmNameFrom lowercases and hyphenates", () => {
  assertEquals(vmNameFrom("Review PR"), "review-pr");
  assertEquals(vmNameFrom("feature/Login Flow"), "feature-login-flow");
});

Deno.test("vmNameFrom collapses hyphen runs and trims the ends", () => {
  // "--a  b--" normalises to "a-b", which is too short and picks up a suffix.
  assertMatch(vmNameFrom("--a  b--"), /^a-b-[a-z0-9]{6}$/);
  assertEquals(vmNameFrom("hello___world"), "hello-world");
});

Deno.test("vmNameFrom prefixes a name that starts with a digit", () => {
  assertEquals(vmNameFrom("4d63-scratch"), "vm-4d63-scratch");
  assertValidVMName(vmNameFrom("4d63-scratch"));
});

Deno.test("vmNameFrom pads a short name and generates one for empty input", () => {
  assertValidVMName(vmNameFrom("ab"));
  assertValidVMName(vmNameFrom(""));
  assertMatch(vmNameFrom(""), /^vm-[a-z0-9]{6}$/);
});

Deno.test("vmNameFrom truncates without leaving a trailing hyphen", () => {
  const name = vmNameFrom(`${"a".repeat(MAX_VM_NAME_LENGTH)}-tail`);
  assertValidVMName(name);
  assertEquals(name.length, MAX_VM_NAME_LENGTH);
});

Deno.test("uniqueVMName numbers a name already taken", () => {
  assertEquals(uniqueVMName("review", new Set(["review"])), "review-2");
  assertEquals(uniqueVMName("review", new Set(["review", "review-2"])), "review-3");
});

Deno.test("uniqueVMName keeps the length limit when numbering", () => {
  const taken = new Set([vmNameFrom("x".repeat(60))]);
  const name = uniqueVMName("x".repeat(60), taken);
  assertValidVMName(name);
  assert(!taken.has(name));
});

Deno.test("shellQuote escapes embedded single quotes", () => {
  assertEquals(shellQuote("it's"), `'it'\\''s'`);
});

Deno.test("controlModeCommand attaches to the shared session and runs the start command", () => {
  const command = controlModeCommand("claude");
  assertStringIncludes(command, "exec tmux -C new-session -A -s exe");
  assertStringIncludes(command, "claude;");
  // The first window outlives the start command, so the tab keeps a prompt.
  assertStringIncludes(command, "exec ${SHELL:-bash} -l");
});

Deno.test("controlModeCommand omits an empty start command", () => {
  const command = controlModeCommand("   ");
  assert(!command.includes(";  ;"));
  assertStringIncludes(command, "/tmp/exe-bootstrap.sh;");
});

Deno.test("bootstrapCommand base64-encodes the script and installs what it needs", () => {
  const command = bootstrapCommand({
    setupScript: "echo hi",
    claudeSettings: "{}",
    repos: [],
  });
  assertStringIncludes(command, "base64 -d > /tmp/exe-bootstrap.sh");
  assertStringIncludes(command, "for _hub_p in tmux git curl");
  assertStringIncludes(command, "exec tmux -C new-session");

  const encoded = /printf %s '([^']+)'/.exec(command)?.[1] ?? "";
  const decoded = new TextDecoder().decode(decodeBase64(encoded));
  assertStringIncludes(decoded, "echo hi");
});

Deno.test("bootstrapScript clones each repo through the configured prefix", () => {
  const script = bootstrapScript({
    setupScript: "",
    claudeSettings: "",
    repos: ["owner/one", "owner/two"],
  });
  assertStringIncludes(
    script,
    "git clone --depth 1 --quiet 'https://github.com/owner/one.git'",
  );
  assertStringIncludes(
    script,
    "git clone --depth 1 --quiet 'https://github.com/owner/two.git'",
  );
  // Failures are collected and reported rather than aborting the bootstrap.
  assertStringIncludes(script, "exe_failed_clones");
  assertStringIncludes(script, ") </dev/null &");
});

Deno.test("bootstrapScript seeds the git identity only when one is known", () => {
  const withIdentity = bootstrapScript({
    setupScript: "",
    claudeSettings: "",
    repos: [],
    gitIdentity: { name: "Ada L", email: "1+ada@users.noreply.github.com" },
  });
  assertStringIncludes(withIdentity, `git config --global user.name 'Ada L'`);

  const without = bootstrapScript({ setupScript: "", claudeSettings: "", repos: [] });
  assert(!without.includes("git config --global user.name"));
});

Deno.test("bootstrapScript writes the harness config for a chosen model", () => {
  const model = { provider: "anthropic", model: "claude-opus-5" };
  const script = bootstrapScript({
    setupScript: "",
    claudeSettings: "",
    repos: [],
    gateway: { model, wiring: gatewayWiring(model, EXE_GATEWAY) },
  });
  assertStringIncludes(script, `"$HOME/.codex/config.toml"`);
  assertStringIncludes(script, "exe-llm");
  assertStringIncludes(script, "~/.pi/agent");
});

Deno.test("bootstrapScript arms auto-naming only when asked", () => {
  const armed = bootstrapScript({
    setupScript: "",
    claudeSettings: "",
    repos: [],
    autoName: true,
  });
  assertStringIncludes(armed, ".exe-autoname-armed");

  const plain = bootstrapScript({ setupScript: "", claudeSettings: "", repos: [] });
  // The installer is always emitted, but it is gated on the armed flag.
  assertStringIncludes(plain, `if [ -e "$HOME/.exe-autoname-armed" ]`);
  assert(!plain.includes(`: > "$HOME/.exe-autoname-armed"`));
});

Deno.test("Node is installed before the npm install that needs it", () => {
  const script = bootstrapScript({ setupScript: "", claudeSettings: "", repos: [] });
  const node = script.indexOf("deb.nodesource.com");
  const pi = script.indexOf(PI_PACKAGE);
  assert(node >= 0, "the bootstrap should install Node");
  assert(pi >= 0, "the bootstrap should install pi");
  assert(node < pi, "npm has to exist before it is asked to install anything");
  // `$_hub_sudo -E bash -` runs `-E` as the command once there is no sudo,
  // which is a container running as root: the common case for Docker.
  assert(!script.includes("$_hub_sudo -E"), "the pipe must survive an empty sudo");
});

Deno.test("pi is installed as an npm package, not through its terminal installer", () => {
  const script = bootstrapScript({ setupScript: "", claudeSettings: "", repos: [] });
  assertStringIncludes(script, `npm install -g --ignore-scripts ${PI_PACKAGE}`);
  // The install script reads /dev/tty, which a tmux pane has: it would prompt.
  assert(!script.includes("pi.dev/install.sh"), "the tty installer must not be used");
});

Deno.test("pi's settings are seeded, but never over one already on the machine", () => {
  const script = bootstrapScript({
    setupScript: "",
    claudeSettings: "",
    piSettings: `{"hideThinkingBlock": true}`,
    repos: [],
  });
  assertStringIncludes(script, `mkdir -p "$HOME/.pi/agent"`);
  assertStringIncludes(script, `if [ ! -f "$HOME/.pi/agent/settings.json" ]; then`);
  const encoded = /printf %s '([^']+)' \| base64 -d > "\$HOME\/\.pi\/agent\/settings\.json"/
    .exec(script)?.[1] ?? "";
  assertEquals(
    new TextDecoder().decode(decodeBase64(encoded)),
    `{"hideThinkingBlock": true}`,
  );
});

Deno.test("no pi settings means nothing is written", () => {
  const script = bootstrapScript({ setupScript: "", claudeSettings: "", repos: [] });
  assert(!script.includes(".pi/agent/settings.json"));
});

Deno.test("a clone can neither prompt nor read the pane it shares", () => {
  const script = bootstrapScript({ setupScript: "", claudeSettings: "", repos: ["owner/one"] });
  // Without a usable credential git asks for a GitHub username on the terminal.
  // The clones run in a background subshell on the agent's own tty, with no job
  // control to stop them reading, so the prompt eats every keystroke typed at
  // the agent.
  assertStringIncludes(script, "export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS=");
  assertStringIncludes(script, ") </dev/null &");
});

Deno.test("git is authenticated before anything that could use it", () => {
  const script = bootstrapScript({
    setupScript: "make setup",
    claudeSettings: "{}",
    repos: ["owner/one"],
    gitIdentity: { name: "A", email: "a@example.com" },
    hostEnvironmentSetup: 'export GITHUB_TOKEN="t"\n',
  });
  const host = script.indexOf("GITHUB_TOKEN=");
  const credentials = script.indexOf(".git-credentials");
  assert(host >= 0 && credentials > host, "the token has to be in the environment first");
  for (const later of ["git config --global user.name", "make setup", "git clone"]) {
    assert(script.indexOf(later) > credentials, `${later} must come after the credential`);
  }
});

Deno.test("no token on the machine leaves git as it was", () => {
  const script = bootstrapScript({ setupScript: "", claudeSettings: "", repos: [] });
  // The fragment is always emitted; it is the shell test inside it that decides.
  assertStringIncludes(script, 'if [ -n "${GITHUB_TOKEN:-}" ]; then');
  assertStringIncludes(script, "credential.helper store");
});
