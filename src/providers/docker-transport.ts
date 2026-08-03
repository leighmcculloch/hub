/**
 * The Docker transport: `docker exec`, spawned as a local process the way
 * `SpritesCLITransport` spawns `sprite`.
 *
 * `-i` keeps stdin open, which `tmux -C` needs to send commands; no `-t`,
 * because the control protocol is a byte stream and a pty would only translate
 * it. Unlike `devbox ssh` — which joins its remote arguments and lets a shell
 * on the far end re-parse them — `docker exec` passes argv straight to the
 * container, so the command is not quoted here.
 *
 * A stopped container has to be started before anything can run in it; that is
 * the one thing this does beyond spawning, and it is why reopening a session
 * whose container was stopped works at all.
 */

import { DOCKER_BINARY } from "./docker-provider.ts";
import { shellQuote } from "../model/shell.ts";
import type { RemoteProcessSpec, RemoteTransport } from "./types.ts";

export class DockerTransport implements RemoteTransport {
  /** The container name, which `docker exec` takes as its argument. */
  constructor(readonly name: string) {}

  interactiveSpec(command: string): RemoteProcessSpec {
    return this.spec(command);
  }

  oneshotSpec(command: string): RemoteProcessSpec {
    return this.spec(command);
  }

  /**
   * `docker start` first, through a shell, so a container that was stopped
   * between sessions comes back rather than failing the exec. It is a no-op on
   * one already running.
   */
  private spec(command: string): RemoteProcessSpec {
    const start = `${DOCKER_BINARY} start ${shellQuote(this.name)} >/dev/null 2>&1;`;
    const exec = [
      DOCKER_BINARY,
      "exec",
      "-i",
      shellQuote(this.name),
      "bash",
      "-l",
      "-c",
      shellQuote(command),
    ].join(" ");
    return {
      executable: "/bin/sh",
      arguments: ["-c", `${start} exec ${exec}`],
    };
  }

  summarize(stderr: string, exit: number): string {
    const lines = stderr
      .split(/[\r\n]/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    const last = lines[lines.length - 1];
    if (!last) return `docker exited with status ${exit}`;
    return /cannot connect to the docker daemon|is the docker daemon/i.test(last)
      ? `${last} — start Docker`
      : last;
  }
}
