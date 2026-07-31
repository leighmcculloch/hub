/**
 * One repo's changed files, their line counts, and its commit log, parsed from
 * a single remote command so all three cost one round trip rather than three.
 */

import { emptyLog, type GitLog, parseCommits, splitLimit } from "./git-log.ts";

/** A single changed path in the worktree. */
export interface GitFileChange {
  /** Two-character porcelain status code, e.g. " M", "??", "A ". */
  status: string;
  path: string;
}

export function isUntracked(change: GitFileChange): boolean {
  return change.status === "??";
}

/**
 * Lines added/removed for one file. `null` counts mean git reported `-`, which
 * it does for binary files.
 */
export interface GitLineStat {
  added: number | null;
  removed: number | null;
}

export function isBinaryStat(stat: GitLineStat): boolean {
  return stat.added === null && stat.removed === null;
}

export interface GitRepoStatus {
  changes: GitFileChange[];
  /** Keyed by path. Untracked files are absent — they aren't in `git diff`. */
  stats: Record<string, GitLineStat>;
  /** The commits this repo has that its default branch doesn't. */
  log: GitLog;
}

export function emptyStatus(): GitRepoStatus {
  return { changes: [], stats: {}, log: emptyLog() };
}

/** Separates the porcelain status from the numstat in the combined output. */
export const STATUS_SEPARATOR = "---exe-numstat---";

/** Separates the numstat from the log half. */
export const LOG_SEPARATOR = "---exe-log---";

/**
 * Strips git's C-style quoting from a status path. Paths with spaces or special
 * characters come back as `"a b.txt"` with escapes; `--numstat` emits them raw,
 * so both sides have to agree for the lookup to work.
 */
export function unquotePath(path: string): string {
  if (path.length < 2 || !path.startsWith('"') || !path.endsWith('"')) return path;
  let result = "";
  let escaped = false;
  for (const character of path.slice(1, -1)) {
    if (escaped) {
      if (character === "n") result += "\n";
      else if (character === "t") result += "\t";
      else result += character; // \" and \\ are literal
      escaped = false;
    } else if (character === "\\") {
      escaped = true;
    } else {
      result += character;
    }
  }
  return result;
}

/**
 * Parses `git status --porcelain=v1`, the separator, `git diff --numstat HEAD`,
 * the log separator, then the base ref and `git log`. Each half is optional.
 */
export function parseRepoStatus(output: string): GitRepoStatus {
  const sections = output.split(STATUS_SEPARATOR);
  const result = emptyStatus();

  for (const line of (sections[0] ?? "").split("\n")) {
    if (line.length <= 3) continue;
    // `status` quotes paths containing spaces or specials while `--numstat`
    // does not, so unquote here or the stat lookup misses.
    result.changes.push({ status: line.slice(0, 2), path: unquotePath(line.slice(3)) });
  }

  if (sections.length <= 1) return result;
  const tail = sections[1].split(LOG_SEPARATOR);
  for (const line of tail[0].split("\n")) {
    if (!line) continue;
    // "<added>\t<removed>\t<path>", with "-" counts for binary files.
    const fields = splitLimit(line, "\t", 3);
    if (fields.length !== 3) continue;
    result.stats[fields[2]] = { added: intOrNull(fields[0]), removed: intOrNull(fields[1]) };
  }

  if (tail.length <= 1) return result;
  result.log = parseLogSection(tail[1]);
  return result;
}

/**
 * The log half is "<base>\n<commits…>". The base line is taken positionally
 * rather than by skipping blanks, because an unresolvable default branch
 * legitimately prints an empty one.
 */
function parseLogSection(section: string): GitLog {
  const lines = section.split("\n");
  if (lines[0] === "") lines.shift(); // newline after the separator
  if (lines.length === 0) return emptyLog();
  const base = (lines.shift() ?? "").trim();
  return { commits: parseCommits(lines.join("\n")), base };
}

function intOrNull(text: string): number | null {
  if (!/^-?\d+$/.test(text)) return null;
  return Number(text);
}
