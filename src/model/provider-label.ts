/**
 * How a provider is named on screen.
 *
 * Every configured provider is listed at once, so "which account is this?"
 * becomes a question the UI has to answer — in a modal that has room for the
 * domain, and in a sidebar row that doesn't.
 */

import type { VMProviderID } from "../providers/types.ts";

/** Every provider the app knows how to talk to, in the order they're offered. */
export const ALL_PROVIDERS: VMProviderID[] = ["exe", "sprites", "namespace", "docker"];

const LABELS: Record<VMProviderID, string> = {
  exe: "exe.dev",
  sprites: "sprites.dev",
  namespace: "namespace.so",
  docker: "docker",
};

const BADGES: Record<VMProviderID, string> = {
  exe: "exe",
  sprites: "spr",
  namespace: "nsp",
  docker: "dkr",
};

/** The provider's full name, where there is room for it. */
export function providerLabel(provider: VMProviderID): string {
  return LABELS[provider] ?? provider;
}

/** A three-letter tag, for a row too narrow to carry the domain. */
export function providerBadge(provider: VMProviderID): string {
  return BADGES[provider] ?? provider.slice(0, 3);
}

/** A stored provider id, or null when it isn't one this build knows. */
export function providerIDFrom(value: unknown): VMProviderID | null {
  return typeof value === "string" && (ALL_PROVIDERS as string[]).includes(value)
    ? value as VMProviderID
    : null;
}
