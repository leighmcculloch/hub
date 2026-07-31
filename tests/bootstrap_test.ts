import { assert, assertEquals, assertMatch, assertStringIncludes } from "@std/assert";
import { decodeBase64 } from "@std/encoding/base64";
import {
  bootstrapCommand,
  bootstrapScript,
  controlModeCommand,
  MAX_VM_NAME_LENGTH,
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

Deno.test("bootstrapCommand base64-encodes the script and installs tmux first", () => {
  const command = bootstrapCommand({
    setupScript: "echo hi",
    claudeSettings: "{}",
    repos: [],
  });
  assertStringIncludes(command, "base64 -d > /tmp/exe-bootstrap.sh");
  assertStringIncludes(command, "command -v tmux");
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
    "git clone --depth 1 --quiet 'https://github.int.exe.xyz/owner/one.git'",
  );
  assertStringIncludes(
    script,
    "git clone --depth 1 --quiet 'https://github.int.exe.xyz/owner/two.git'",
  );
  // Failures are collected and reported rather than aborting the bootstrap.
  assertStringIncludes(script, "exe_failed_clones");
  assertStringIncludes(script, ") &");
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
