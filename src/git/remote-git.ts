/**
 * Runs `git` over the session's transport against a VM, so the diff sidebar can
 * inspect the repos cloned into the VM's home directory.
 *
 * All calls reuse a single multiplexed connection when the transport is SSH
 * (ControlMaster); other transports open a fresh command each call. The
 * terminal session and these one-shots share the transport, so the work rides
 * on whatever connection the terminal already holds.
 */

import { shellQuote } from "../model/shell.ts";
import { runCommand } from "../providers/process.ts";
import { BASE_CANDIDATES, LOG_LIMIT, PRETTY_FORMAT } from "./git-log.ts";
import {
  emptyStatus,
  type GitRepoStatus,
  LOG_SEPARATOR,
  parseRepoStatus,
  STATUS_SEPARATOR,
} from "./git-status.ts";
import {
  emptyScopeFiles,
  type GitScopeFiles,
  parseScopeFiles,
  scopeFilesCommandFor,
} from "./git-scope-files.ts";
import type { RemoteTransport } from "../providers/types.ts";

export class RemoteGitError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RemoteGitError";
  }
}

/** Home-relative directories under `$HOME` (depth ≤ 2) that are git repos. */
export async function listRepos(transport: RemoteTransport): Promise<string[]> {
  // Two passes: repos checked out directly in the home dir, plus every worktree
  // under a repo's `.claude/worktrees`. The second is targeted rather than a
  // deeper `-maxdepth`, which would also drag in incidental repos under things
  // like node_modules. `.git` is matched without a type filter because in a
  // worktree it is a file, not a directory.
  const command = `cd "$HOME" && {` +
    ` find . -maxdepth 2 -name .git 2>/dev/null;` +
    ` find . -maxdepth 5 -path './*/.claude/worktrees/*/.git' 2>/dev/null;` +
    ` } | sed 's|/\\.git$||;s|^\\./||' | grep -v '^\\.$' | sort -u`;
  const out = await runOrThrow(transport, command);
  return out.split("\n").filter((line) => line.length > 0);
}

/**
 * Changed files, their line counts, and the repo's log, in one round trip: the
 * three are concatenated with separators rather than run as separate commands,
 * so neither the counts nor the log multiplied the per-poll cost.
 */
export async function repoStatus(
  transport: RemoteTransport,
  repo: string,
): Promise<GitRepoStatus> {
  const out = await run(transport, statusCommand(repo));
  return out === null ? emptyStatus() : parseRepoStatus(out);
}

/**
 * `--untracked-files=all` because the default collapses a whole new directory
 * into a single `?? dir/` entry — one unopenable row standing in for every file
 * in it.
 *
 * Rename detection is turned off on both halves. With it on, a rename is
 * reported as `R old.txt -> new.txt`, and everything downstream treats that
 * whole string as a filename: the row is unreadable and its diff is empty. The
 * two halves don't even agree on the spelling, so line counts never attach
 * either. Off, git reports the plain delete and add, and every path is one that
 * exists.
 *
 * Set as config rather than `--no-renames` so a git too old to know the option
 * ignores it instead of failing the whole command.
 */
export function statusCommand(repo: string): string {
  const git = `git -C "$HOME"/${shellQuote(repo)}` +
    ` -c core.quotePath=false -c status.renames=false -c diff.renames=false`;
  return `${git} status --porcelain=v1 --untracked-files=all 2>/dev/null;` +
    ` echo '${STATUS_SEPARATOR}';` +
    ` ${git} diff --numstat HEAD 2>/dev/null;` +
    ` echo '${LOG_SEPARATOR}';` +
    ` ${logCommand(git)};` +
    // `run` discards a non-zero exit, and the halves above legitimately fail on
    // a repo with no commits yet — where `status` still has untracked files to
    // report. Without this the whole list blanks.
    ` exit 0`;
}

/**
 * Resolves the repo's default branch, prints it, then lists the commits HEAD
 * has beyond it.
 *
 * The base is printed even though the caller could guess, because the log alone
 * doesn't say what it stopped at — and when nothing resolves, the blank line is
 * what tells the sidebar it is showing plain history rather than a branch's own
 * work.
 */
function logCommand(git: string): string {
  return `base=;` +
    ` for ref in $(${git} symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)` +
    ` ${BASE_CANDIDATES.join(" ")}; do` +
    ` ${git} rev-parse --verify -q "$ref" >/dev/null 2>&1 && base=$ref && break;` +
    ` done;` +
    ` echo "$base";` +
    ` ${git} log -n ${LOG_LIMIT} --pretty=format:'${PRETTY_FORMAT}'` +
    ` "\${base:+$base..}HEAD" 2>/dev/null`;
}

/**
 * The combined diff of a run of commits: everything between `from` (exclusive)
 * and `to` (inclusive).
 */
export async function rangeDiff(
  transport: RemoteTransport,
  repo: string,
  from: string,
  to: string,
): Promise<string> {
  return (await run(transport, rangeDiffCommand(repo, from, to))) ?? "";
}

/**
 * Both revisions come from git's own output, but they are quoted anyway: the
 * base can be a ref name from the repo, and a branch may be named anything a
 * filesystem accepts.
 */
export function rangeDiffCommand(repo: string, from: string, to: string): string {
  return `git -C "$HOME"/${shellQuote(repo)} diff` +
    ` ${shellQuote(from)} ${shellQuote(to)} 2>/dev/null`;
}

/**
 * The files changed between `from` (exclusive) and `to`, with line counts — the
 * file list for a commit scope, in one round trip.
 */
export async function scopeFiles(
  transport: RemoteTransport,
  repo: string,
  from: string,
  to: string,
): Promise<GitScopeFiles> {
  const out = await run(transport, scopeFilesCommand(repo, from, to));
  return out === null ? emptyScopeFiles() : parseScopeFiles(out);
}

/**
 * The trailing `exit 0` serves the same purpose as in `statusCommand`: an
 * unresolvable range fails the diffs, and a non-zero exit would make `run`
 * discard whatever did print.
 */
export function scopeFilesCommand(repo: string, from: string, to: string): string {
  const git = `git -C "$HOME"/${shellQuote(repo)} -c diff.renames=false`;
  return `${scopeFilesCommandFor(git, shellQuote(from), shellQuote(to))}; exit 0`;
}

/** The diff of one file within a commit range. */
export async function rangeFileDiff(
  transport: RemoteTransport,
  repo: string,
  from: string,
  to: string,
  file: string,
): Promise<string> {
  return (await run(transport, rangeFileDiffCommand(repo, from, to, file))) ?? "";
}

export function rangeFileDiffCommand(
  repo: string,
  from: string,
  to: string,
  file: string,
): string {
  return `git -C "$HOME"/${shellQuote(repo)} diff` +
    ` ${shellQuote(from)} ${shellQuote(to)}` +
    ` -- ${shellQuote(file)} 2>/dev/null`;
}

/** Unified diff for a single file within a repo. */
export async function fileDiff(
  transport: RemoteTransport,
  repo: string,
  file: string,
): Promise<string> {
  return (await run(transport, fileDiffCommand(repo, file))) ?? "";
}

/**
 * An untracked file has no blob in HEAD, so `git diff HEAD` says nothing about
 * it — the sidebar listed the file and then showed an empty pane. `--no-index`
 * renders it as an addition against `/dev/null` instead.
 *
 * The choice between the two has to be "is this file untracked", which is what
 * `ls-files --others` answers. Asking whether it is *in the index* instead gets
 * deletions wrong: `git rm` takes the file out of the index, so a staged
 * deletion would be sent down the untracked path and diffed against a file that
 * is no longer on disk, producing nothing.
 *
 * The trailing `exit 0` is load-bearing: `--no-index` exits 1 whenever the
 * inputs differ, which is every time it produces output.
 */
export function fileDiffCommand(repo: string, file: string): string {
  const path = shellQuote(file);
  return `cd "$HOME" && cd ${shellQuote(repo)} 2>/dev/null || exit 0;` +
    ` if [ -n "$(git ls-files --others --exclude-standard -- ${path} 2>/dev/null)" ];` +
    ` then git diff --no-index -- /dev/null ${path} 2>/dev/null;` +
    ` else git diff HEAD -- ${path} 2>/dev/null; fi;` +
    ` exit 0`;
}

/**
 * Full worktree diff for a repo (vs. HEAD), untracked files included.
 *
 * `git diff HEAD` says nothing about untracked files — the sidebar lists them
 * from the status, so a whole-worktree diff missing them would be wrong. Each
 * is appended as an addition against `/dev/null`.
 */
export async function repoDiff(transport: RemoteTransport, repo: string): Promise<string> {
  return (await run(transport, repoDiffCommand(repo))) ?? "";
}

/**
 * The untracked loop reads newline-separated paths, which only a filename
 * containing a newline can break — the trade `read -d ''` makes is requiring
 * bash, and the remote shell isn't guaranteed to be one.
 */
export function repoDiffCommand(repo: string): string {
  const quoted = shellQuote(repo);
  return `cd "$HOME" && cd ${quoted} 2>/dev/null || exit 0;` +
    ` git -c core.quotePath=false -c diff.renames=false diff HEAD 2>/dev/null;` +
    ` git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null` +
    ` | while IFS= read -r f; do git diff --no-index -- /dev/null "$f" 2>/dev/null; done;` +
    ` exit 0`;
}

/**
 * Run one remote command, returning stdout on success (exit 0), else null.
 *
 * Not private because this is the app's one way of running something on a VM
 * over the terminal's connection; the rename poll asks the VM its name with it.
 */
export async function run(
  transport: RemoteTransport,
  remoteCommand: string,
): Promise<string | null> {
  try {
    return await runOrThrow(transport, remoteCommand);
  } catch {
    return null;
  }
}

/**
 * Same, but surfacing *why* it failed. The distinction matters: an unreachable
 * VM and an empty home directory both produce no output, and showing "no repos"
 * for a connection failure is actively misleading.
 */
export async function runOrThrow(
  transport: RemoteTransport,
  remoteCommand: string,
): Promise<string> {
  const spec = transport.oneshotSpec(remoteCommand);
  let result;
  try {
    result = await runCommand(spec);
  } catch (error) {
    throw new RemoteGitError(
      `Couldn't run ${spec.executable}: ${error instanceof Error ? error.message : error}`,
    );
  }
  if (result.code === 0) return result.stdout;
  throw new RemoteGitError(transport.summarize(result.stderr, result.code));
}
