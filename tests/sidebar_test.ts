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

function stubWorkspace(sessions: TerminalSession[], selected: string | null): Workspace {
  return {
    sessions,
    unopenedVMs: [],
    loadingVMs: false,
    selectedSessionID: selected,
  } as unknown as Workspace;
}

function rows(workspace: Workspace): string[] {
  const sidebar = new SessionSidebar(workspace);
  return sidebar
    .render({ x: 0, y: 0, width: 26, height: 10 }, new HitMap(), false)
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

Deno.test("the dot doesn't crowd out the name it sits beside", () => {
  const lines = rows(stubWorkspace([stubSession("a", "a-rather-long-session-name", true)], "b"));
  const row = lines.find((line) => line.includes("●"));
  assert(row, "no marked row");
  assertEquals(row.length, 26);
  assert(row.includes("…"), `a name that long should elide: ${row}`);
});
