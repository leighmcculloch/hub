/**
 * Which session tab a keyboard shortcut selects.
 *
 * Kept apart from the workspace so the index arithmetic — the part that is easy
 * to get subtly wrong at the ends of the list — can be exercised directly.
 */

/**
 * The tab picked by Alt+1…Alt+9.
 *
 * Follows the convention every browser and terminal uses: 9 is the *last* tab
 * rather than the ninth, so it stays useful past nine sessions. A number beyond
 * the end selects nothing rather than clamping, so 4 with two tabs open leaves
 * the selection alone instead of jumping.
 */
export function indexForShortcut(number_: number, count: number): number | null {
  if (count <= 0 || number_ < 1 || number_ > 9) return null;
  if (number_ === 9) return count - 1;
  const index = number_ - 1;
  return index < count ? index : null;
}

/**
 * The tab `offset` places from `current`, wrapping around both ends so
 * next/previous never dead-ends. With nothing selected, going forward starts at
 * the first tab and going back starts at the last.
 */
export function indexFrom(current: number | null, offset: number, count: number): number | null {
  if (count <= 0) return null;
  if (current === null) return offset >= 0 ? 0 : count - 1;
  const next = (current + offset) % count;
  return next < 0 ? next + count : next;
}
