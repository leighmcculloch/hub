/** One commit in a repo's log. */
export interface GitCommit {
  /** Abbreviated hash, as git prints it for `%h`. */
  sha: string;
  subject: string;
  author: string;
  /** git's own relative wording, e.g. "2 days ago". */
  relativeDate: string;
}

/**
 * The commits a repo has that its default branch doesn't — the branch's own
 * work, newest first — plus the ref that boundary was measured against.
 */
export interface GitLog {
  /** Newest first. */
  commits: GitCommit[];
  /**
   * The default-branch ref the list stops at, e.g. "origin/main". Empty when
   * the repo has no recognisable default branch, in which case the whole
   * history is listed instead.
   */
  base: string;
}

export function emptyLog(): GitLog {
  return { commits: [], base: "" };
}

/** Refs tried, in order, when `refs/remotes/origin/HEAD` isn't set. */
export const BASE_CANDIDATES = ["origin/main", "origin/master", "main", "master"];

/**
 * A branch that has run away from its default branch would otherwise send its
 * whole history over the transport on every poll.
 */
export const LOG_LIMIT = 200;

/**
 * Fields are separated by US (0x1f) rather than a printable character, so a
 * commit subject can contain anything without breaking the split. `%x1f` makes
 * git emit the byte itself, which keeps the format shell-safe.
 */
export const PRETTY_FORMAT = "%h%x1f%s%x1f%an%x1f%ar";

const FIELD_SEPARATOR = "\x1f";

/**
 * The revision range for `git log`: the branch's own commits, or the whole
 * history when no default branch could be resolved.
 */
export function logRange(base: string): string {
  return base ? `${base}..HEAD` : "HEAD";
}

/**
 * Parses lines of `PRETTY_FORMAT`. Anything with the wrong field count is
 * skipped rather than guessed at.
 */
export function parseCommits(output: string): GitCommit[] {
  const commits: GitCommit[] = [];
  for (const line of output.split("\n")) {
    if (!line) continue;
    const fields = splitLimit(line, FIELD_SEPARATOR, 4);
    if (fields.length !== 4) continue;
    commits.push({
      sha: fields[0],
      subject: fields[1],
      author: fields[2],
      relativeDate: fields[3],
    });
  }
  return commits;
}

/**
 * The left-hand side of the diff for the run of commits ending at `index` —
 * indices into `commits`, so lower means newer.
 *
 * It is the commit *before* the oldest selected one: the next older entry in
 * the list, or — when the selection reaches the end of the list — the default
 * branch itself. Naming the base ref rather than `<oldest>^` is what makes "all
 * commits" work on a branch whose oldest commit is the repo's root, which has
 * no parent to name.
 */
export function exclusiveBase(log: GitLog, index: number): string {
  if (index + 1 < log.commits.length) return log.commits[index + 1].sha;
  if (log.base) return log.base;
  return `${log.commits[index].sha}^`;
}

/**
 * `split` with a maximum field count, keeping any further separators inside the
 * last field — the behaviour git's formats rely on for free-text trailers.
 */
export function splitLimit(text: string, separator: string, limit: number): string[] {
  const parts: string[] = [];
  let rest = text;
  while (parts.length < limit - 1) {
    const index = rest.indexOf(separator);
    if (index === -1) break;
    parts.push(rest.slice(0, index));
    rest = rest.slice(index + separator.length);
  }
  parts.push(rest);
  return parts;
}
