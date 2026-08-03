/**
 * Cloning the chosen repos, the same way on every provider: a GitHub token
 * taken from this machine, put in the VM's environment, and used against
 * github.com.
 *
 * exe.dev used to broker this itself, through per-repo integrations bound by a
 * tag and a `github.int.exe.xyz` proxy. That worked, but it made exe.dev the
 * one provider whose setup nothing else shared — and a provider starting from a
 * bare image has no brokerage to offer. One credential, one URL, one code path.
 */

import { CLONE_FAILURE_HINT, tokenCloneConfig } from "../model/bootstrap.ts";
import { currentGitHubToken } from "../github/repos.ts";
import type { GitHubSetup } from "./types.ts";

/** The variable the VM clones with, read by the clone's auth header. */
export const TOKEN_VARIABLE = "GITHUB_TOKEN";

/**
 * What cloning `repos` takes. No token found means public repos only, which is
 * a working session rather than a failed one, so it isn't an error here.
 */
export async function tokenGitHubSetup(repos: string[]): Promise<GitHubSetup> {
  if (repos.length === 0) {
    return { tags: [], cloneEnvironment: [], clone: tokenCloneConfig(null, CLONE_FAILURE_HINT) };
  }
  const token = await currentGitHubToken();
  return {
    tags: [],
    cloneEnvironment: token ? [{ key: TOKEN_VARIABLE, value: token }] : [],
    clone: tokenCloneConfig(token, CLONE_FAILURE_HINT),
  };
}
