import { assert, assertEquals } from "@std/assert";
import { SessionSidebar } from "../src/ui/session-sidebar.ts";
import { TerminalPane } from "../src/ui/terminal-pane.ts";
import { DiffSidebar } from "../src/ui/diff-sidebar.ts";
import type { Workspace } from "../src/model/workspace.ts";
import type { TerminalSession } from "../src/model/terminal-session.ts";

function diffKey(name: string, shift: boolean) {
  return { name, ctrl: false, alt: false, shift };
}

/** The sidebar only reaches the workspace while rendering, which these don't. */
function stubWorkspace(): Workspace {
  return {
    sessions: [],
    unopenedVMs: [],
    loadingVMs: false,
    selectedSessionID: null,
  } as unknown as Workspace;
}

/** A session with two panes, enough to drive the tab strip. */
function stubSession(): TerminalSession {
  const tabs = [
    {
      paneID: "%1",
      windowID: "@1",
      title: "one",
      screen: [],
      cursor: { x: 0, y: 0, visible: true },
    },
    {
      paneID: "%2",
      windowID: "@2",
      title: "two",
      screen: [],
      cursor: { x: 0, y: 0, visible: true },
    },
  ];
  let selected = "%1";
  return {
    tabs,
    get selectedTabID() {
      return selected;
    },
    get selectedTab() {
      return tabs.find((tab) => tab.paneID === selected) ?? null;
    },
    selectAdjacentTab(offset: number) {
      const index = tabs.findIndex((tab) => tab.paneID === selected);
      selected = tabs[(index + offset + tabs.length) % tabs.length].paneID;
    },
    closeTab() {},
  } as unknown as TerminalSession;
}

Deno.test("the sessions sidebar walks its list, the group toggle, then its button", () => {
  const sidebar = new SessionSidebar(stubWorkspace());
  sidebar.focusFirst();
  assertEquals(sidebar.onNewButton, false);
  assertEquals(sidebar.onGroupToggle, false);
  assertEquals(sidebar.advance(1), true);
  assertEquals(sidebar.onGroupToggle, true);
  assertEquals(sidebar.advance(1), true);
  assertEquals(sidebar.onNewButton, true);
  // Past the last control, so the app knows to move to the next pane.
  assertEquals(sidebar.advance(1), false);
  assertEquals(sidebar.advance(-1), true);
  assertEquals(sidebar.onNewButton, false);
  assertEquals(sidebar.advance(-1), true);
  assertEquals(sidebar.onGroupToggle, false);
  // Back on the list.
  assertEquals(sidebar.advance(-1), false);
});

Deno.test("focusLast lands on the button, for Shift+Tab arriving from the right", () => {
  const sidebar = new SessionSidebar(stubWorkspace());
  sidebar.focusLast();
  assertEquals(sidebar.onNewButton, true);
});

Deno.test("the sidebar's keys navigate the list and report activation", () => {
  const sidebar = new SessionSidebar(stubWorkspace());
  sidebar.focusFirst();
  assertEquals(sidebar.key("down"), "handled");
  assertEquals(sidebar.key("enter"), "activate");
  assertEquals(sidebar.key("delete"), "delete");
  assertEquals(sidebar.key("x"), "ignored");
  // Plain `g` cycles the grouping from the list.
  assertEquals(sidebar.key("g"), "group");
  sidebar.focusLast();
  assertEquals(sidebar.key("enter"), "activate");
  // Arrow keys mean nothing on a button.
  assertEquals(sidebar.key("down"), "ignored");
});

Deno.test("the terminal body is a dead end for Tab, so the shell keeps it", () => {
  const pane = new TerminalPane();
  assert(pane.inBody, "the pane starts ready to type in");
  assertEquals(pane.advance(1), false);
  assertEquals(pane.advance(-1), false);
});

Deno.test("the terminal pane walks its tab strip then its + button", () => {
  const pane = new TerminalPane();
  pane.focusFirst();
  assert(!pane.inBody);
  assertEquals(pane.advance(1), true); // tabs -> new
  assertEquals(pane.advance(1), false); // past the end
  pane.focusLast();
  assertEquals(pane.advance(-1), true); // new -> tabs
  assertEquals(pane.advance(-1), false);
});

Deno.test("the tab strip's keys switch tabs and step into the body", () => {
  const pane = new TerminalPane();
  const session = stubSession();
  pane.focusFirst();
  assertEquals(pane.key(session, "right"), "handled");
  assertEquals(session.selectedTabID, "%2");
  assertEquals(pane.key(session, "left"), "handled");
  assertEquals(session.selectedTabID, "%1");
  assertEquals(pane.key(session, "enter"), "enterBody");

  pane.focusLast();
  assertEquals(pane.key(session, "enter"), "newTab");
});

Deno.test("entering the body puts every key back in the program's hands", () => {
  const pane = new TerminalPane();
  pane.focusFirst();
  pane.enterBody();
  assert(pane.inBody);
});

Deno.test("the diff sidebar walks repo, scope, files and diff", async () => {
  const sidebar = new DiffSidebar(() => {});
  sidebar.focusFirst();
  assertEquals(sidebar.part, "repo");
  // The repo row is a dropdown: Enter asks the app to open its list.
  assertEquals(await sidebar.key(diffKey("enter", false)), "openRepos");

  for (const expected of ["scope", "files", "diff"]) {
    assertEquals(sidebar.advance(1), true);
    assertEquals(sidebar.part, expected);
  }
  assertEquals(sidebar.advance(1), false);

  sidebar.focusLast();
  assertEquals(sidebar.part, "diff");
  assertEquals(sidebar.advance(-1), true);
  assertEquals(sidebar.part, "files");
});

Deno.test("the diff sidebar's lists and diff pane take the arrow keys", async () => {
  const sidebar = new DiffSidebar(() => {});
  sidebar.focusFirst();
  // Left and right step the repo filter without opening the list; the dropdown
  // claims them whether or not there is another repo to step to.
  assertEquals(await sidebar.key(diffKey("right", false)), true);
  assertEquals(await sidebar.key(diffKey("q", false)), false);

  sidebar.part = "scope";
  assertEquals(await sidebar.key(diffKey("down", false)), true);
  assertEquals(await sidebar.key(diffKey("end", false)), true);
  assertEquals(await sidebar.key(diffKey("q", false)), false);

  sidebar.part = "diff";
  assertEquals(await sidebar.key(diffKey("pagedown", false)), true);
  assertEquals(await sidebar.key(diffKey("home", false)), true);
});

Deno.test("the diff pane's search claims Esc, but only while it has the keyboard", async () => {
  const sidebar = new DiffSidebar(() => {});
  sidebar.part = "diff";
  assert(!sidebar.searchActive, "nothing is being searched yet");
  assertEquals(await sidebar.key(diffKey("/", false)), true);
  assert(sidebar.searchActive, "the field is open, so Esc belongs here");

  // Tabbing on to the file list hands Esc back to the app, even though the
  // query is still highlighting matches behind it.
  sidebar.part = "files";
  assert(!sidebar.searchActive);

  sidebar.part = "diff";
  assertEquals(await sidebar.key(diffKey("escape", false)), true);
  assert(!sidebar.searchActive, "Esc dropped the search");
});

Deno.test("y asks the app to copy, from every part of the diff pane", async () => {
  const sidebar = new DiffSidebar(() => {});
  for (const part of ["repo", "scope", "files", "diff"] as const) {
    sidebar.part = part;
    assertEquals(await sidebar.key(diffKey("y", false)), "copy");
  }
});

Deno.test("Alt+↑/↓ walks the diff sidebar's stacked panes and wraps", () => {
  const sidebar = new DiffSidebar(() => {});
  sidebar.focusFirst();
  assertEquals(sidebar.part, "repo");
  for (const expected of ["scope", "files", "diff"]) {
    sidebar.cyclePart(1);
    assertEquals(sidebar.part, expected);
  }
  // Wrapping, because this key moves within the sidebar — Alt+←/→ is how you
  // leave it, so running off the end here should never strand the keyboard.
  sidebar.cyclePart(1);
  assertEquals(sidebar.part, "repo");
  sidebar.cyclePart(-1);
  assertEquals(sidebar.part, "diff");
});
