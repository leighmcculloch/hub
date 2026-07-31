/** How a repo path from the VM's home directory is shown in the sidebar. */

/** The path segment Claude puts its worktrees under, relative to a repo. */
export const WORKTREE_MARKER = "/.claude/worktrees/";

/**
 * A short label for `repo`.
 *
 * A Claude worktree lives at `<repo>/.claude/worktrees/<branch>`, which in a
 * narrow sidebar is mostly boilerplate and pushes the part that actually
 * identifies it off the end. Shown as `<repo> › <branch>` instead.
 */
export function shortRepoLabel(repo: string): string {
  const index = repo.indexOf(WORKTREE_MARKER);
  if (index === -1) return repo;
  const owner = repo.slice(0, index);
  const branch = repo.slice(index + WORKTREE_MARKER.length);
  // A trailing marker with nothing after it isn't a worktree path.
  if (!branch || !owner) return repo;
  return `${owner} › ${branch}`;
}

export function isWorktree(repo: string): boolean {
  return shortRepoLabel(repo) !== repo;
}
