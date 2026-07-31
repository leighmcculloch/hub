/**
 * The exe.dev transport: `ssh` against a direct hostname, with ControlMaster
 * multiplexing so the diff sidebar's git calls and the rename poll ride on the
 * one connection the terminal opens. A drop-in for the `sprite` CLI on
 * sprites.dev — same shape, different executable.
 */

import type { RemoteProcessSpec, RemoteTransport } from "./types.ts";

/**
 * Longest summary kept: the banner only shows a few lines, and this string is
 * re-compared on every poll, so an unbounded one isn't worth holding.
 */
const MAX_SUMMARY_LENGTH = 300;

const NOTABLE = [
  "Permission denied",
  "Could not resolve",
  "Connection refused",
  "Connection timed out",
  "Connection closed",
  "No route to host",
  "Host key verification failed",
  "Operation timed out",
];

export class SSHTransport implements RemoteTransport {
  constructor(readonly destination: string) {}

  interactiveSpec(command: string): RemoteProcessSpec {
    // No `-t`: the protocol is a byte stream on stdout, and a remote tty would
    // only translate it. (`tmux -CC`, the interactive spelling, insists on one
    // — plain `-C` is the spelling for a program driving tmux.)
    // `ConnectionAttempts` retries while the VM finishes booting.
    return {
      executable: "/usr/bin/ssh",
      arguments: [
        ...this.controlArgs,
        "-o",
        "ConnectTimeout=15",
        "-o",
        "ConnectionAttempts=10",
        "-o",
        "ServerAliveInterval=30",
        this.destination,
        command,
      ],
    };
  }

  oneshotSpec(command: string): RemoteProcessSpec {
    return {
      executable: "/usr/bin/ssh",
      arguments: [
        ...this.controlArgs,
        "-o",
        "ConnectTimeout=15",
        "-o",
        "BatchMode=yes",
        this.destination,
        command,
      ],
    };
  }

  private get controlArgs(): string[] {
    return [
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "ControlMaster=auto",
      "-o",
      `ControlPath=${SSHTransport.controlPath(this.destination)}`,
      "-o",
      "ControlPersist=120",
    ];
  }

  static controlPath(destination: string): string {
    const home = Deno.env.get("HOME") ?? ".";
    return `${home}/.ssh/cm-${destination.replaceAll("/", "_")}.sock`;
  }

  summarize(stderr: string, exit: number): string {
    return summarizeSSH(stderr, exit);
  }
}

/**
 * Condenses ssh's stderr into one line fit for a banner. ssh is chatty
 * (banners, "Warning: Permanently added…"), so the informative line is picked
 * out rather than showing the first one.
 */
export function summarizeSSH(stderr: string, exitCode: number): string {
  // Split on CR as well as LF: ssh and remote programs emit bare carriage
  // returns, which would otherwise leave line breaks inside the summary.
  const lines = stderr
    .split(/[\r\n\v\f\u0085\u2028\u2029]/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("Warning: Permanently added"))
    .map((line) =>
      line.length > MAX_SUMMARY_LENGTH ? `${line.slice(0, MAX_SUMMARY_LENGTH)}…` : line
    );

  const match = lines.find((line) =>
    NOTABLE.some((needle) => line.toLowerCase().includes(needle.toLowerCase()))
  );
  if (match) return match;
  return lines[lines.length - 1] ?? `ssh exited with status ${exitCode}`;
}
