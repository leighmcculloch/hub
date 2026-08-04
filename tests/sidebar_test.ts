import { assert, assertEquals } from "@std/assert";
import { stripAnsi } from "../src/tui/ansi.ts";
import { HitMap } from "../src/tui/widgets.ts";
import { SessionSidebar } from "../src/ui/session-sidebar.ts";
import type { SidebarGrouping } from "../src/config/layout-store.ts";
import type { Workspace } from "../src/model/workspace.ts";
import type { TerminalSession } from "../src/model/terminal-session.ts";

function stubSession(
  id: string,
  name: string,
  unseen: boolean,
  options: {
    provider?: "exe" | "sprites";
    destination?: string | null;
    workingDirectory?: string | null;
  } = {},
): TerminalSession {
  const provider = options.provider ?? "exe";
  return {
    id,
    displayName: name,
    hasUnseenOutput: unseen,
    isDisconnected: false,
    isConnecting: false,
    elapsedMs: 0,
    provider: { id: provider },
    destination: options.destination !== undefined ? options.destination : `${name}.exe.xyz`,
    workingDirectory: options.workingDirectory ?? null,
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

function rows(workspace: Workspace, width = 26, grouping: SidebarGrouping = "none"): string[] {
  const sidebar = new SessionSidebar(workspace);
  sidebar.grouping = grouping;
  return sidebar
    .render({ x: 0, y: 0, width, height: 10 }, new HitMap(), false)
    .map(stripAnsi);
}

/** Raw styled lines for a focused or unfocused sidebar, colours intact. */
function rawRows(
  workspace: Workspace,
  width = 26,
  focused: boolean,
  grouping: SidebarGrouping = "none",
): string[] {
  const sidebar = new SessionSidebar(workspace);
  sidebar.grouping = grouping;
  return sidebar.render({ x: 0, y: 0, width, height: 12 }, new HitMap(), focused);
}

/** The SGR sequence that paints the focused pane's title bar. */
const PANE_FOCUS_BG = "\x1b[48;5;239m";
/** The background a selected row carries in a pane that has the keyboard. */
const SELECTION_BG = "48;5;24m";
/** The accent, which the keyboard's row wears as its edge marker. */
const ACCENT_FG = "38;5;39m";

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

Deno.test("grouping by provider puts a heading per host, with sessions and VMs together", () => {
  const sessions = [
    stubSession("a", "alpha", false, { provider: "exe" }),
    stubSession("b", "bravo", false, { provider: "sprites", destination: "bravo.spr" }),
  ];
  const vms = [stubVM("sprite-one", "sprites"), stubVM("box", "exe")];
  const lines = rows(
    stubWorkspace(sessions, "a", [], { vms, providers: ["exe", "sprites"] }),
    30,
    "provider",
  );
  const text = lines.join("\n");
  // Both hosts have a heading, so which account an instance is on is the first
  // thing you read — the point of grouping by provider.
  assert(text.includes("EXE.DEV"), `no exe.dev heading: ${text}`);
  assert(text.includes("SPRITES.DEV"), `no sprites.dev heading: ${text}`);
  // An open session and a reopenable VM on the same host sit under the same
  // heading, so the host's instances are in one place.
  const spritesStart = lines.findIndex((line) => line.includes("SPRITES.DEV"));
  const alphaLine = lines.findIndex((line) => line.includes("alpha"));
  const boxLine = lines.findIndex((line) => line.includes("box"));
  assert(alphaLine > -1 && boxLine > -1, "exe.dev session and VM both present");
  assert(
    alphaLine < spritesStart && boxLine < spritesStart,
    `exe.dev items not under the exe.dev heading: ${text}`,
  );
});

Deno.test("grouping by provider gives local sessions their own heading", () => {
  const sessions = [
    stubSession("local", "Local", false, { provider: "exe", destination: null }),
    stubSession("vm", "vm-one", false, { provider: "exe" }),
  ];
  const lines = rows(stubWorkspace(sessions, "local"), 30, "provider");
  const text = lines.join("\n");
  assert(text.includes("LOCAL"), `no Local heading: ${text}`);
  assert(text.includes("EXE.DEV"), `no exe.dev heading: ${text}`);
});

Deno.test("grouping by provider drops the per-row badge, since the host is the heading", () => {
  const vms = [stubVM("box", "exe"), stubVM("sprite-one", "sprites")];
  const lines = rows(
    stubWorkspace([], null, [], { vms, providers: ["exe", "sprites"] }),
    34,
    "provider",
  );
  const box = lines.find((line) => line.includes("box"));
  const sprite = lines.find((line) => line.includes("sprite-one"));
  assert(box && !box.trimEnd().endsWith("exe"), `badge shown under a provider heading: ${box}`);
  assert(
    sprite && !sprite.trimEnd().endsWith("spr"),
    `badge shown under a provider heading: ${sprite}`,
  );
});

Deno.test("grouping by repo names the session's working directory as the heading", () => {
  const sessions = [
    stubSession("a", "alpha", false, { workingDirectory: "/home/u/leigh/hub" }),
    stubSession("b", "bravo", false, { workingDirectory: "/home/u/leigh/pi" }),
  ];
  const lines = rows(stubWorkspace(sessions, "a"), 30, "repo");
  const text = lines.join("\n");
  assert(text.includes("LEIGH/HUB"), `no repo heading: ${text}`);
  assert(text.includes("LEIGH/PI"), `no second repo heading: ${text}`);
});

Deno.test("grouping by repo collects repo-less sessions under No repo", () => {
  const sessions = [
    stubSession("a", "alpha", false, { workingDirectory: null }),
    stubSession("b", "bravo", false, { workingDirectory: "/home/u/leigh/hub" }),
  ];
  const lines = rows(stubWorkspace(sessions, "a"), 30, "repo");
  const text = lines.join("\n");
  assert(text.includes("NO REPO"), `no No repo heading: ${text}`);
  assert(text.includes("LEIGH/HUB"), `no repo heading for the repo'd session: ${text}`);
});

Deno.test("grouping by repo keeps two sessions in the same repo under one heading", () => {
  // A repo shared by two sessions must not split into two headings just
  // because another repo's session sorts between them on the first pass.
  const sessions = [
    stubSession("a", "alpha", false, { workingDirectory: "/home/u/leigh/hub" }),
    stubSession("b", "bravo", false, { workingDirectory: "/home/u/leigh/pi" }),
    stubSession("c", "charlie", false, { workingDirectory: "/home/u/leigh/hub" }),
  ];
  const lines = rows(stubWorkspace(sessions, "a"), 30, "repo");
  const hubHeaders = lines.filter((line) => line.includes("LEIGH/HUB"));
  assertEquals(hubHeaders.length, 1, `repo heading repeated: ${lines.join("\n")}`);
  // And both sessions sit under that one heading, with nothing between them.
  const hubIndex = lines.findIndex((line) => line.includes("LEIGH/HUB"));
  const alphaIndex = lines.findIndex((line) => line.includes("alpha"));
  const charlieIndex = lines.findIndex((line) => line.includes("charlie"));
  const piIndex = lines.findIndex((line) => line.includes("LEIGH/PI"));
  assert(alphaIndex > hubIndex && charlieIndex > hubIndex, "sessions not under the hub heading");
  assert(
    alphaIndex < piIndex && charlieIndex < piIndex,
    "hub sessions came after the pi heading",
  );
});

Deno.test("grouping by state separates connecting, waiting and output-ready sessions", () => {
  const sessions = [
    stubSession("a", "alpha", false), // waiting (live, no unseen)
    stubSession("b", "bravo", true), // output ready (has unseen)
  ];
  // Make `bravo` live so it isn't "connecting": unseen output implies content.
  (sessions[1] as unknown as { hasContent: boolean }).hasContent = true;
  const lines = rows(stubWorkspace(sessions, "a"), 30, "state");
  const text = lines.join("\n");
  assert(text.includes("WAITING"), `no Waiting heading: ${text}`);
  assert(text.includes("OUTPUT READY"), `no Output ready heading: ${text}`);
});

Deno.test("grouping by state puts a disconnected session under Disconnected", () => {
  const sessions = [
    stubSession("a", "alpha", false),
    stubSession("b", "bravo", false),
  ];
  (sessions[1] as unknown as { isDisconnected: boolean }).isDisconnected = true;
  const lines = rows(stubWorkspace(sessions, "a"), 30, "state");
  const text = lines.join("\n");
  assert(text.includes("DISCONNECTED"), `no Disconnected heading: ${text}`);
  assert(text.includes("WAITING"), `no Waiting heading for the live one: ${text}`);
});

Deno.test("the grouping toggle cycles through every mode and wraps", () => {
  const sidebar = new SessionSidebar(stubWorkspace([], null));
  const modes = ["provider", "repo", "state", "none"] as const;
  for (let index = 0; index < modes.length; index += 1) {
    assertEquals(sidebar.grouping, modes[index], `mode ${index} should be ${modes[index]}`);
    sidebar.cycleGrouping();
  }
  // After none it wraps back to provider.
  assertEquals(sidebar.grouping, "provider");
});

Deno.test("plain g from the list reports the group action for the app to apply", () => {
  const sidebar = new SessionSidebar(stubWorkspace([], null));
  sidebar.focusFirst();
  assertEquals(sidebar.key("g"), "group");
  // From the group toggle row, enter and g both act on the toggle.
  sidebar.part = "group";
  assertEquals(sidebar.key("enter"), "group");
  assertEquals(sidebar.key("g"), "group");
});

Deno.test("the grouping toggle is a stop on the focus ring, above the list", () => {
  const sidebar = new SessionSidebar(stubWorkspace([], null));
  sidebar.focusFirst();
  assert(sidebar.onGroupToggle, "the chip in the title bar is the first stop");
  sidebar.advance(1);
  assert(!sidebar.onGroupToggle, "one step lands on the list");
  // And the list is the last stop: starting a session is a status-bar key now.
  assert(!sidebar.advance(1), "there is nothing below the list");
});

Deno.test("the grouping chip rides in the title bar, not in a row of its own", () => {
  // As a full-width footer row it read as one more session to select, and lit
  // up the way a selected row does.
  const ws = stubWorkspace([stubSession("a", "alpha", false)], "a");
  const lines = rows(ws, 26, "provider").map((line) => line.trimEnd());
  const title = lines[0];
  assert(title.includes("SESSIONS"), `the first row is not the title bar: ${title}`);
  assert(title.includes("Provider"), `the grouping isn't shown in the title bar: ${title}`);
  assert(
    !lines.some((line) => line.startsWith(" Group:")),
    `the old full-width toggle row is still drawn: ${lines.join("\n")}`,
  );
});

Deno.test("the sidebar says it has the keyboard in its title bar alone", () => {
  // One row, the same row every pane has. Painting the pane's empty space
  // instead couldn't mean the same thing in the terminal pane, whose body is
  // tmux's own rendering.
  const ws = stubWorkspace([stubSession("a", "alpha", false)], "a");
  const focused = rawRows(ws, 26, true);
  const unfocused = rawRows(ws, 26, false);
  assert(focused[0].includes(PANE_FOCUS_BG), `no focus tint on the title bar: ${focused[0]}`);
  assert(
    focused.slice(1).every((line) => !line.includes(PANE_FOCUS_BG)),
    "the focus tint leaked past the title bar",
  );
  assert(
    !unfocused.some((line) => line.includes(PANE_FOCUS_BG)),
    "unfocused sidebar shows the focus tint",
  );
});

Deno.test("the open session and the keyboard's row are told apart", () => {
  // Both used to draw as "selected", which left two rows looking equally
  // chosen and no way to see which one Enter would act on.
  const ws = stubWorkspace([
    stubSession("a", "alpha", false),
    stubSession("b", "bravo", false),
  ], "a");
  const sidebar = new SessionSidebar(ws);
  sidebar.grouping = "none";
  sidebar.focusList();
  const lines = sidebar.render({ x: 0, y: 0, width: 26, height: 8 }, new HitMap(), true);
  const alpha = lines.find((line) => stripAnsi(line).includes("alpha"))!;
  const bravo = lines.find((line) => stripAnsi(line).includes("bravo"))!;
  // The open session carries the selection colour; the cursor row doesn't.
  assert(alpha.includes(SELECTION_BG), `the open session isn't marked: ${alpha}`);
  assert(!bravo.includes(SELECTION_BG), `an unopened row wears the selection: ${bravo}`);

  // Move the keyboard onto the other row: it takes the accent edge, and the
  // open session keeps its colour.
  sidebar.move(1);
  const moved = sidebar.render({ x: 0, y: 0, width: 26, height: 8 }, new HitMap(), true);
  const cursorRow = moved.find((line) => stripAnsi(line).includes("bravo"))!;
  assert(cursorRow.includes(ACCENT_FG), `the keyboard's row has no edge marker: ${cursorRow}`);
  assert(
    moved.find((line) => stripAnsi(line).includes("alpha"))!.includes(SELECTION_BG),
    "the open session lost its marking when the keyboard moved off it",
  );
});
