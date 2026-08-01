import { assertEquals } from "@std/assert";
import { Color, stripAnsi } from "../src/tui/ansi.ts";
import { parseDiff } from "../src/git/diff-parse.ts";
import { matchingRows, matchOrdinal, nextLandmark, nextMatch } from "../src/git/diff-search.ts";
import { highlighted, scrollLabel } from "../src/ui/diff-sidebar.ts";

const DIFF = `diff --git a/one.ts b/one.ts
@@ -1,3 +1,3 @@ function one()
 const value = 1;
-console.log(value);
+console.log(VALUE);
diff --git a/two.ts b/two.ts
@@ -10,2 +10,2 @@
-const other = 2;
+const other = 3;
`;

const rows = parseDiff(DIFF, true).rows;

Deno.test("a search finds rows whatever case they were written in", () => {
  const matches = matchingRows(rows, "value");
  assertEquals(matches.length, 3);
  // The lower-case query still finds `VALUE`, which is the point.
  assertEquals(matches.map((index) => rows[index].kind), ["context", "deletion", "addition"]);
  assertEquals(matchingRows(rows, ""), []);
  assertEquals(matchingRows(rows, "nothing here"), []);
});

Deno.test("stepping through matches wraps at both ends", () => {
  const matches = [2, 5, 9];
  assertEquals(nextMatch(matches, 0, 1), 2);
  assertEquals(nextMatch(matches, 5, 1), 9);
  // Past the last match, back to the first rather than stopping dead.
  assertEquals(nextMatch(matches, 9, 1), 2);
  assertEquals(nextMatch(matches, 5, -1), 2);
  assertEquals(nextMatch(matches, 2, -1), 9);
  assertEquals(nextMatch([], 0, 1), null);
});

Deno.test("the match readout counts from where the pane is parked", () => {
  const matches = [2, 5, 9];
  assertEquals(matchOrdinal(matches, 0), 1);
  assertEquals(matchOrdinal(matches, 5), 2);
  assertEquals(matchOrdinal(matches, 9), 3);
  // Scrolled past the last match, it still reads as the last one.
  assertEquals(matchOrdinal(matches, 40), 3);
});

Deno.test("landmark jumps land on file and hunk headers, then on the ends", () => {
  const landmarks = rows
    .map((row, index) => ({ kind: row.kind, index }))
    .filter((row) => row.kind === "file" || row.kind === "hunk")
    .map((row) => row.index);
  assertEquals(nextLandmark(rows, 0, 1), landmarks[1]);
  assertEquals(nextLandmark(rows, landmarks[1], -1), landmarks[0]);
  // Off the end in either direction, so the key never feels stuck.
  assertEquals(nextLandmark(rows, rows.length - 1, 1), rows.length);
  assertEquals(nextLandmark(rows, 0, -1), 0);
});

Deno.test("highlighting marks every occurrence without changing the text", () => {
  const plain = highlighted("value and VALUE", "value", { fg: "15" });
  assertEquals(stripAnsi(plain), "value and VALUE");
  // Two runs carry the highlight background, so both occurrences are marked.
  assertEquals(plain.split(`48;5;${Color.yellow}`).length - 1, 2);
  assertEquals(stripAnsi(highlighted("untouched", "", { fg: "15" })), "untouched");
});

Deno.test("the scroll readout says top, end, or how far through", () => {
  assertEquals(scrollLabel(0, 10, 5), ""); // nothing to scroll
  assertEquals(scrollLabel(0, 10, 100), "top");
  assertEquals(scrollLabel(90, 10, 100), "end");
  assertEquals(scrollLabel(45, 10, 100), "50%");
});
