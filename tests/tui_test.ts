import { assert, assertEquals } from "@std/assert";
import {
  center,
  displayWidth,
  dropCells,
  elideHead,
  elideMiddle,
  fit,
  overlay,
  setClipboard,
  setWindowTitle,
  stripAnsi,
  styled,
  truncate,
} from "../src/tui/ansi.ts";
import {
  control,
  dropdown,
  row as listRow,
  scrollToShow,
  TextInput,
  wrap,
} from "../src/tui/widgets.ts";
import { InputDecoder, type KeyEvent, type MouseEvent } from "../src/tui/input.ts";

const RED = "\x1b[31m";
const RESET = "\x1b[0m";
const encoder = new TextEncoder();

Deno.test("displayWidth ignores escape sequences and counts wide characters", () => {
  assertEquals(displayWidth(`${RED}abc${RESET}`), 3);
  assertEquals(displayWidth("日本"), 4);
  assertEquals(displayWidth("é"), 1); // combining accent
  assertEquals(displayWidth("\x1b]0;title\x07x"), 1); // OSC
});

Deno.test("stripAnsi leaves only the visible text", () => {
  assertEquals(stripAnsi(`${RED}hi${RESET}`), "hi");
});

Deno.test("truncate keeps the styling that leads up to what survives", () => {
  const truncated = truncate(`${RED}abcdef${RESET}`, 3);
  assertEquals(displayWidth(truncated), 3);
  assert(truncated.includes(RED));
  assertEquals(stripAnsi(truncated), "abc");
});

Deno.test("truncate substitutes a space for a wide character it would split", () => {
  const truncated = truncate("日本", 1);
  assertEquals(stripAnsi(truncated), " ");
});

Deno.test("fit pads and clips to exactly the width asked for", () => {
  assertEquals(displayWidth(fit("ab", 5)), 5);
  assertEquals(displayWidth(fit("abcdef", 3)), 3);
  assertEquals(displayWidth(fit(`${RED}abcdef`, 4)), 4);
  // A sequence left open by the content can't bleed past the segment.
  assert(fit(`${RED}ab`, 4).endsWith(RESET));
});

Deno.test("dropCells re-opens the styling that was in force at the cut", () => {
  const dropped = dropCells(`${RED}abcdef${RESET}`, 3);
  assertEquals(stripAnsi(dropped), "def");
  assert(dropped.startsWith(RED));
});

Deno.test("overlay writes a panel over a row without disturbing its width", () => {
  const row = fit("0123456789", 10);
  const result = overlay(row, 3, fit("XX", 2), 10);
  assertEquals(stripAnsi(result), "012XX56789");
  assertEquals(displayWidth(result), 10);
});

Deno.test("overlay at the right edge doesn't run past the row", () => {
  const row = fit("0123456789", 10);
  const result = overlay(row, 8, fit("XX", 2), 10);
  assertEquals(stripAnsi(result), "01234567XX");
  assertEquals(displayWidth(result), 10);
});

Deno.test("elideMiddle and elideHead keep the identifying end", () => {
  assertEquals(elideMiddle("abcdefghij", 5), "ab…ij");
  assertEquals(elideHead("/very/long/path/file.ts", 10), "…h/file.ts");
  assertEquals(elideMiddle("short", 10), "short");
});

Deno.test("center pads both sides to the requested width", () => {
  assertEquals(stripAnsi(center("ab", 6)), "  ab  ");
  assertEquals(displayWidth(center("ab", 6)), 6);
});

Deno.test("wrap breaks on words and chops a word too long to fit", () => {
  assertEquals(wrap("the quick brown fox", 10), ["the quick", "brown fox"]);
  assertEquals(wrap("supercalifragilistic", 8), ["supercal", "ifragili", "stic"]);
});

Deno.test("scrollToShow keeps the selection on screen and inside the content", () => {
  assertEquals(scrollToShow(0, 12, 10, 30), 3);
  assertEquals(scrollToShow(5, 2, 10, 30), 2);
  assertEquals(scrollToShow(99, 29, 10, 30), 20);
  assertEquals(scrollToShow(0, 0, 10, 3), 0);
});

Deno.test("TextInput edits, moves and deletes", () => {
  const input = new TextInput("hello");
  input.handle(key("left"));
  input.handle(key("backspace"));
  assertEquals(input.value, "helo");
  input.handle(key("a"));
  assertEquals(input.value, "helao");
  input.handle(key("a", { ctrl: true }));
  input.handle(key("k", { ctrl: true }));
  assertEquals(input.value, "");
});

Deno.test("TextInput ignores Alt chords so they stay app shortcuts", () => {
  const input = new TextInput("x");
  assertEquals(input.handle(key("t", { alt: true })), false);
  assertEquals(input.value, "x");
});

Deno.test("the decoder reads plain keys, control chords and Alt chords", () => {
  const decoder = new InputDecoder();
  assertEquals(names(decoder.feed(encoder.encode("a"))), ["a"]);
  const ctrl = decoder.feed(new Uint8Array([0x03]))[0] as KeyEvent;
  assertEquals([ctrl.name, ctrl.ctrl], ["c", true]);
  const alt = decoder.feed(encoder.encode("\x1bt"))[0] as KeyEvent;
  assertEquals([alt.name, alt.alt], ["t", true]);
});

Deno.test("the decoder names the cursor and function keys", () => {
  const decoder = new InputDecoder();
  assertEquals(names(decoder.feed(encoder.encode("\x1b[A"))), ["up"]);
  assertEquals(names(decoder.feed(encoder.encode("\x1b[6~"))), ["pagedown"]);
  assertEquals(names(decoder.feed(encoder.encode("\x1bOP"))), ["f1"]);
  const shiftTab = decoder.feed(encoder.encode("\x1b[Z"))[0] as KeyEvent;
  assertEquals([shiftTab.name, shiftTab.shift], ["tab", true]);
});

Deno.test("the decoder reads xterm's modifier parameter", () => {
  const decoder = new InputDecoder();
  const event = decoder.feed(encoder.encode("\x1b[1;5C"))[0] as KeyEvent;
  assertEquals([event.name, event.ctrl], ["right", true]);
});

Deno.test("every key event carries the bytes it came from, for the terminal", () => {
  const decoder = new InputDecoder();
  const event = decoder.feed(encoder.encode("\x1b[A"))[0] as KeyEvent;
  assertEquals(new TextDecoder().decode(event.bytes), "\x1b[A");
});

Deno.test("the decoder reads SGR mouse presses, releases and the wheel", () => {
  const decoder = new InputDecoder();
  const down = decoder.feed(encoder.encode("\x1b[<0;10;5M"))[0] as MouseEvent;
  assertEquals([down.kind, down.button, down.x, down.y], ["down", 0, 9, 4]);

  const up = decoder.feed(encoder.encode("\x1b[<0;10;5m"))[0] as MouseEvent;
  assertEquals(up.kind, "up");

  const wheelUp = decoder.feed(encoder.encode("\x1b[<64;1;1M"))[0] as MouseEvent;
  assertEquals([wheelUp.kind, wheelUp.button], ["wheel", -1]);
  const wheelDown = decoder.feed(encoder.encode("\x1b[<65;1;1M"))[0] as MouseEvent;
  assertEquals(wheelDown.button, 1);
});

Deno.test("the decoder reports pointer motion and its modifiers", () => {
  const decoder = new InputDecoder();
  const move = decoder.feed(encoder.encode("\x1b[<35;3;4M"))[0] as MouseEvent;
  assertEquals([move.kind, move.x, move.y], ["move", 2, 3]);
  const shiftClick = decoder.feed(encoder.encode("\x1b[<4;1;1M"))[0] as MouseEvent;
  assertEquals([shiftClick.kind, shiftClick.shift], ["down", true]);
});

Deno.test("the decoder holds a sequence split across reads", () => {
  const decoder = new InputDecoder();
  assertEquals(decoder.feed(encoder.encode("\x1b[")).length, 0);
  assertEquals(names(decoder.feed(encoder.encode("B"))), ["down"]);
});

Deno.test("bracketed paste arrives as one event, not as keystrokes", () => {
  const decoder = new InputDecoder();
  const events = decoder.feed(encoder.encode("\x1b[200~hello\nthere\x1b[201~"));
  assertEquals(events.length, 1);
  assertEquals(events[0].type, "paste");
  if (events[0].type !== "paste") throw new Error("expected paste");
  assertEquals(events[0].text, "hello\nthere");
});

Deno.test("focus in and out are reported", () => {
  const decoder = new InputDecoder();
  const [gained, lost] = decoder.feed(encoder.encode("\x1b[I\x1b[O"));
  assertEquals(gained.type === "focus" && gained.focused, true);
  assertEquals(lost.type === "focus" && lost.focused, false);
});

function key(name: string, modifiers: { ctrl?: boolean; alt?: boolean } = {}) {
  return { name, ctrl: modifiers.ctrl ?? false, alt: modifiers.alt ?? false };
}

function names(events: ReturnType<InputDecoder["feed"]>): string[] {
  return events.filter((event): event is KeyEvent => event.type === "key").map((event) =>
    event.name
  );
}

Deno.test("a focused field keeps its hint, so the caret has a field to sit in", () => {
  const input = new TextInput("");
  assertEquals(stripAnsi(input.render(20, true, "optional")).trim(), "optional");
  assertEquals(displayWidth(input.render(20, true, "optional")), 20);
});

Deno.test("the caret offset follows the cursor through the field", () => {
  const input = new TextInput("abc");
  assertEquals(input.cursorOffset(20), 4); // one gutter cell, then three typed
  input.handle({ name: "home", ctrl: false, alt: false });
  assertEquals(input.cursorOffset(20), 1);
  input.handle({ name: "right", ctrl: false, alt: false });
  assertEquals(input.cursorOffset(20), 2);
});

Deno.test("a value longer than the field scrolls, keeping the caret inside it", () => {
  const input = new TextInput("x".repeat(50));
  const offset = input.cursorOffset(10);
  assert(offset >= 1 && offset < 10, `caret at ${offset} is outside a 10-cell field`);
});

Deno.test("hover tints every kind of control differently from resting", () => {
  assert(control(" Go ", { hovered: true }) !== control(" Go ", {}));
  assert(control(" Go ", { active: true, hovered: true }) !== control(" Go ", { active: true }));
  assert(control(" Go ", { danger: true, hovered: true }) !== control(" Go ", { danger: true }));
  assert(dropdown("v", 12, { hovered: true }) !== dropdown("v", 12, {}));
});

Deno.test("a selected row still shows hover, and unfocused selection is dimmer", () => {
  const selected = listRow("a", 10, { selected: true, focused: true });
  assert(listRow("a", 10, { selected: true, focused: true, hovered: true }) !== selected);
  assert(listRow("a", 10, { selected: true, focused: false }) !== selected);
  assert(listRow("a", 10, { hovered: true }) !== listRow("a", 10, {}));
});

Deno.test("a dropdown says it opens a list", () => {
  assertEquals(stripAnsi(dropdown("exe.dev", 20, {})).includes("▾"), true);
});

Deno.test("the window title never carries a control character", () => {
  assertEquals(setWindowTitle("agent-vm"), "\x1b]2;agent-vm\x07");
  // A newline or a BEL in a session name would end the sequence early and
  // spill the rest onto the screen.
  assertEquals(setWindowTitle("one\ntwo\x07"), "\x1b]2;one two \x07");
});

Deno.test("the clipboard sequence carries base64, not the text", () => {
  assertEquals(setClipboard("aGk="), "\x1b]52;c;aGk=\x07");
});

Deno.test("a row with a background stays that colour across its whole width", () => {
  // Every `styled()` run ends with a reset. Without re-asserting the row's own
  // style after each one, the terminal's background shows through the gaps
  // between runs and across the trailing padding — which is what made panels
  // look patchy.
  const row = fit(` ${styled("label", { fg: "15" })}  ${styled("value", { fg: "244" })}`, 40, {
    bg: "235",
  });
  assertEquals(displayWidth(row), 40);
  assertEquals(backgroundsIn(row), ["235"]);
});

Deno.test("an unstyled row is left exactly as it was", () => {
  // The terminal pane passes tmux's own capture through here; re-asserting a
  // style it never asked for would repaint the program's colours.
  const passed = fit(`${styled("x", { fg: "9" })}y`, 4);
  assertEquals(stripAnsi(passed), "xy  ");
  assertEquals(backgroundsIn(passed), []);
});

/** Every distinct background colour a rendered string actually paints with. */
function backgroundsIn(text: string): string[] {
  const seen = new Set<string>();
  let background: string | null = null;
  let index = 0;
  while (index < text.length) {
    const match = /^\x1b\[([0-9;]*)m/.exec(text.slice(index));
    if (match) {
      const parts = match[1].split(";");
      if (match[1] === "" || match[1] === "0") background = null;
      for (let at = 0; at < parts.length; at += 1) {
        if (parts[at] === "48" && parts[at + 1] === "5") background = parts[at + 2];
        if (parts[at] === "49" || parts[at] === "0") background = null;
      }
      index += match[0].length;
      continue;
    }
    // Only cells that actually carry a colour count; trailing padding included.
    if (background !== null) seen.add(background);
    index += 1;
  }
  return [...seen];
}

Deno.test("Alt+Arrow arrives whole when the terminal sends ESC before the CSI", () => {
  // "Alt sends Escape" terminals spell Alt+Right as ESC then a plain CSI,
  // rather than as CSI with a modifier parameter.
  const decoder = new InputDecoder();
  const events = decoder.feed(new TextEncoder().encode("\x1b\x1b[C"));
  assertEquals(events.length, 1);
  const event = events[0];
  assertEquals(event.type, "key");
  if (event.type !== "key") return;
  assertEquals(event.name, "right");
  assertEquals(event.alt, true);
});

Deno.test("the same holds for the SS3 spelling of an arrow", () => {
  const events = new InputDecoder().feed(new TextEncoder().encode("\x1b\x1bOD"));
  assertEquals(events.length, 1);
  const event = events[0];
  if (event.type !== "key") throw new Error("expected a key");
  assertEquals(event.name, "left");
  assertEquals(event.alt, true);
});

Deno.test("a modified CSI arrow still decodes as Alt on terminals that send one", () => {
  const events = new InputDecoder().feed(new TextEncoder().encode("\x1b[1;3C"));
  assertEquals(events.length, 1);
  const event = events[0];
  if (event.type !== "key") throw new Error("expected a key");
  assertEquals(event.name, "right");
  assertEquals(event.alt, true);
});

Deno.test("a paste whose terminator is split across reads still ends", () => {
  const decoder = new InputDecoder();
  const encode = (text: string) => new TextEncoder().encode(text);
  // The read boundary falls inside the six-byte terminator, which is where a
  // pasted API key used to leave the decoder stuck in paste mode forever —
  // swallowing every keystroke afterwards, in every session.
  assertEquals(decoder.feed(encode("\x1b[200~sk-abc")).length, 0);
  assertEquals(decoder.feed(encode("\x1b[201")).length, 0);
  const events = decoder.feed(encode("~"));
  assertEquals(events.length, 1);
  assertEquals(events[0].type, "paste");
  if (events[0].type !== "paste") return;
  assertEquals(events[0].text, "sk-abc");
});

Deno.test("typing after a split paste is delivered, not swallowed", () => {
  const decoder = new InputDecoder();
  const encode = (text: string) => new TextEncoder().encode(text);
  decoder.feed(encode("\x1b[200~key"));
  decoder.feed(encode("\x1b[2"));
  decoder.feed(encode("01~"));
  const events = decoder.feed(encode("hi"));
  assertEquals(events.map((one) => one.type), ["key", "key"]);
});

Deno.test("a paste arriving whole is unaffected", () => {
  const events = new InputDecoder().feed(new TextEncoder().encode("\x1b[200~text\x1b[201~"));
  assertEquals(events.length, 1);
  if (events[0].type !== "paste") throw new Error("expected a paste");
  assertEquals(events[0].text, "text");
});
