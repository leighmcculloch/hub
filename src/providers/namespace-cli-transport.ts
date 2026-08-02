/**
 * The Namespace transport: `devbox ssh`, spawned as a local process the same
 * way `SSHTransport` spawns `ssh` and `SpritesCLITransport` spawns `sprite`.
 * The CLI brokers the connection; the app only pumps bytes through the
 * process's standard streams, so `tmux -C` runs over it unchanged.
 *
 * `-T` because tmux's control protocol is a byte stream on stdout and a remote
 * PTY would only translate it — the same reason `SSHTransport` passes no `-t`.
 *
 * `devbox ssh` also resumes a stopped dev box, so reopening one that idled out
 * needs nothing else: connecting is what starts it.
 */

import { DEVBOX_BINARY, DEVBOX_LOGIN } from "./namespace-cli.ts";
import type { RemoteProcessSpec, RemoteTransport } from "./types.ts";

export class NamespaceCLITransport implements RemoteTransport {
  /** The dev box name, which `devbox ssh` takes as its argument. */
  constructor(readonly name: string) {}

  interactiveSpec(command: string): RemoteProcessSpec {
    return this.spec(command);
  }

  oneshotSpec(command: string): RemoteProcessSpec {
    return this.spec(command);
  }

  private spec(command: string): RemoteProcessSpec {
    return {
      executable: "/usr/bin/env",
      arguments: [DEVBOX_BINARY, "ssh", "-T", this.name, "--", "bash", "-l", "-c", command],
    };
  }

  summarize(stderr: string, exit: number): string {
    // The CLI's own messages; take the last non-empty line, like the ssh
    // summarizer takes the informative line.
    const lines = stderr
      .split(/[\r\n]/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    const last = lines[lines.length - 1];
    if (!last) return `devbox exited with status ${exit}`;
    return /not logged in|unauthenticated/i.test(last) ? `${last} — run \`${DEVBOX_LOGIN}\`` : last;
  }
}
