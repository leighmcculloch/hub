/**
 * Running one command to completion and collecting what it said.
 *
 * The long-lived tmux connection has its own plumbing (`tmux/client.ts`); this
 * is for the one-shots — the diff sidebar's git calls, the rename poll, and
 * looking up a GitHub token from the `gh` CLI.
 */

import type { RemoteProcessSpec } from "./types.ts";

export interface CommandResult {
  code: number;
  stdout: string;
  stderr: string;
}

export async function runCommand(spec: RemoteProcessSpec): Promise<CommandResult> {
  const command = new Deno.Command(spec.executable, {
    args: spec.arguments,
    stdin: "null",
    stdout: "piped",
    stderr: "piped",
  });
  const output = await command.output();
  const decoder = new TextDecoder();
  return {
    code: output.code,
    stdout: decoder.decode(output.stdout),
    stderr: decoder.decode(output.stderr),
  };
}

/** Open `url` in the system browser, however this platform spells that. */
export async function openInBrowser(url: string): Promise<boolean> {
  const spec = browserSpec(url);
  try {
    const result = await runCommand(spec);
    return result.code === 0;
  } catch {
    return false;
  }
}

function browserSpec(url: string): RemoteProcessSpec {
  switch (Deno.build.os) {
    case "darwin":
      return { executable: "/usr/bin/open", arguments: [url] };
    case "windows":
      return { executable: "cmd", arguments: ["/c", "start", "", url] };
    default:
      return { executable: "/usr/bin/env", arguments: ["xdg-open", url] };
  }
}
