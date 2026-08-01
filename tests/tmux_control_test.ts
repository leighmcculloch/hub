import { assertEquals } from "@std/assert";
import {
  capturePaneCommand,
  paneTitle,
  parseCursor,
  parsePanes,
  sendKeysCommands,
  TmuxControlParser,
  TmuxLineBuffer,
  unescapeOutput,
} from "../src/tmux/control.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function line(text: string): Uint8Array {
  return encoder.encode(text);
}

Deno.test("parsePanes reads every field of a listing row", () => {
  const panes = parsePanes(["@1|0|1|1|%2|0|1|4|9|zsh|/home/me/repo"]);
  assertEquals(panes.length, 1);
  assertEquals(panes[0], {
    id: "%2",
    windowID: "@1",
    windowIndex: 0,
    windowName: "zsh",
    panesInWindow: 1,
    index: 0,
    isActive: true,
    cursorX: 4,
    cursorY: 9,
    currentPath: "/home/me/repo",
  });
});

Deno.test("parsePanes keeps a separator inside a window name", () => {
  const panes = parsePanes(["@1|0|1|1|%2|0|1|0|0|a|b|c|/tmp"]);
  assertEquals(panes[0].windowName, "a|b|c");
  assertEquals(panes[0].currentPath, "/tmp");
});

Deno.test("parsePanes skips rows missing fields rather than guessing", () => {
  assertEquals(parsePanes(["@1|0|1"]), []);
  assertEquals(parsePanes(["@1|x|1|1|%2|0|1|0|0|zsh|/tmp"]), []);
});

Deno.test("a pane is only active when its window is too", () => {
  // window_active=0 with pane_active=1: the active pane of another window.
  const panes = parsePanes(["@2|1|1|0|%5|0|1|0|0|zsh|/tmp"]);
  assertEquals(panes[0].isActive, false);
});

Deno.test("paneTitle qualifies a split window's panes", () => {
  const base = parsePanes(["@1|0|2|1|%2|1|1|0|0|vim|/tmp"])[0];
  assertEquals(paneTitle(base), "vim:1");
  const single = parsePanes(["@1|0|1|1|%2|0|1|0|0|vim|/tmp"])[0];
  assertEquals(paneTitle(single), "vim");
});

Deno.test("parseCursor reads the position, the flags and the history size", () => {
  assertEquals(parseCursor(["12,3,1,400,1"]), {
    x: 12,
    y: 3,
    visible: true,
    historySize: 400,
    alternate: true,
  });
  // A reply from before those fields were asked for still parses.
  assertEquals(parseCursor(["0,0,0"]), {
    x: 0,
    y: 0,
    visible: false,
    historySize: 0,
    alternate: false,
  });
  assertEquals(parseCursor(["nonsense"]), null);
});

Deno.test("capture-pane reads the live screen, or a window of the scrollback", () => {
  assertEquals(capturePaneCommand("%1"), "capture-pane -p -e -t %1");
  // Scrolled back 30 lines in a 20-row pane: the 20 lines ending 30 above the
  // top of the live screen.
  assertEquals(capturePaneCommand("%1", 30, 20), "capture-pane -p -e -S -30 -E -11 -t %1");
  // No height yet means no window to ask for, so it falls back to the screen.
  assertEquals(capturePaneCommand("%1", 30, 0), "capture-pane -p -e -t %1");
});

Deno.test("sendKeysCommands hex-encodes bytes and splits long payloads", () => {
  assertEquals(sendKeysCommands("%1", new Uint8Array([0x61, 0x0d])), ["send-keys -t %1 -H 61 0d"]);
  const long = new Uint8Array(1100).fill(0x41);
  assertEquals(sendKeysCommands("%1", long).length, 3);
});

Deno.test("unescapeOutput turns octal escapes back into bytes", () => {
  assertEquals(Array.from(unescapeOutput(line("a\\015b"))), [0x61, 0x0d, 0x62]);
  // A lone backslash is kept rather than eating what follows.
  assertEquals(decoder.decode(unescapeOutput(line("a\\z"))), "a\\z");
});

Deno.test("unescapeOutput leaves raw UTF-8 alone", () => {
  assertEquals(decoder.decode(unescapeOutput(line("héllo"))), "héllo");
});

Deno.test("TmuxLineBuffer holds a partial line until the rest arrives", () => {
  const buffer = new TmuxLineBuffer();
  assertEquals(buffer.lines(line("%output %1 he")).length, 0);
  const lines = buffer.lines(line("llo\n%exit\n"));
  assertEquals(lines.map((one) => decoder.decode(one)), ["%output %1 hello", "%exit"]);
});

Deno.test("TmuxLineBuffer strips a trailing carriage return", () => {
  const buffer = new TmuxLineBuffer();
  const lines = buffer.lines(line("%exit\r\n"));
  assertEquals(decoder.decode(lines[0]), "%exit");
});

Deno.test("the parser pairs a reply block with its guard", () => {
  const parser = new TmuxControlParser();
  assertEquals(parser.consume(line("%begin 1 7 1")), null);
  assertEquals(parser.consume(line("one")), null);
  const event = parser.consume(line("%end 1 7 1"));
  assertEquals(event, { type: "reply", reply: { lines: ["one"], isError: false } });
});

Deno.test("a block tmux ran for itself is dropped, not counted as a reply", () => {
  const parser = new TmuxControlParser();
  parser.consume(line("%begin 1 7 0"));
  parser.consume(line("noise"));
  assertEquals(parser.consume(line("%end 1 7 0")), null);
});

Deno.test("a captured line that looks like a guard doesn't end the block early", () => {
  const parser = new TmuxControlParser();
  parser.consume(line("%begin 1 7 1"));
  parser.consume(line("%end 1 99 1"));
  parser.consume(line("real"));
  const event = parser.consume(line("%end 1 7 1"));
  assertEquals(event, {
    type: "reply",
    reply: { lines: ["%end 1 99 1", "real"], isError: false },
  });
});

Deno.test("%error closes a block as a failed reply", () => {
  const parser = new TmuxControlParser();
  parser.consume(line("%begin 1 2 1"));
  parser.consume(line("no such pane"));
  const event = parser.consume(line("%error 1 2 1"));
  assertEquals(event, { type: "reply", reply: { lines: ["no such pane"], isError: true } });
});

Deno.test("%output carries the pane id and its unescaped bytes", () => {
  const parser = new TmuxControlParser();
  const event = parser.consume(line("%output %3 hi\\015"));
  assertEquals(event?.type, "output");
  if (event?.type !== "output") throw new Error("expected output");
  assertEquals(event.pane, "%3");
  assertEquals(Array.from(event.bytes), [0x68, 0x69, 0x0d]);
});

Deno.test("every layout notification collapses to one pane-list change", () => {
  const parser = new TmuxControlParser();
  for (const notification of ["%window-add @2", "%layout-change @1", "%window-close @3"]) {
    assertEquals(parser.consume(line(notification)), { type: "paneListChanged" });
  }
});

Deno.test("%exit carries a reason when tmux gives one", () => {
  const parser = new TmuxControlParser();
  assertEquals(parser.consume(line("%exit")), { type: "exit", reason: null });
  assertEquals(parser.consume(line("%exit server exited")), {
    type: "exit",
    reason: "server exited",
  });
});
