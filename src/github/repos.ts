/**
 * Lists the GitHub repositories the current user can access, for the
 * new-session repo picker.
 *
 * GitHub auth is discovered locally: `GITHUB_TOKEN`/`GH_TOKEN`, else the `gh`
 * CLI's token. If none is found the picker still allows typing `owner/repo`
 * manually.
 */

import { condense, tokenHint } from "../model/message-text.ts";
import { describe } from "../model/llm-gateway.ts";
import { runCommand } from "../providers/process.ts";
import { readRepoCache, writeRepoCache } from "./repo-cache.ts";

export interface GitHubRepo {
  fullName: string;
  isPrivate: boolean;
}

/**
 * The authenticated GitHub user, used to seed `git config` on a new VM so
 * commits are attributed correctly without the user configuring anything.
 */
export interface GitHubUser {
  login: string;
  id: number;
  name: string | null;
}

/**
 * Commit author name: the profile name when set, else the login.
 *
 * Trimmed, because this is written straight into `git config user.name` on the
 * VM — a profile name that is blank or only spaces would otherwise author every
 * commit as nothing.
 */
export function userDisplayName(user: GitHubUser): string {
  const trimmed = (user.name ?? "").trim();
  return trimmed || user.login;
}

/**
 * GitHub's private commit address for this account, which keeps the real email
 * out of commits while still linking them to the profile.
 */
export function userNoreplyEmail(user: GitHubUser): string {
  return `${user.id}+${user.login}@users.noreply.github.com`;
}

export interface RepoListing {
  repos: GitHubRepo[];
  error: string | null;
}

const USER_AGENT = "hub-tui";

export async function listGitHubRepos(): Promise<RepoListing> {
  const token = await discoverToken();
  if (!token) {
    return {
      repos: [],
      error:
        "No GitHub token found. Run `gh auth login` or set GITHUB_TOKEN to list repos — or type owner/repo below.",
    };
  }

  try {
    const collected: GitHubRepo[] = [];
    for (let page = 1; page <= 10; page += 1) {
      const url = new URL("https://api.github.com/user/repos");
      url.searchParams.set("per_page", "100");
      url.searchParams.set("page", String(page));
      url.searchParams.set("sort", "full_name");
      url.searchParams.set("affiliation", "owner,collaborator,organization_member");

      const response = await fetch(url, {
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/vnd.github+json",
          "User-Agent": USER_AGENT,
        },
      });
      if (!response.ok) {
        return {
          repos: sortRepos(collected),
          error: apiError(response.status, await response.text()),
        };
      }
      const batch = await response.json() as Array<{ full_name: string; private: boolean }>;
      for (const entry of batch) {
        collected.push({ fullName: entry.full_name, isPrivate: entry.private });
      }
      if (batch.length < 100) break;
    }
    const sorted = sortRepos(collected);
    // Persist for the next open: the picker can render immediately from the
    // cache and refresh from the network in the background.
    writeRepoCache(sorted);
    return { repos: sorted, error: null };
  } catch (error) {
    return { repos: [], error: `Failed to list repos: ${describe(error)}` };
  }
}

/**
 * Ordered the way the picker is read, not the way bytes compare.
 *
 * A plain `<` puts every capitalised name ahead of every lowercase one, so
 * `ZZZ/a` landed above `aaa/b` and the list looked arbitrary to scan. Ties are
 * broken by the exact name so the order is still total.
 */
export function sortRepos(repos: GitHubRepo[]): GitHubRepo[] {
  return [...repos].sort((left, right) => {
    const comparison = left.fullName.localeCompare(right.fullName, undefined, {
      sensitivity: "accent",
    });
    if (comparison !== 0) return comparison;
    return left.fullName < right.fullName ? -1 : left.fullName > right.fullName ? 1 : 0;
  });
}

/**
 * One readable line. GitHub answers with JSON normally but an HTML page from an
 * intermediary when things go wrong, and this lands in a banner.
 */
export function apiError(status: number, body: string): string {
  return `GitHub API error (HTTP ${status}): ${condense(body)}` +
    tokenHint(status, "GITHUB_TOKEN, or run `gh auth login`");
}

/**
 * The GitHub token the app discovered, for providers that clone from github.com
 * with it (sprites.dev). exe.dev brokers GitHub access itself.
 */
export function currentGitHubToken(): Promise<string | null> {
  return discoverToken();
}

/** The authenticated user, or null when no token is available. */
export async function currentGitHubUser(): Promise<GitHubUser | null> {
  const token = await discoverToken();
  if (!token) return null;
  try {
    const response = await fetch("https://api.github.com/user", {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "User-Agent": USER_AGENT,
      },
    });
    if (!response.ok) return null;
    const user = await response.json() as { login: string; id: number; name: string | null };
    return { login: user.login, id: user.id, name: user.name ?? null };
  } catch {
    return null;
  }
}

/** Read once per process: the token doesn't change under a running app. */
let cachedToken: string | null | undefined;

async function discoverToken(): Promise<string | null> {
  if (cachedToken !== undefined) return cachedToken;
  for (const key of ["GITHUB_TOKEN", "GH_TOKEN"]) {
    const value = Deno.env.get(key);
    if (value) {
      cachedToken = value;
      return value;
    }
  }
  cachedToken = await ghCLIToken();
  return cachedToken;
}

/** `gh auth token`, if the GitHub CLI is installed and authenticated. */
async function ghCLIToken(): Promise<string | null> {
  try {
    const result = await runCommand({
      executable: "/usr/bin/env",
      arguments: ["gh", "auth", "token"],
    });
    const token = result.stdout.trim();
    return result.code === 0 && token ? token : null;
  } catch {
    return null;
  }
}

/** Re-read the cached repo list from disk, for an immediate first paint. */
export function cachedRepos(): GitHubRepo[] | null {
  return readRepoCache();
}
