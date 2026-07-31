/**
 * The files a run of commits changed, with their line counts: the file list of
 * a commit scope in the diff sidebar. The worktree scope's equivalent already
 * exists as the `changes`/`stats` half of `GitRepoStatus`.
 */

import { splitLimit } from "./git-log.ts";
import { type GitFileChange, type GitLineStat, unquotePath } from "./git-status.ts";

export interface GitScopeFiles {
  changes: GitFileChange[];
  /**
   * Keyed by path. Files whose counts git reports as `-` (binary) get a stat
   * with null counts.
   */
  stats: Record<string, GitLineStat>;
}

export function emptyScopeFiles(): GitScopeFiles {
  return { changes: [], stats: {} };
}

/**
 * Separates the `--name-status` half from the `--numstat` half in the combined
 * output, the same trick `STATUS_SEPARATOR` plays for the worktree status.
 */
export const SCOPE_SEPARATOR = "---exe-scope-numstat---";

/**
 * The command run for a commit range: name-status, separator, numstat. Renames
 * are off so every reported path is one that exists — with detection on, a
 * rename arrives as `R100\told\tnew` and the rows stop lining up with real
 * files, the same reason the worktree status disables them.
 */
export function scopeFilesCommandFor(git: string, from: string, to: string): string {
  return `${git} diff --name-status ${from} ${to} 2>/dev/null;` +
    ` echo '${SCOPE_SEPARATOR}';` +
    ` ${git} diff --numstat ${from} ${to} 2>/dev/null`;
}

/**
 * Parses `--name-status`, the separator, then `--numstat`. Either half may be
 * empty: a range that touches no files (or an unresolvable one, where git
 * printed nothing) still yields a valid, empty result.
 */
export function parseScopeFiles(output: string): GitScopeFiles {
  const sections = output.split(SCOPE_SEPARATOR);
  const result = emptyScopeFiles();

  for (const line of (sections[0] ?? "").split("\n")) {
    if (!line) continue;
    // "<letter>\t<path>". Rename lines ("R100\told\tnew") shouldn't appear with
    // renames off; if one slips through, the score is dropped and the letter
    // read alone, so the row stays readable.
    const fields = line.split("\t");
    if (fields.length < 2 || !fields[0]) continue;
    // `status` is a two-character porcelain code; a name-status letter occupies
    // the index slot.
    result.changes.push({ status: `${fields[0][0]} `, path: unquotePath(fields[1]) });
  }

  if (sections.length <= 1) return result;
  for (const line of sections[1].split("\n")) {
    if (!line) continue;
    const fields = splitLimit(line, "\t", 3);
    if (fields.length !== 3) continue;
    result.stats[fields[2]] = { added: intOrNull(fields[0]), removed: intOrNull(fields[1]) };
  }
  return result;
}

function intOrNull(text: string): number | null {
  if (!/^-?\d+$/.test(text)) return null;
  return Number(text);
}
