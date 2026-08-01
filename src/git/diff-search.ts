/**
 * Finding your way around a diff: which rows match a search, and where the next
 * match or the next file/hunk header is.
 *
 * Kept out of the sidebar because it is all arithmetic over the parsed rows —
 * the part most worth testing, and the part with nothing to do with drawing.
 */

import type { DiffRow } from "./diff-parse.ts";

/** The rows containing `query`, case-insensitively. Empty for an empty query. */
export function matchingRows(rows: DiffRow[], query: string): number[] {
  const needle = query.toLowerCase();
  if (!needle) return [];
  const found: number[] = [];
  for (let index = 0; index < rows.length; index += 1) {
    if (rows[index].text.toLowerCase().includes(needle)) found.push(index);
  }
  return found;
}

/**
 * The match after (or before) `from`, wrapping around the ends. A search you
 * have to restart at the top is a search you stop using.
 */
export function nextMatch(matches: number[], from: number, step: number): number | null {
  if (matches.length === 0) return null;
  if (step > 0) return matches.find((row) => row > from) ?? matches[0];
  for (let index = matches.length - 1; index >= 0; index -= 1) {
    if (matches[index] < from) return matches[index];
  }
  return matches[matches.length - 1];
}

/** Which match a body scrolled to `offset` is parked on, 1-based, for "3/12". */
export function matchOrdinal(matches: number[], offset: number): number {
  const at = matches.findIndex((row) => row >= offset);
  return at === -1 ? matches.length : at + 1;
}

/**
 * The next file or hunk header in the given direction. Running out lands on the
 * far end rather than doing nothing, so the key always moves.
 */
export function nextLandmark(rows: DiffRow[], from: number, step: number): number {
  for (let index = from + step; index >= 0 && index < rows.length; index += step) {
    if (rows[index].kind === "hunk" || rows[index].kind === "file") return index;
  }
  return step > 0 ? rows.length : 0;
}
