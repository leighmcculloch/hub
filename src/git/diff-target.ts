/**
 * What the diff sidebar's scope list has selected: either the repo's whole
 * worktree, or a run of commits diffed together. A file picked in the files
 * pane below is separate view state — it always belongs to the current scope.
 *
 * This lives apart from the view so the range arithmetic behind shift-click —
 * which end of a run is which, and what a range is diffed against — can be
 * tested.
 */

import { exclusiveBase, type GitLog } from "./git-log.ts";

export type DiffTarget =
  /** Everything uncommitted in the worktree. */
  | { kind: "worktree"; repo: string }
  /**
   * A contiguous run of commits, newest first, shown as one combined diff
   * against `base` — the commit (or default-branch ref) just before the oldest.
   */
  | { kind: "commits"; repo: string; shas: string[]; base: string };

export function worktreeTarget(repo: string): DiffTarget {
  return { kind: "worktree", repo };
}

/**
 * The run of commits selected by picking `index` in `log`.
 *
 * `anchor` is the last commit picked without shift held; passing it selects
 * everything between the two, in either direction, which is how a range gets
 * chosen. Passing null selects `index` alone.
 */
export function commitsTarget(
  repo: string,
  log: GitLog,
  index: number,
  anchor: number | null = null,
): DiffTarget {
  if (index < 0 || index >= log.commits.length) {
    return { kind: "commits", repo, shas: [], base: "" };
  }
  const other = anchor !== null && anchor >= 0 && anchor < log.commits.length ? anchor : index;
  return rangeTarget(repo, log, Math.min(other, index), Math.max(other, index));
}

/** Every commit in `log` — the branch's whole work against its default branch. */
export function allCommitsTarget(repo: string, log: GitLog): DiffTarget {
  if (log.commits.length === 0) return { kind: "commits", repo, shas: [], base: "" };
  return rangeTarget(repo, log, 0, log.commits.length - 1);
}

function rangeTarget(repo: string, log: GitLog, from: number, to: number): DiffTarget {
  const shas: string[] = [];
  for (let index = from; index <= to; index += 1) shas.push(log.commits[index].sha);
  return { kind: "commits", repo, shas, base: exclusiveBase(log, to) };
}

/**
 * The newest commit in the run — the right-hand side of the range diff. Null
 * for the worktree scope, which is diffed against HEAD instead.
 */
export function newestSha(target: DiffTarget): string | null {
  return target.kind === "commits" ? (target.shas[0] ?? null) : null;
}

/** The run's endpoints for a range diff; null for the worktree scope. */
export function commitRange(target: DiffTarget): { from: string; to: string } | null {
  if (target.kind !== "commits") return null;
  const newest = newestSha(target);
  if (!newest) return null;
  return { from: target.base, to: newest };
}

export function selectsWorktree(target: DiffTarget | null, repo: string): boolean {
  return target?.kind === "worktree" && target.repo === repo;
}

export function selectsCommit(target: DiffTarget | null, repo: string, sha: string): boolean {
  return target?.kind === "commits" && target.repo === repo && target.shas.includes(sha);
}

/** True when the run covers every commit in `log` — what "all commits" shows. */
export function selectsAll(target: DiffTarget | null, repo: string, log: GitLog): boolean {
  return target?.kind === "commits" && target.repo === repo && target.shas.length > 0 &&
    target.shas.length === log.commits.length;
}

export function sameTarget(left: DiffTarget | null, right: DiffTarget | null): boolean {
  if (left === null || right === null) return left === right;
  if (left.kind !== right.kind || left.repo !== right.repo) return false;
  if (left.kind === "worktree" || right.kind !== "commits" || left.kind !== "commits") return true;
  return left.base === right.base && left.shas.join(",") === right.shas.join(",");
}

/**
 * Names the scope for the files pane's caption and the diff pane's title: the
 * subject for a single commit, the span for a run of them.
 */
export function targetLabel(target: DiffTarget, log: GitLog): string {
  if (target.kind === "worktree") return "Working tree";
  const newest = target.shas[0];
  if (!newest) return "";
  if (target.shas.length === 1) {
    const subject = log.commits.find((commit) => commit.sha === newest)?.subject ?? "";
    return subject ? `${newest}  ${subject}` : newest;
  }
  return `${target.shas.length} commits  ${target.shas[target.shas.length - 1]}…${newest}`;
}
