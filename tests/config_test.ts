import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import {
  decodeConfig,
  DEFAULT_CLAUDE_SETTINGS,
  defaultConfigData,
} from "../src/config/app-config.ts";
import { mergeEnv } from "../src/config/env-var.ts";
import { restorable, restorableSelection, SessionStore } from "../src/config/session-store.ts";
import { normalizeRepo } from "../src/github/repo-reference.ts";
import { sortRepos, userDisplayName, userNoreplyEmail } from "../src/github/repos.ts";

Deno.test("decodeConfig falls back field by field, not file by file", () => {
  const config = decodeConfig({ exeToken: 12, provider: "sprites", claudeSettings: "{}" });
  assertEquals(config.exeToken, "");
  assertEquals(config.provider, "sprites");
  assertEquals(config.claudeSettings, "{}");
  assertEquals(config.environments.length, 3);
});

Deno.test("decodeConfig treats an empty environment list as absent", () => {
  assertEquals(decodeConfig({ environments: [] }).environments.length, 3);
});

Deno.test("decodeConfig defaults an unknown provider to exe.dev", () => {
  assertEquals(decodeConfig({ provider: "nope" }).provider, "exe");
  assertEquals(decodeConfig(null).claudeSettings, DEFAULT_CLAUDE_SETTINGS);
});

Deno.test("decodeConfig accepts both the epoch and the ISO minted date", () => {
  assertEquals(decodeConfig({ renameTokenMinted: 1700000000000 }).renameTokenMinted, 1700000000000);
  assertEquals(
    decodeConfig({ renameTokenMinted: "2024-01-01T00:00:00Z" }).renameTokenMinted,
    Date.parse("2024-01-01T00:00:00Z"),
  );
  assertEquals(decodeConfig({ renameTokenMinted: "nonsense" }).renameTokenMinted, null);
});

Deno.test("decodeConfig only keeps a model with both halves", () => {
  assertEquals(decodeConfig({ model: { provider: "p", model: "m" } }).model, {
    provider: "p",
    model: "m",
  });
  assertEquals(decodeConfig({ model: { provider: "p" } }).model, null);
});

Deno.test("mergeEnv lets later lists win and drops nameless rows", () => {
  const merged = mergeEnv([
    [{ key: "A", value: "1" }, { key: "", value: "x" }],
    [{ key: "A", value: "2" }, { key: "B", value: "3" }],
  ]);
  assertEquals(merged, [{ key: "A", value: "2" }, { key: "B", value: "3" }]);
});

Deno.test("mergeEnv can blank a value a previous list set", () => {
  const merged = mergeEnv([[{ key: "T", value: "secret" }], [{ key: "T", value: "" }]]);
  assertEquals(merged, [{ key: "T", value: "" }]);
});

Deno.test("restorable drops tabs whose VM is gone", () => {
  const persisted = [
    { destination: "a.exe.xyz", title: "a", vmName: "a", provider: "exe" as const },
    { destination: "b.exe.xyz", title: "b", vmName: "b", provider: "exe" as const },
  ];
  assertEquals(restorable(persisted, new Set(["a.exe.xyz"])).length, 1);
});

Deno.test("restorable trusts the file when the VM list came back empty", () => {
  const persisted = [{ destination: "a", title: "a", vmName: null, provider: "exe" as const }];
  assertEquals(restorable(persisted, new Set()).length, 1);
});

Deno.test("restorableSelection keeps your place, or falls back to the first", () => {
  const sessions = [
    { destination: "a", title: "a", vmName: null, provider: "exe" as const },
    { destination: "b", title: "b", vmName: null, provider: "exe" as const },
  ];
  assertEquals(restorableSelection("b", sessions), "b");
  assertEquals(restorableSelection("gone", sessions), "a");
  assertEquals(restorableSelection(null, []), null);
});

Deno.test("SessionStore round-trips a workspace and reads the legacy bare array", async () => {
  const directory = await Deno.makeTempDir();
  try {
    const path = `${directory}/sessions.json`;
    const store = new SessionStore(path);
    store.save({
      sessions: [{ destination: "a.exe.xyz", title: "a", vmName: "a", provider: "sprites" }],
      selected: "a.exe.xyz",
    });
    const loaded = store.load();
    assertEquals(loaded.selected, "a.exe.xyz");
    assertEquals(loaded.sessions[0].provider, "sprites");

    // A file written before the selection was recorded holds a bare array, and
    // before providers existed it named none.
    await Deno.writeTextFile(path, `[{"destination":"b","title":"b"}]`);
    const legacy = store.load();
    assertEquals(legacy.selected, null);
    assertEquals(legacy.sessions[0].provider, "exe");
    assertEquals(legacy.sessions[0].vmName, null);
  } finally {
    await Deno.remove(directory, { recursive: true });
  }
});

Deno.test("SessionStore treats a missing or corrupt file as no sessions", async () => {
  const directory = await Deno.makeTempDir();
  try {
    assertEquals(new SessionStore(`${directory}/absent.json`).load().sessions, []);
    await Deno.writeTextFile(`${directory}/bad.json`, "{{{");
    assertEquals(new SessionStore(`${directory}/bad.json`).load().sessions, []);
  } finally {
    await Deno.remove(directory, { recursive: true });
  }
});

Deno.test("normalizeRepo accepts owner/repo and the URLs people paste", () => {
  assertEquals(normalizeRepo("owner/repo"), "owner/repo");
  assertEquals(normalizeRepo("  owner/repo  "), "owner/repo");
  assertEquals(normalizeRepo("https://github.com/owner/repo"), "owner/repo");
  assertEquals(normalizeRepo("https://github.com/owner/repo.git"), "owner/repo");
  assertEquals(normalizeRepo("https://github.com/owner/repo/tree/main"), "owner/repo");
  assertEquals(normalizeRepo("git@github.com:owner/repo.git"), "owner/repo");
  assertEquals(normalizeRepo("github.com/owner/repo"), "owner/repo");
});

Deno.test("normalizeRepo refuses text that isn't a repository reference", () => {
  assertEquals(normalizeRepo(""), null);
  assertEquals(normalizeRepo("repo"), null);
  // Without a recognisable prefix, a third component is not guessed at.
  assertEquals(normalizeRepo("owner/repo/extra"), null);
  assertEquals(normalizeRepo("owner/"), null);
});

Deno.test("repos sort the way the picker is read, not the way bytes compare", () => {
  const sorted = sortRepos([
    { fullName: "ZZZ/a", isPrivate: false },
    { fullName: "aaa/b", isPrivate: false },
  ]);
  assertEquals(sorted.map((repo) => repo.fullName), ["aaa/b", "ZZZ/a"]);
});

Deno.test("a blank profile name still authors commits as the login", () => {
  assertEquals(userDisplayName({ login: "ada", id: 1, name: "   " }), "ada");
  assertEquals(userDisplayName({ login: "ada", id: 1, name: "Ada L" }), "Ada L");
  assertEquals(
    userNoreplyEmail({ login: "ada", id: 42, name: null }),
    "42+ada@users.noreply.github.com",
  );
});

Deno.test("the default Claude settings bypass permissions and onboarding", () => {
  const settings = JSON.parse(DEFAULT_CLAUDE_SETTINGS);
  assertEquals(settings.permissions.defaultMode, "bypassPermissions");
  assert(settings.hasCompletedOnboarding);
});

Deno.test("a stored environment list gains defaults added since it was written", () => {
  const stored = decodeConfig({
    environments: [{ id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000001", name: "Mine", startCommand: "x" }],
  }).environments;
  // The user's edit survives…
  assertEquals(stored[0].name, "Mine");
  assertEquals(stored[0].startCommand, "x");
  // …and the environments they predate arrive alongside it.
  assert(stored.some((one) => one.name === "pi"), "pi should be added to an older config");
  assert(stored.some((one) => one.name === "Codex"));
});

Deno.test("pi is offered out of the box, and installs itself on the VM", () => {
  const pi = defaultConfigData().environments.find((one) => one.name === "pi");
  assert(pi !== undefined);
  assertEquals(pi.startCommand, "pi");
  assertStringIncludes(pi.setupScript, "pi.dev/install.sh");
  // Idempotent: the bootstrap re-runs it on every reconnect.
  assertStringIncludes(pi.setupScript, "command -v pi");
});
