/**
 * A transport that runs commands on this machine, for the local shell session.
 *
 * The same shape as the remote transports, so a local shell is an ordinary
 * tmux control-mode session — tabs, splits and all — rather than a second code
 * path through the terminal pane.
 */

import type { RemoteProcessSpec, RemoteTransport } from "./types.ts";

export class LocalTransport implements RemoteTransport {
  interactiveSpec(command: string): RemoteProcessSpec {
    return { executable: shell(), arguments: ["-l", "-c", command] };
  }

  oneshotSpec(command: string): RemoteProcessSpec {
    return { executable: shell(), arguments: ["-l", "-c", command] };
  }

  summarize(stderr: string, exit: number): string {
    const lines = stderr.split(/[\r\n]/).map((line) => line.trim()).filter((line) => line);
    return lines[lines.length - 1] ?? `the shell exited with status ${exit}`;
  }
}

function shell(): string {
  return Deno.env.get("SHELL") ?? "/bin/bash";
}
