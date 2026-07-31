/**
 * How long to wait before the next poll of a VM.
 *
 * The diff sidebar polls over the transport every few seconds. When a VM is
 * unreachable each attempt costs a full connect timeout, so polling at the
 * normal rate leaves a process permanently in flight against a machine that is
 * down. Failures widen the gap; the first success snaps it back.
 */
export class PollBackoff {
  /** The gap between polls while the VM is answering, in milliseconds. */
  static readonly base = 3000;
  /** The widest gap. Past this, waiting longer only delays noticing recovery. */
  static readonly maximum = 30000;

  consecutiveFailures = 0;

  /** Doubles per consecutive failure, from `base` up to `maximum`. */
  get delay(): number {
    if (this.consecutiveFailures === 0) return PollBackoff.base;
    // Bound the exponent before shifting: a VM left unreachable for hours
    // counts up far past the cap.
    const doublings = Math.min(this.consecutiveFailures - 1, 16);
    return Math.min(PollBackoff.base * 2 ** doublings, PollBackoff.maximum);
  }

  recordSuccess(): void {
    this.consecutiveFailures = 0;
  }

  recordFailure(): void {
    this.consecutiveFailures += 1;
  }
}
