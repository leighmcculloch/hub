/**
 * Turning a server response body into something that fits in a one-line banner.
 *
 * Both API clients need this: bodies arrive as multi-line JSON or, when an
 * intermediary fails, a whole HTML error page.
 */

export const DEFAULT_LIMIT = 200;

/** One line, trimmed, and no longer than `limit`. */
export function condense(text: string, limit: number = DEFAULT_LIMIT): string {
  const collapsed = text.split(/\s+/).filter((word) => word.length > 0).join(" ");
  if (!collapsed) return "(empty response)";
  return collapsed.length > limit ? `${collapsed.slice(0, limit)}…` : collapsed;
}

/**
 * Names the one thing a user can do about an auth failure. A bad token
 * otherwise surfaces as a bare API string with no hint where to fix it.
 */
export function tokenHint(status: number, setting: string): string {
  return status === 401 || status === 403 ? ` — check ${setting}.` : "";
}
