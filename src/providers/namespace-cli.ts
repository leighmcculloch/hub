/**
 * Thin wrapper around Namespace's `devbox` CLI, the way `SpritesClient` wraps
 * the sprites.dev REST API.
 *
 * Namespace has no token to paste: `devbox login` opens a browser and the
 * credential stays inside the CLI, so every call here shells out to that binary
 * rather than signing a request itself. `devbox auth check-login` is the one
 * command that answers "is this usable?" without prompting for anything.
 */

import { runCommand } from "./process.ts";
import { condense } from "../model/message-text.ts";

/** The CLI this provider drives; on `PATH` after Namespace's installer runs. */
export const DEVBOX_BINARY = "devbox";

/** What `devbox login` is called, quoted back at the user when it's needed. */
export const DEVBOX_LOGIN = "devbox login";

/** Where the CLI comes from, for the failure that means it isn't installed. */
export const INSTALL_URL = "get.namespace.so/devbox/install.sh";

export class NamespaceError extends Error {
  /**
   * Set when the CLI's complaint was about the login rather than the request.
   * The workspace watches for this: `devbox auth check-login` can say yes to a
   * credential the API then refuses, and the first real call is where that
   * shows up.
   */
  readonly credentialFailure: boolean;

  constructor(message: string, credentialFailure = false) {
    super(message);
    this.name = "NamespaceError";
    this.credentialFailure = credentialFailure;
  }
}

/**
 * Whether a CLI message is about the login rather than the request.
 *
 * Only failures of *authentication* count. Being refused something the account
 * simply isn't entitled to — `PermissionDenied`, `access denied`, a 403 — means
 * the login worked and the answer was still no, and treating that as a dead
 * credential sends the user to `devbox login` to fix a thing logging in cannot
 * fix, on top of dropping a working credential from the cache.
 */
export function isLoginFailure(reason: string): boolean {
  return /not logged in|unauthenticated|unauthorized|not authenticated|log ?in again|401/i
    .test(reason);
}

/** A dev box, reduced to what this app shows and connects to. */
export interface DevBox {
  name: string;
  /** "running", "stopped", or whatever the CLI called it; null when unstated. */
  status: string | null;
}

/**
 * How a dev box is created. Namespace prompts interactively for anything it
 * isn't told — an image, a size, a name — and a prompt would hang a spawn that
 * has no terminal, so all three are always passed.
 */
export interface CreateOptions {
  name: string;
  image: string;
  size: string;
  purpose: string;
}

export class NamespaceCLI {
  constructor(private binary = DEVBOX_BINARY) {}

  /**
   * Whether the CLI is installed and still logged in. A missing binary throws
   * from the spawn, which reads the same as a refusal here: not usable.
   */
  async loggedIn(): Promise<boolean> {
    try {
      const result = await this.run(["auth", "check-login"]);
      return result.code === 0;
    } catch {
      return false;
    }
  }

  async list(): Promise<DevBox[]> {
    const output = await this.expect(["list", "-o", "json"], "list dev boxes");
    return parseDevBoxes(output);
  }

  /**
   * Create a dev box and wait for it to be activated. `--no_checkout` because
   * the bootstrap clones the chosen repos itself, the same way it does on every
   * other provider — a workspace default checkout would land repos nobody asked
   * for.
   */
  async create(options: CreateOptions): Promise<DevBox> {
    await this.expect([
      "create",
      "--name",
      options.name,
      "--image",
      options.image,
      "--size",
      options.size,
      "--purpose",
      options.purpose,
      "--no_checkout",
      "--activate",
    ], `create dev box ${options.name}`);
    return { name: options.name, status: "running" };
  }

  /** Expire (delete) a dev box and its volume. `--force` skips the prompt. */
  async expire(name: string): Promise<void> {
    await this.expect(["expire", name, "--force"], `delete dev box ${name}`);
  }

  /** Run a devbox subcommand, failing with the CLI's own words. */
  private async expect(args: string[], what: string): Promise<string> {
    let result;
    try {
      result = await this.run(args);
    } catch (error) {
      // The spawn itself refused — rare, since a missing binary comes back as
      // a failed exit from `env` rather than a throw.
      throw failure(what, -1, String(error), "");
    }
    if (result.code !== 0) throw failure(what, result.code, result.stderr, result.stdout);
    return result.stdout;
  }

  private run(args: string[]) {
    return runCommand({ executable: "/usr/bin/env", arguments: [this.binary, ...args] });
  }
}

/** The error for a failed devbox command, marked when it is about the login. */
function failure(what: string, code: number, stderr: string, stdout: string): NamespaceError {
  const message = failureMessage(what, code, stderr, stdout);
  return new NamespaceError(message, isLoginFailure(message));
}

/**
 * One line for a failed devbox command.
 *
 * Both streams are read, because this CLI does not reliably use stderr: its
 * human renderer writes to stdout, so a failure whose whole explanation went
 * there would otherwise be reported as "the devbox CLI failed" — a sentence
 * that helps nobody. With nothing on either stream, the exit code is at least
 * something to go on.
 */
export function failureMessage(
  what: string,
  code: number,
  stderr: string,
  stdout = "",
): string {
  const reason = lastLine(stderr) ?? lastLine(stdout);
  if (reason === null) {
    return `Namespace couldn't ${what}: \`${DEVBOX_BINARY}\` exited with status ${code} ` +
      `and printed nothing.`;
  }
  let hint = "";
  if (/no image found/i.test(reason)) {
    // The image is this app's choice, not the user's, so name the command that
    // shows what the workspace actually offers.
    hint = ` Run \`${DEVBOX_BINARY} image list\` to see the images available.`;
  } else if (/no such file|not found/i.test(reason)) {
    hint = ` Install it: curl -fsSL ${INSTALL_URL} | bash`;
  } else if (isLoginFailure(reason)) {
    // Only when the CLI hasn't already said it, which it usually has.
    hint = reason.includes(DEVBOX_LOGIN) ? "" : ` Run \`${DEVBOX_LOGIN}\`.`;
  }
  return `Namespace couldn't ${what}: ${reason}.${hint}`;
}

/** The last thing a stream said, or null when it said nothing. */
function lastLine(text: string): string | null {
  const lines = text.split(/[\r\n]/).map((line) => line.trim()).filter((line) => line.length > 0);
  return lines.length === 0 ? null : condense(lines[lines.length - 1]);
}

/**
 * The dev boxes in `devbox list -o json`.
 *
 * `-o json` is not a promise of JSON: with nothing to list the CLI prints a
 * sentence to stdout instead ("No devbox available yet. Try running `devbox
 * create`."), and reading that as a broken response put an error in the sidebar
 * where an empty account was the whole story. So the exit code decides whether
 * the command failed, and the output only decides what it *contains*: anything
 * that doesn't open as JSON is a message about having none.
 *
 * The JSON shape itself isn't part of the CLI's documented contract either, so
 * only the two things this app needs are read, each from the first plausible
 * key present. JSON that can't be read as a listing is still an error — that is
 * a broken response rather than a spoken one.
 */
export function parseDevBoxes(text: string): DevBox[] {
  const trimmed = text.trim();
  if (!trimmed.startsWith("[") && !trimmed.startsWith("{")) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    throw new NamespaceError(`Unexpected \`devbox list\` output: ${condense(trimmed)}`);
  }

  const entries = Array.isArray(parsed) ? parsed : arrayField(parsed);
  if (entries === null) {
    throw new NamespaceError(`Unexpected \`devbox list\` output: ${condense(trimmed)}`);
  }

  const boxes: DevBox[] = [];
  for (const entry of entries) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as Record<string, unknown>;
    const name = firstString(record, ["name", "devbox_name", "id", "instance_id"]);
    if (name === null) continue;
    boxes.push({ name, status: statusOf(record) });
  }
  return boxes;
}

/** The first array under a key a listing might wrap its items in. */
function arrayField(value: unknown): unknown[] | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  for (const key of ["devboxes", "dev_boxes", "items", "list"]) {
    if (Array.isArray(record[key])) return record[key] as unknown[];
  }
  return null;
}

function firstString(record: Record<string, unknown>, keys: string[]): string | null {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return null;
}

/**
 * A dev box's state, normalised to the "running" the sidebar's grouping looks
 * for. Namespace has two states that matter — running and stopped — and a
 * stopped box is still openable, because `devbox ssh` resumes it.
 */
function statusOf(record: Record<string, unknown>): string | null {
  const nested = record.status;
  const direct = firstString(record, ["status", "state", "phase"]) ??
    (typeof nested === "object" && nested !== null
      ? firstString(nested as Record<string, unknown>, ["state", "phase", "name"])
      : null);
  if (direct === null) return null;
  const lowered = direct.toLowerCase();
  return lowered.includes("run") ? "running" : lowered;
}
