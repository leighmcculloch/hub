import { assert, assertEquals } from "@std/assert";
import { stripAnsi } from "../src/tui/ansi.ts";
import { HitMap } from "../src/tui/widgets.ts";
import { SelectPopup } from "../src/ui/select-popup.ts";

const OPTIONS = [
  { label: "anthropic/claude-opus-5", detail: "claude-opus-5" },
  { label: "anthropic/claude-sonnet-5", detail: "claude-sonnet-5" },
  { label: "fireworks/glm-5p2", detail: "accounts/fireworks/models/glm-5p2" },
];

function key(name: string) {
  return { name, ctrl: false, alt: false, shift: false };
}

/** Lay the popup out once, which is what fixes the visible list for input. */
function laidOut(popup: SelectPopup): string[] {
  return popup.render(100, 30, new HitMap()).lines.map(stripAnsi);
}

Deno.test("the list shows every option, so none of them has to be guessed at", () => {
  const popup = new SelectPopup("Model", OPTIONS, 0, () => {});
  const text = laidOut(popup).join("\n");
  for (const option of OPTIONS) assert(text.includes(option.label), `missing ${option.label}`);
});

Deno.test("the option that is currently the value is marked and pre-selected", () => {
  const chosen: number[] = [];
  const popup = new SelectPopup("Model", OPTIONS, 2, (index) => chosen.push(index));
  const marked = laidOut(popup).find((line) => line.includes("●"));
  assert(marked?.includes("fireworks/glm-5p2"), `marked the wrong row: ${marked}`);
  // Opening on the current value means Enter is a no-op rather than a surprise.
  popup.key(key("enter"));
  assertEquals(chosen, [2]);
});

Deno.test("typing filters the list", () => {
  const popup = new SelectPopup("Model", OPTIONS, 0, () => {});
  laidOut(popup);
  for (const character of "fire") popup.key(key(character));
  const text = laidOut(popup).join("\n");
  assert(text.includes("fireworks/glm-5p2"));
  assert(!text.includes("claude-opus-5"));
});

Deno.test("the filter matches the detail as well as the label", () => {
  const popup = new SelectPopup("Model", OPTIONS, 0, () => {});
  laidOut(popup);
  for (const character of "accounts") popup.key(key(character));
  assert(laidOut(popup).join("\n").includes("fireworks/glm-5p2"));
});

Deno.test("choosing from a filtered list reports the original index", () => {
  const chosen: number[] = [];
  const popup = new SelectPopup("Model", OPTIONS, 0, (index) => chosen.push(index));
  laidOut(popup);
  for (const character of "glm") popup.key(key(character));
  laidOut(popup);
  assertEquals(popup.key(key("enter")), true);
  assertEquals(chosen, [2]);
});

Deno.test("a filter that matches nothing says so and chooses nothing", () => {
  const chosen: number[] = [];
  const popup = new SelectPopup("Model", OPTIONS, 0, (index) => chosen.push(index));
  laidOut(popup);
  for (const character of "zzz") popup.key(key(character));
  assert(laidOut(popup).join("\n").includes("No option matches"));
  popup.key(key("enter"));
  assertEquals(chosen, []);
});

Deno.test("arrows move the selection and stop at the ends", () => {
  const chosen: number[] = [];
  const popup = new SelectPopup("Model", OPTIONS, 0, (index) => chosen.push(index));
  laidOut(popup);
  popup.key(key("down"));
  popup.key(key("down"));
  popup.key(key("down")); // past the end
  popup.key(key("enter"));
  assertEquals(chosen, [2]);
});

Deno.test("escape closes without choosing", () => {
  const chosen: number[] = [];
  const popup = new SelectPopup("Model", OPTIONS, 0, (index) => chosen.push(index));
  laidOut(popup);
  assertEquals(popup.key(key("escape")), true);
  assertEquals(chosen, []);
});

Deno.test("clicking a row chooses that option", () => {
  const chosen: number[] = [];
  const popup = new SelectPopup("Model", OPTIONS, 0, (index) => chosen.push(index));
  laidOut(popup);
  assertEquals(popup.click("popup.option:1"), true);
  assertEquals(chosen, [1]);
  // A click anywhere else is not a choice.
  assertEquals(popup.click("popup.filter"), false);
});

Deno.test("the popup registers a region per visible row, for the mouse", () => {
  const popup = new SelectPopup("Model", OPTIONS, 0, () => {});
  const hits = new HitMap();
  const { rect } = popup.render(100, 30, hits);
  // The filter sits on the first inner row, the options below it.
  assertEquals(hits.hit(rect.x + 2, rect.y + 1)?.id, "popup.filter");
  assertEquals(hits.hit(rect.x + 2, rect.y + 2)?.id, "popup.option:0");
  assertEquals(hits.hit(rect.x + 2, rect.y + 3)?.id, "popup.option:1");
});

Deno.test("the caret sits in the filter, so it is clear typing filters", () => {
  const popup = new SelectPopup("Model", OPTIONS, 0, () => {});
  const { rect } = popup.render(100, 30, new HitMap());
  const caret = popup.cursorPosition();
  assert(caret !== null);
  assertEquals(caret.y, rect.y + 1);
  assert(caret.x > rect.x && caret.x < rect.x + rect.width);

  for (const character of "ab") popup.key(key(character));
  popup.render(100, 30, new HitMap());
  assertEquals(popup.cursorPosition()!.x, caret.x + 2);
});
