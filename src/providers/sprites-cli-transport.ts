/**
 * The sprites.dev transport: the `sprite` CLI, spawned as a local process the
 * same way `SSHTransport` spawns `ssh`. The CLI speaks the exec WebSocket; the
 * app only pumps bytes through the process's standard streams, so `tmux -C`
 * runs over it exactly as it does over ssh.
 *
 * Non-TTY: tmux's control protocol is a byte stream on stdout, and a remote PTY
 * would only translate it — the same reason `SSHTransport` passes no `-t`.
 *
 * Nothing here keeps the session alive across a dropped connection, because
 * nothing has to: the tmux *server* on the sprite daemonises, so losing the
 * control client leaves the session running and the next `new-session -A`
 * reattaches to it.
 */

import type { RemoteProcessSpec, RemoteTransport } from "./types.ts";

export class SpritesCLITransport implements RemoteTransport {
  /** The sprite name, used as `-s <name>` to select the sprite. */
  constructor(readonly name: string) {}

  interactiveSpec(command: string): RemoteProcessSpec {
    return {
      executable: "/usr/bin/env",
      // `sprite exec [flags] -- <command>`: an unrecognised flag makes the CLI
      // print its usage and exit, which arrives as the session's entire output.
      arguments: ["sprite", "exec", "-s", this.name, "--", "bash", "-l", "-c", command],
    };
  }

  oneshotSpec(command: string): RemoteProcessSpec {
    return {
      executable: "/usr/bin/env",
      arguments: ["sprite", "exec", "-s", this.name, "--", "bash", "-l", "-c", command],
    };
  }

  summarize(stderr: string, exit: number): string {
    // The sprite CLI's own messages; take the last non-empty line, like the ssh
    // summarizer takes the informative line.
    const lines = stderr
      .split(/[\r\n]/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    return lines[lines.length - 1] ?? `sprite exited with status ${exit}`;
  }
}
