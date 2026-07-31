/**
 * Runs tmux's control-mode client for one VM: a process whose remote command is
 * `tmux -C`, with the protocol on its standard streams. For exe.dev that
 * process is `ssh`; for sprites.dev it's `sprite exec` — the transport is
 * supplied by the provider, this class only owns the byte plumbing.
 *
 * Events are delivered in batches, one per read, because a busy pane produces
 * thousands of tiny `%output` lines and calling back per line would spend more
 * time in the event loop than in the renderer.
 */

import { TmuxControlParser, type TmuxEvent, TmuxLineBuffer } from "./control.ts";
import type { RemoteTransport } from "../providers/types.ts";

export interface TmuxClientHandlers {
  /** Every event from one read, in order. */
  onEvents(events: TmuxEvent[]): void;
  /**
   * The process ended. `message` is the transport's or tmux's complaint, when
   * they made one — a VM that is gone, or a tmux that failed to install.
   */
  onExit(message: string | null): void;
}

export class TmuxClient {
  private process: Deno.ChildProcess | null = null;
  private writer: WritableStreamDefaultWriter<Uint8Array> | null = null;
  private parser = new TmuxControlParser();
  private lineBuffer = new TmuxLineBuffer();
  /** Everything the transport or tmux wrote to stderr, for the exit message. */
  private errorOutput = "";
  private stopped = false;
  private encoder = new TextEncoder();
  /** Commands are written in order, without a keystroke waiting on a paste. */
  private writeChain: Promise<void> = Promise.resolve();

  constructor(
    private transport: RemoteTransport,
    private remoteCommand: string,
    private handlers: TmuxClientHandlers,
  ) {}

  start(): void {
    this.stop();
    this.stopped = false;
    this.parser = new TmuxControlParser();
    this.lineBuffer = new TmuxLineBuffer();
    this.errorOutput = "";

    const spec = this.transport.interactiveSpec(this.remoteCommand);
    let process: Deno.ChildProcess;
    try {
      process = new Deno.Command(spec.executable, {
        args: spec.arguments,
        stdin: "piped",
        stdout: "piped",
        stderr: "piped",
      }).spawn();
    } catch (error) {
      this.handlers.onExit(
        `Couldn't run ${spec.executable}: ${error instanceof Error ? error.message : error}`,
      );
      return;
    }

    this.process = process;
    this.writer = process.stdin.getWriter();
    void this.pumpStdout(process);
    void this.pumpStderr(process);
    void this.waitForExit(process);
  }

  /**
   * Send one tmux command. One per call: tmux replies with a block per command,
   * and callers pair replies with commands by position.
   */
  send(command: string): void {
    const writer = this.writer;
    if (!writer || this.stopped) return;
    const bytes = this.encoder.encode(`${command}\n`);
    // Chained rather than awaited by the caller: a megabyte paste turns into
    // thousands of `send-keys`, and the UI must not block behind the pipe.
    this.writeChain = this.writeChain
      .then(() => writer.write(bytes))
      .catch(() => {
        // Writing after tmux has gone away must fail quietly; the exit handler
        // is what tells the session about it.
      });
  }

  stop(): void {
    if (this.process === null) return;
    this.stopped = true;
    const process = this.process;
    this.process = null;
    this.writer?.close().catch(() => {});
    this.writer = null;
    try {
      process.kill("SIGTERM");
    } catch {
      // Already gone.
    }
  }

  private async pumpStdout(process: Deno.ChildProcess): Promise<void> {
    try {
      for await (const chunk of process.stdout) {
        if (this.stopped) return;
        const events: TmuxEvent[] = [];
        for (const line of this.lineBuffer.lines(chunk)) {
          const event = this.parser.consume(line);
          if (event) events.push(event);
        }
        if (events.length > 0) this.handlers.onEvents(events);
      }
    } catch {
      // A closed pipe is the process ending; `waitForExit` reports it.
    }
  }

  private async pumpStderr(process: Deno.ChildProcess): Promise<void> {
    const decoder = new TextDecoder();
    try {
      for await (const chunk of process.stderr) {
        this.errorOutput += decoder.decode(chunk, { stream: true });
      }
    } catch {
      // Same as stdout.
    }
  }

  private async waitForExit(process: Deno.ChildProcess): Promise<void> {
    let code = -1;
    try {
      code = (await process.status).code;
    } catch {
      // Killed out from under us.
    }
    if (this.stopped) return; // stopped deliberately
    this.process = null;
    this.writer = null;
    const stderr = this.errorOutput.trim();
    this.handlers.onExit(stderr ? this.transport.summarize(this.errorOutput, code) : null);
  }
}
