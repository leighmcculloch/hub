/**
 * How a provider is named on screen.
 *
 * Both providers are listed at once whenever both have a token, so "which
 * account is this?" becomes a question the UI has to answer — in a modal that
 * has room for the domain, and in a sidebar row that doesn't.
 */

import type { VMProviderID } from "../providers/types.ts";

/** The provider's full name, where there is room for it. */
export function providerLabel(provider: VMProviderID): string {
  return provider === "exe" ? "exe.dev" : "sprites.dev";
}

/** A three-letter tag, for a row too narrow to carry the domain. */
export function providerBadge(provider: VMProviderID): string {
  return provider === "exe" ? "exe" : "spr";
}
