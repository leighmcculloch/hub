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
  constructor(message: string) {
    super(message);
    this.name = "NamespaceError";
  }
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
      throw new NamespaceError(failureMessage(what, String(error)));
    }
    if (result.code !== 0) throw new NamespaceError(failureMessage(what, result.stderr));
    return result.stdout;
  }

  private run(args: string[]) {
    return runCommand({ executable: "/usr/bin/env", arguments: [this.binary, ...args] });
  }
}

/**
 * One line for a failed devbox command. The CLI says what went wrong on its
 * last line; the two failures with a one-line answer — no login, no CLI — get
 * that answer appended, and everything else is reported as the CLI put it
 * rather than guessed at.
 */
export function failureMessage(what: string, stderr: string): string {
  const lines = stderr.split(/[\r\n]/).map((line) => line.trim()).filter((line) => line.length > 0);
  const reason = condense(lines[lines.length - 1] ?? "the devbox CLI failed");
  let hint = "";
  if (/no such file|not found/i.test(reason)) {
    hint = ` Install it: curl -fsSL ${INSTALL_URL} | bash`;
  } else if (/not logged in|unauthenticated|log in|login/i.test(reason)) {
    // Only when the CLI hasn't already said it, which it usually has.
    hint = reason.includes(DEVBOX_LOGIN) ? "" : ` Run \`${DEVBOX_LOGIN}\`.`;
  }
  return `Namespace couldn't ${what}: ${reason}.${hint}`;
}

/**
 * The dev boxes in `devbox list -o json`.
 *
 * The CLI's JSON shape isn't part of its documented contract, so only the two
 * things this app needs are read, and each is taken from the first plausible
 * key present: a field that moves costs a status label rather than the list.
 * Anything unparseable is an error, because an empty list and a broken response
 * mean very different things to the sidebar.
 */
export function parseDevBoxes(text: string): DevBox[] {
  const trimmed = text.trim();
  if (!trimmed) return [];
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
