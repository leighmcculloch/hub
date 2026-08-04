/**
 * pi's GitHub Copilot credential, carried from this machine onto the session's.
 *
 * Copilot is not reachable with the GitHub token the session already gets: that
 * one is the `gh` CLI's, scoped for git and the API, and Copilot's endpoints
 * want a credential from a Copilot-entitled OAuth client. pi obtains one with
 * its own device-code login and stores it in `~/.pi/agent/auth.json` — so the
 * credential to copy is the one pi already wrote, in the format pi already
 * reads. Nothing here invents or exchanges a token.
 *
 * Only the Copilot entry is taken. That file is pi's whole credential store,
 * and an Anthropic key or an OpenAI key sitting beside the Copilot one has no
 * business being copied to a machine an agent runs on.
 */

import { join } from "@std/path";

/** Where pi keeps its credentials, relative to `$HOME`, here and on the VM. */
export const PI_AUTH_PATH = ".pi/agent/auth.json";

/** The provider whose credential is worth carrying. */
export const COPILOT_PROVIDER = "github-copilot";

/**
 * The Copilot entry from this machine's pi credentials, as the JSON to write on
 * the session's machine — or null when pi has never logged into Copilot here,
 * which is not an error: it is a session that will ask you to `/login` itself.
 */
export async function localCopilotAuth(): Promise<string | null> {
  const home = Deno.env.get("HOME");
  if (!home) return null;
  let text: string;
  try {
    text = await Deno.readTextFile(join(home, PI_AUTH_PATH));
  } catch {
    return null;
  }
  return copilotEntry(text);
}

/**
 * The Copilot entry alone, out of pi's credential store.
 *
 * Read leniently: the file is pi's, its shape is pi's business, and the one
 * thing this needs to know is whether there is something filed under the
 * Copilot provider. Anything else — a missing key, a file that isn't an object,
 * text that isn't JSON — means there is nothing to carry.
 */
export function copilotEntry(text: string): string | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  const entry = (parsed as Record<string, unknown>)[COPILOT_PROVIDER];
  if (entry === undefined || entry === null) return null;
  return JSON.stringify({ [COPILOT_PROVIDER]: entry }, null, 2);
}
