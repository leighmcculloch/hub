/**
 * A transport that runs commands on this machine, for the local shell session.
 *
 * The same shape as the remote transports, so a local shell is an ordinary
 * tmux control-mode session — tabs, splits and all — rather than a second code
 * path through the terminal pane.
 */

import type { RemoteProcessSpec, RemoteTransport } from "./types.ts";

export class LocalTransport implements RemoteTransport {
  /**
   * `/bin/sh -c`, deliberately: not the user's `$SHELL`, and not a login shell.
   *
   * A login shell sources the user's profile, and anything that profile prints —
   * a version-manager banner, a greeting — lands on stdout in front of the
   * command's real output. For the terminal that would corrupt tmux's control
   * protocol, which *is* stdout; for the diff sidebar it turned each banner line
   * into a phantom repository. Nothing here needs the profile: the app inherits
   * the environment it was started with, and the shell the user actually types
   * into is started by tmux, with `-l`, inside the session.
   *
   * `/bin/sh` rather than `$SHELL` because these commands are POSIX shell —
   * `$(…)`, `while IFS= read`, `&&` — which fish and csh do not parse.
   */
  interactiveSpec(command: string): RemoteProcessSpec {
    return { executable: "/bin/sh", arguments: ["-c", command] };
  }

  oneshotSpec(command: string): RemoteProcessSpec {
    return { executable: "/bin/sh", arguments: ["-c", command] };
  }

  summarize(stderr: string, exit: number): string {
    const lines = stderr.split(/[\r\n]/).map((line) => line.trim()).filter((line) => line);
    return lines[lines.length - 1] ?? `the shell exited with status ${exit}`;
  }
}
