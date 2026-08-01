import { assert, assertEquals } from "@std/assert";
import { stripAnsi } from "../src/tui/ansi.ts";
import { HitMap } from "../src/tui/widgets.ts";
import { SessionSidebar } from "../src/ui/session-sidebar.ts";
import type { Workspace } from "../src/model/workspace.ts";
import type { TerminalSession } from "../src/model/terminal-session.ts";

function stubSession(id: string, name: string, unseen: boolean): TerminalSession {
  return {
    id,
    displayName: name,
    hasUnseenOutput: unseen,
    isDisconnected: false,
    isConnecting: false,
    elapsedMs: 0,
  } as unknown as TerminalSession;
}

function stubVM(name: string, provider: "exe" | "sprites") {
  return { name, destination: name, webURL: null, status: "running", provider };
}

function stubWorkspace(
  sessions: TerminalSession[],
  selected: string | null,
  vmListErrors: Array<{ provider: "exe" | "sprites"; reason: string }> = [],
  options: { vms?: ReturnType<typeof stubVM>[]; providers?: Array<"exe" | "sprites"> } = {},
): Workspace {
  return {
    sessions,
    unopenedVMs: options.vms ?? [],
    loadingVMs: false,
    selectedSessionID: selected,
    vmListErrors,
    hasAnyToken: true,
    configuredProviders: options.providers ?? ["exe"],
  } as unknown as Workspace;
}

function rows(workspace: Workspace, width = 26): string[] {
  const sidebar = new SessionSidebar(workspace);
  return sidebar
    .render({ x: 0, y: 0, width, height: 10 }, new HitMap(), false)
    .map(stripAnsi);
}

Deno.test("a background session that has printed something carries a dot", () => {
  const lines = rows(stubWorkspace([
    stubSession("a", "alpha", false),
    stubSession("b", "bravo", true),
  ], "a"));
  const alpha = lines.find((line) => line.includes("alpha"));
  const bravo = lines.find((line) => line.includes("bravo"));
  assert(alpha && !alpha.includes("●"), `quiet session was marked: ${alpha}`);
  assert(bravo?.trimEnd().endsWith("●"), `busy session was not marked: ${bravo}`);
});

Deno.test("the session you are looking at never claims unseen output", () => {
  // The flag is cleared as it becomes foreground, but a frame can be drawn from
  // the same turn that raised it, and a dot on the open session says nothing.
  const lines = rows(stubWorkspace([stubSession("a", "alpha", true)], "a"));
  const alpha = lines.find((line) => line.includes("alpha"));
  assert(alpha && !alpha.includes("●"), `the open session was marked: ${alpha}`);
});

Deno.test("a failed VM listing says so where the VMs would have been", () => {
  // Wide enough for the whole reason; a narrow sidebar elides it, which is the
  // widget's job rather than this test's subject.
  const lines = rows(
    stubWorkspace([], null, [{ provider: "sprites", reason: "401 Unauthorized" }]),
    44,
  );
  const text = lines.join("\n");
  assert(text.toLowerCase().includes("existing"), "the section should still appear");
  // Named, because with both providers listed "which one" is half the answer.
  assert(text.includes("sprites.dev"), `no provider named: ${text}`);
  assert(text.includes("401 Unauthorized"), `no reason shown: ${text}`);
});

Deno.test("the notice isn't something the keyboard can land on", () => {
  const workspace = stubWorkspace([stubSession("a", "alpha", false)], "a", [
    { provider: "exe", reason: "network is down" },
  ]);
  const sidebar = new SessionSidebar(workspace);
  sidebar.render({ x: 0, y: 0, width: 26, height: 10 }, new HitMap(), true);
  // Rows: Sessions header, alpha, Existing header, notice. Walking off the end
  // has to wrap past both headers and the notice, back onto the one session.
  sidebar.move(1);
  assertEquals(sidebar.current?.kind, "session");
  sidebar.move(-1);
  assertEquals(sidebar.current?.kind, "session");
});

Deno.test("the dot doesn't crowd out the name it sits beside", () => {
  const lines = rows(stubWorkspace([stubSession("a", "a-rather-long-session-name", true)], "b"));
  const row = lines.find((line) => line.includes("●"));
  assert(row, "no marked row");
  assertEquals(row.length, 26);
  assert(row.includes("…"), `a name that long should elide: ${row}`);
});

Deno.test("a VM row says which account it is on, but only when there are two", () => {
  const vms = [stubVM("box", "exe"), stubVM("sprite-one", "sprites")];
  const both = rows(stubWorkspace([], null, [], { vms, providers: ["exe", "sprites"] }), 34);
  const box = both.find((line) => line.includes("box"));
  const sprite = both.find((line) => line.includes("sprite-one"));
  assert(box?.trimEnd().endsWith("exe"), `no badge on the exe.dev VM: ${box}`);
  assert(sprite?.trimEnd().endsWith("spr"), `no badge on the sprites.dev VM: ${sprite}`);

  // With one account configured the badge is noise, so it isn't drawn.
  const one = rows(stubWorkspace([], null, [], { vms, providers: ["exe"] }), 34);
  const only = one.find((line) => line.includes("box"));
  assert(only && !only.trimEnd().endsWith("exe"), `badge shown for one account: ${only}`);
});
