/**
 * Where the app keeps its files.
 *
 * On macOS this is the same Application Support directory the SwiftUI app used,
 * so an existing install's token, environments and open sessions are picked up
 * as they are. Elsewhere it follows the XDG convention.
 */

import { join } from "@std/path";

const APP_DIRECTORY = "ExeDesktopApp";

export function configDirectory(): string {
  const override = Deno.env.get("HUB_CONFIG_DIR");
  if (override) return override;

  const home = Deno.env.get("HOME") ?? Deno.env.get("USERPROFILE") ?? ".";
  if (Deno.build.os === "darwin") {
    return join(home, "Library", "Application Support", APP_DIRECTORY);
  }
  const xdg = Deno.env.get("XDG_CONFIG_HOME");
  return join(xdg ?? join(home, ".config"), "hub");
}

export function configPath(name: string): string {
  return join(configDirectory(), name);
}

/** Read and parse a JSON file, or null when it is missing or unreadable. */
export function readJSON<T>(path: string): T | null {
  try {
    return JSON.parse(Deno.readTextFileSync(path)) as T;
  } catch {
    return null;
  }
}

/**
 * Write JSON, creating the directory if needed. Best-effort: a failed write
 * costs the setting rather than the session, and there is nowhere in a
 * full-screen TUI to report it that wouldn't be worse than the loss.
 */
export function writeJSON(path: string, value: unknown): void {
  try {
    Deno.mkdirSync(configDirectory(), { recursive: true });
    Deno.writeTextFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
  } catch {
    // Ignored deliberately; see above.
  }
}
