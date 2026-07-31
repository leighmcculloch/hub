/**
 * Thin client for the exe.dev HTTPS API.
 *
 * The entire API is "run a CLI command": POST the command string to
 * `https://exe.dev/exec` with a bearer token; the response body is the command
 * output (always JSON, equivalent to passing `--json`). Errors come back as
 * `{"error":"..."}`.
 */

import { condense, tokenHint } from "../model/message-text.ts";

export class ExeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ExeError";
  }
}

const ENDPOINT = "https://exe.dev/exec";

export class ExeClient {
  constructor(private tokenProvider: () => string) {}

  /** Run a command and return the raw response body. */
  async run(command: string): Promise<string> {
    const token = this.tokenProvider();
    if (!token) {
      throw new ExeError(
        "No exe.dev API token configured. Add one in Settings (Alt+,) or set EXE_DEV_TOKEN.",
      );
    }

    const response = await fetch(ENDPOINT, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "text/plain" },
      body: command,
    });
    const body = await response.text();
    const failure = exeFailure(response.status, body);
    if (failure) throw failure;
    return body;
  }

  /** Run a command and decode its JSON output. */
  async runJSON<T>(command: string): Promise<T> {
    const body = await this.run(command);
    try {
      return JSON.parse(body) as T;
    } catch {
      throw new ExeError(`Unexpected exe.dev response for \`${command}\`: ${condense(body)}`);
    }
  }
}

/**
 * The error a response represents, or null if it succeeded.
 *
 * Separate from the request so the message-building — the part a user actually
 * reads when something breaks — can be exercised directly.
 */
export function exeFailure(status: number, body: string): ExeError | null {
  // Error responses are `{"error":"..."}` regardless of status code, so this is
  // checked before the status.
  try {
    const parsed = JSON.parse(body) as unknown;
    if (typeof parsed === "object" && parsed !== null) {
      const error = (parsed as Record<string, unknown>).error;
      if (typeof error === "string") {
        return new ExeError(`exe.dev (HTTP ${status}): ${condense(error)}${hint(status)}`);
      }
    }
  } catch {
    // Not JSON; fall through to the status check.
  }
  if (status >= 200 && status < 300) return null;
  return new ExeError(`exe.dev HTTP ${status}: ${condense(body)}${hint(status)}`);
}

function hint(status: number): string {
  return tokenHint(status, "your API token in Settings (Alt+,) or EXE_DEV_TOKEN");
}
