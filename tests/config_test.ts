import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import {
  AppConfig,
  decodeConfig,
  DEFAULT_CLAUDE_SETTINGS,
  defaultConfigData,
} from "../src/config/app-config.ts";
import { mergeEnv } from "../src/config/env-var.ts";
import { restorable, restorableSelection, SessionStore } from "../src/config/session-store.ts";
import { decodeLayout, defaultLayout, LayoutStore } from "../src/config/layout-store.ts";
import { normalizeRepo } from "../src/github/repo-reference.ts";
import { sortRepos, userDisplayName, userNoreplyEmail } from "../src/github/repos.ts";

Deno.test("decodeConfig falls back field by field, not file by file", () => {
  const config = decodeConfig({ exeToken: 12, provider: "sprites", claudeSettings: "{}" });
  assertEquals(config.exeToken, "");
  assertEquals(config.provider, "sprites");
  assertEquals(config.claudeSettings, "{}");
  assertEquals(config.environments.length, 1);
});

Deno.test("decodeConfig treats an empty environment list as absent", () => {
  assertEquals(decodeConfig({ environments: [] }).environments.length, 1);
});

Deno.test("decodeConfig defaults an unknown provider to docker", () => {
  assertEquals(decodeConfig({ provider: "nope" }).provider, "docker");
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

Deno.test("LayoutStore round-trips the pane sizes and what was showing", async () => {
  const directory = await Deno.makeTempDir();
  try {
    const store = new LayoutStore(`${directory}/layout.json`);
    store.save({
      sidebarWidth: 34,
      diffWidth: 60,
      scopeHeight: 6,
      filesHeight: 12,
      showSessionSidebar: false,
      showDiffSidebar: true,
      sidebarGrouping: "repo",
    });
    const loaded = store.load();
    assertEquals(loaded.sidebarWidth, 34);
    assertEquals(loaded.filesHeight, 12);
    assertEquals(loaded.showSessionSidebar, false);
    assertEquals(loaded.showDiffSidebar, true);
    assertEquals(loaded.sidebarGrouping, "repo");
  } finally {
    await Deno.remove(directory, { recursive: true });
  }
});

Deno.test("decodeLayout falls back per field and refuses a nonsense size", () => {
  const defaults = defaultLayout();
  assertEquals(decodeLayout(null), defaults);
  const partial = decodeLayout({ diffWidth: 70, showDiffSidebar: "yes", sidebarWidth: Infinity });
  assertEquals(partial.diffWidth, 70);
  // A width that isn't a usable number costs that width, not the layout.
  assertEquals(partial.sidebarWidth, defaults.sidebarWidth);
  assertEquals(partial.showDiffSidebar, defaults.showDiffSidebar);
  // A pane can never be persisted to nothing; the layout pass clamps from here.
  assertEquals(decodeLayout({ sidebarWidth: -5, scopeHeight: 0.4 }).sidebarWidth, 1);
  assertEquals(decodeLayout({ scopeHeight: 0.4 }).scopeHeight, 1);
  // A grouping the app doesn't know — written by a newer version, say — falls
  // back to the default rather than surfacing as an unknown mode.
  assertEquals(decodeLayout({ sidebarGrouping: "by-mood" }).sidebarGrouping, "provider");
  assertEquals(decodeLayout({}).sidebarGrouping, "provider");
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
});

Deno.test("a fresh install starts with pi and nothing to set up", () => {
  const environments = defaultConfigData().environments;
  assertEquals(environments.length, 1);
  assertEquals(environments[0].name, "pi");
  assertEquals(environments[0].startCommand, "pi");
  // Installing it is the bootstrap's job, not a setup script the user owns.
  assertEquals(environments[0].setupScript, "");
});

Deno.test("a config written by the Swift app doesn't grow duplicate environments", () => {
  // Swift's UUID.uuidString is upper case and this app writes lower case; the
  // same environment written by either must be recognised as the same one.
  const config = decodeConfig({
    environments: [
      {
        id: "8F1D4F4E-1D2B-4C1B-9E3A-000000000001",
        name: "Claude Code",
        setupScript: "",
        startCommand: "claude",
        environment: [{ key: "CLAUDE_CODE_OAUTH_TOKEN", value: "secret" }],
      },
      {
        id: "8F1D4F4E-1D2B-4C1B-9E3A-000000000002",
        name: "Codex",
        setupScript: "",
        startCommand: "codex",
        environment: [],
      },
    ],
  });
  assertEquals(config.environments.map((one) => one.name), ["Claude Code", "Codex", "pi"]);
  // The user's own copy survives, token and all — the built-in isn't merged over it.
  assertEquals(config.environments[0].environment[0].value, "secret");
});

Deno.test("an already-duplicated config is repaired, keeping the edited copy", () => {
  const config = decodeConfig({
    environments: [
      {
        id: "8F1D4F4E-1D2B-4C1B-9E3A-000000000001",
        name: "Claude Code",
        setupScript: "",
        startCommand: "claude --resume",
        environment: [{ key: "CLAUDE_CODE_OAUTH_TOKEN", value: "secret" }],
      },
      // What the case-sensitive comparison appended: an untouched built-in.
      {
        id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000001",
        name: "Claude Code",
        setupScript: "",
        startCommand: "claude",
        environment: [{ key: "CLAUDE_CODE_OAUTH_TOKEN", value: "" }],
      },
    ],
    selectedEnvironmentID: "8f1d4f4e-1d2b-4c1b-9e3a-000000000001",
  });
  assertEquals(config.environments.filter((one) => one.name === "Claude Code").length, 1);
  assertEquals(config.environments[0].startCommand, "claude --resume");
  // A selection pointing at the removed copy follows the one that replaced it.
  assertEquals(config.selectedEnvironmentID, "8F1D4F4E-1D2B-4C1B-9E3A-000000000001");
});

Deno.test("two environments the user edited are never confused for a duplicate", () => {
  const config = decodeConfig({
    environments: [
      {
        id: "8F1D4F4E-1D2B-4C1B-9E3A-000000000002",
        name: "Codex",
        setupScript: "",
        startCommand: "codex",
        environment: [],
      },
      // Same name, but not a built-in: the user made this one, so it stays.
      {
        id: "11111111-1111-1111-1111-111111111111",
        name: "Codex",
        setupScript: "",
        startCommand: "codex --sandbox",
        environment: [],
      },
    ],
  });
  assertEquals(config.environments.filter((one) => one.name === "Codex").length, 2);
});

Deno.test("the selected environment resolves whatever case its id was written in", () => {
  const data = decodeConfig({
    environments: [{
      id: "8F1D4F4E-1D2B-4C1B-9E3A-000000000002",
      name: "Codex",
      startCommand: "codex",
    }],
    selectedEnvironmentID: "8f1d4f4e-1d2b-4c1b-9e3a-000000000002",
  });
  const config = Object.assign(Object.create(AppConfig.prototype), { data }) as AppConfig;
  assertEquals(config.selectedEnvironment.name, "Codex");
});

Deno.test("pi is preconfigured to keep thinking blocks out of the pane", () => {
  const settings = JSON.parse(defaultConfigData().piSettings);
  assertEquals(settings.hideThinkingBlock, true);
});

Deno.test("a stored pi settings string is kept as the user wrote it", () => {
  assertEquals(
    decodeConfig({ piSettings: `{"hideThinkingBlock": false}` }).piSettings,
    `{"hideThinkingBlock": false}`,
  );
});

Deno.test("the old curl-into-a-shell pi installer becomes the npm install", () => {
  const stored = decodeConfig({
    environments: [{
      id: "8f1d4f4e-1d2b-4c1b-9e3a-000000000003",
      name: "pi",
      startCommand: "pi",
      setupScript: "command -v pi >/dev/null 2>&1 || curl -fsSL https://pi.dev/install.sh | sh",
    }],
  }).environments;
  assertStringIncludes(stored[0].setupScript, "npm install -g --ignore-scripts");
  assert(!stored[0].setupScript.includes("pi.dev/install.sh"));
});

Deno.test("a setup script someone wrote themselves is left alone", () => {
  const mine = "echo mine; curl -fsSL https://pi.dev/install.sh | sh";
  const stored = decodeConfig({
    environments: [{ id: "x", name: "pi", setupScript: mine }],
  }).environments;
  assertEquals(stored[0].setupScript, mine);
});
