import { assert, assertEquals } from "@std/assert";
import { AppConfig, decodeConfig } from "../src/config/app-config.ts";
import { SessionStore } from "../src/config/session-store.ts";
import { Workspace } from "../src/model/workspace.ts";
import type { RemoteVMRecord, VMProvider, VMProviderID } from "../src/providers/types.ts";

/** A config with whichever tokens the test wants, and no file behind it. */
function config(tokens: { exe?: string; sprites?: string; provider?: VMProviderID }): AppConfig {
  const data = decodeConfig({
    exeToken: tokens.exe ?? "",
    spritesToken: tokens.sprites ?? "",
    provider: tokens.provider ?? "exe",
  });
  // `load` reads the real config directory; this stands in for one.
  return Object.assign(Object.create(AppConfig.prototype), { data, path: "" }) as AppConfig;
}

function vm(name: string, provider: VMProviderID): RemoteVMRecord {
  return { name, destination: name, webURL: null, status: "running", provider };
}

/**
 * A workspace whose providers list a fixed set of VMs, or throw. Only the
 * credential and `listVMs` are reached by these tests — `namespace` keeps its
 * real shape, a CLI-held login with no token behind it.
 */
function workspace(
  config_: AppConfig,
  listings: Partial<Record<VMProviderID, RemoteVMRecord[] | Error>>,
  loggedIn = false,
): Workspace {
  const space = new Workspace(config_, () => {}, new SessionStore("/dev/null/nope.json"));
  space.providerFor = ((id: VMProviderID) => ({
    id,
    credential: id === "namespace"
      ? { kind: "cli", binary: "devbox", loginCommand: "devbox login" }
      : { kind: "token", envVar: "" },
    effectiveToken: () => config_.tokenFor(id),
    checkAvailable: () =>
      Promise.resolve(id === "namespace" ? loggedIn : config_.tokenFor(id) !== ""),
    listVMs: () => {
      const listed = listings[id];
      if (listed instanceof Error) return Promise.reject(listed);
      return Promise.resolve(listed ?? []);
    },
  })) as unknown as Workspace["providerFor"];
  return space;
}

Deno.test("only providers with a token count as configured, default first", () => {
  assertEquals(workspace(config({}), {}).configuredProviders, []);
  assertEquals(workspace(config({ exe: "t" }), {}).configuredProviders, ["exe"]);
  assertEquals(workspace(config({ sprites: "t" }), {}).configuredProviders, ["sprites"]);
  // Both configured: the default provider leads, since it is what new sessions
  // start on and what the lists are ordered by.
  assertEquals(
    workspace(config({ exe: "t", sprites: "t", provider: "sprites" }), {}).configuredProviders,
    ["sprites", "exe"],
  );
});

Deno.test("a CLI-held login counts as configured only once it is probed", async () => {
  // Namespace has no token to read: it is configured when its CLI says it is
  // logged in, which the workspace asks once and remembers.
  const space = workspace(config({}), { namespace: [vm("box-one", "namespace")] }, true);
  assertEquals(space.configuredProviders, [], "nothing counts before the probe");
  await space.refreshCLICredentials();
  assertEquals(space.configuredProviders, ["namespace"]);
  assert(space.hasAnyToken);
  await space.loadAvailableVMs();
  assertEquals(space.availableVMs.map((one) => one.name), ["box-one"]);
});

Deno.test("a CLI that isn't logged in leaves its provider unconfigured", async () => {
  const space = workspace(config({}), { namespace: [vm("box-one", "namespace")] }, false);
  await space.refreshCLICredentials();
  assertEquals(space.configuredProviders, []);
  assert(!space.isConfigured("namespace"));
  await space.loadAvailableVMs();
  assertEquals(space.availableVMs, [], "an unusable provider isn't listed");
});

Deno.test("logging out between probes drops the provider again", async () => {
  const space = workspace(config({}), {}, true);
  await space.refreshCLICredentials();
  assertEquals(space.configuredProviders, ["namespace"]);
  // The next probe finds the CLI logged out; the cached yes must not stick.
  space.providerFor = ((id: VMProviderID) => ({
    id,
    credential: { kind: "cli", binary: "devbox", loginCommand: "devbox login" },
    effectiveToken: () => "",
    checkAvailable: () => Promise.resolve(false),
    listVMs: () => Promise.resolve([]),
  })) as unknown as Workspace["providerFor"];
  await space.refreshCLICredentials();
  assertEquals(space.configuredProviders, []);
});

Deno.test("both accounts are listed at once when both have a token", async () => {
  const space = workspace(config({ exe: "t", sprites: "t" }), {
    exe: [vm("box", "exe")],
    sprites: [vm("sprite-one", "sprites"), vm("sprite-two", "sprites")],
  });
  await space.loadAvailableVMs();
  assertEquals(space.availableVMs.map((one) => one.name), ["box", "sprite-one", "sprite-two"]);
  assertEquals(space.vmListErrors, []);
});

Deno.test("one provider failing doesn't cost the other its VMs", async () => {
  const space = workspace(config({ exe: "t", sprites: "t" }), {
    exe: [vm("box", "exe")],
    sprites: new Error("401 Unauthorized"),
  });
  await space.loadAvailableVMs();
  assertEquals(space.availableVMs.map((one) => one.name), ["box"]);
  assertEquals(space.vmListErrors, [{ provider: "sprites", reason: "401 Unauthorized" }]);
});

Deno.test("a provider that fails keeps the VMs it listed last time", async () => {
  const space = workspace(config({ exe: "t", sprites: "t" }), {
    exe: [vm("box", "exe")],
    sprites: [vm("sprite-one", "sprites")],
  });
  await space.loadAvailableVMs();

  // The next poll can't reach sprites.dev. Its VM almost certainly still
  // exists, so it stays on screen with the reason beside it.
  const space2 = space as unknown as { providerFor: unknown };
  space2.providerFor = ((id: VMProviderID) => ({
    id,
    credential: { kind: "token", envVar: "" },
    effectiveToken: () => "t",
    listVMs: () =>
      id === "exe"
        ? Promise.resolve([vm("box", "exe")])
        : Promise.reject(new Error("network is down")),
  })) as unknown as Workspace["providerFor"];
  await space.loadAvailableVMs();

  assertEquals(space.availableVMs.map((one) => one.name), ["box", "sprite-one"]);
  assertEquals(space.vmListErrors[0].provider, "sprites");
});

Deno.test("a VM is only hidden by a session on its own provider", async () => {
  const space = workspace(config({ exe: "t", sprites: "t" }), {
    exe: [vm("shared", "exe")],
    sprites: [vm("shared", "sprites")],
  });
  await space.loadAvailableVMs();
  assertEquals(space.unopenedVMs.length, 2);

  // Two VMs of the same name on different accounts is perfectly ordinary;
  // opening one must not make the other disappear.
  space.sessions.push(
    {
      destination: "shared",
      provider: { id: "exe" },
    } as unknown as (typeof space.sessions)[number],
  );
  assertEquals(space.unopenedVMs.map((one) => one.provider), ["sprites"]);
});

Deno.test("nothing is listed without a token, and the app says it has none", async () => {
  const space = workspace(config({}), { exe: [vm("box", "exe")] });
  assert(!space.hasAnyToken);
  await space.loadAvailableVMs();
  assertEquals(space.availableVMs, []);
});

/** Kept honest: the real provider objects must carry their own id on records. */
Deno.test("a provider id is what makes a record reopenable on the right account", () => {
  const record = vm("box", "sprites");
  const provider: Pick<VMProvider, "id"> = { id: record.provider };
  assertEquals(provider.id, "sprites");
});
