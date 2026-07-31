/**
 * On-disk cache of the last fetched GitHub repo list, so the new-session picker
 * can show something immediately and refresh in the background instead of
 * staring at a spinner until the network answers.
 *
 * Stored separately from `config.json` — repos are a cache of account data, not
 * settings. A corrupt or partial file is treated as a miss; the next fetch
 * rewrites it.
 */

import { configPath, readJSON, writeJSON } from "../config/paths.ts";
import type { GitHubRepo } from "./repos.ts";

function cachePath(): string {
  return configPath("repos-cache.json");
}

/** The last fetched list, or null when nothing usable is cached. */
export function readRepoCache(): GitHubRepo[] | null {
  const raw = readJSON<unknown>(cachePath());
  if (!Array.isArray(raw)) return null;
  const repos: GitHubRepo[] = [];
  for (const entry of raw) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as Record<string, unknown>;
    if (typeof record.fullName !== "string") continue;
    repos.push({ fullName: record.fullName, isPrivate: record.isPrivate === true });
  }
  return repos.length > 0 ? repos : null;
}

/**
 * Records a freshly fetched list. Best-effort: a write failure just means the
 * next open shows a spinner again, so it isn't surfaced.
 */
export function writeRepoCache(repos: GitHubRepo[]): void {
  writeJSON(cachePath(), repos);
}
