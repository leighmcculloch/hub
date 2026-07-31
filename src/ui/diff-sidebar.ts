/**
 * The right sidebar, organised as scope → files → diff: pick *what* to read (a
 * repo's working tree or a run of its commits), narrow to one of that scope's
 * files if wanted, and read the diff below.
 *
 * The scopes come from the git repos in the VM's home directory — pick one (or
 * all), and everything is read over the session's own transport.
 */

import { Color, displayWidth, elideHead, elideMiddle, fit, styled } from "../tui/ansi.ts";
import {
  dropdown,
  type HitMap,
  placeholder,
  type Rect,
  row as listRow,
  rule,
  scrollbar,
  scrollToShow,
  wrap,
} from "../tui/widgets.ts";
import { PollBackoff } from "../model/poll-backoff.ts";
import { isWorktree, shortRepoLabel } from "../model/repo-label.ts";
import {
  allCommitsTarget,
  commitRange,
  commitsTarget,
  type DiffTarget,
  sameTarget,
  selectsAll,
  selectsCommit,
  selectsWorktree,
  targetLabel,
  worktreeTarget,
} from "../git/diff-target.ts";
import { emptyLog, type GitLog } from "../git/git-log.ts";
import { type GitLineStat, type GitRepoStatus, isBinaryStat } from "../git/git-status.ts";
import { emptyScopeFiles, type GitScopeFiles } from "../git/git-scope-files.ts";
import { type ParsedDiff, parseDiff } from "../git/diff-parse.ts";
import * as RemoteGit from "../git/remote-git.ts";
import { RemoteGitError } from "../git/remote-git.ts";
import type { TerminalSession } from "../model/terminal-session.ts";

/** One row of the scope list, flattened so hit testing and keys share an index. */
type ScopeRow =
  | { kind: "repoHeader"; repo: string; changes: number; commits: number }
  | { kind: "worktree"; repo: string }
  | { kind: "allCommits"; repo: string; log: GitLog }
  | { kind: "commit"; repo: string; log: GitLog; index: number };

/**
 * Where a diff view is scrolled and what it is showing. Held per sidebar so a
 * poll that returns the same text doesn't disturb the reading position.
 */
interface DiffView {
  text: string;
  parsed: ParsedDiff;
  offset: number;
}

export class DiffSidebar {
  /** The session this sidebar is bound to; null while nothing is selected. */
  private session: TerminalSession | null = null;
  private boundTo: string | null = null;

  repos: string[] = [];
  /** null means every repo. */
  selectedRepo: string | null = null;
  statusByRepo = new Map<string, GitRepoStatus>();
  scope: DiffTarget | null = null;
  selectedFile: string | null = null;
  commitFiles: GitScopeFiles = emptyScopeFiles();

  loadingRepos = false;
  loadingFiles = false;
  loadingDiff = false;
  /** Non-null when the VM couldn't be reached, so "no repos" isn't shown for
   * what is really a connection failure. */
  connectionError: string | null = null;

  private diff: DiffView = { text: "", parsed: parseDiff("", true), offset: 0 };
  private scopeOffset = 0;
  private filesOffset = 0;
  private scopeSelection = 0;
  private filesSelection = 0;
  /** Where a shift-click measures from: the last commit picked without one. */
  private anchor: { repo: string; index: number } | null = null;

  /** Pane heights, dragged by the split handles between them. */
  scopeHeight = 10;
  filesHeight = 8;

  private backoff = new PollBackoff();
  private refreshing = false;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private hoverRow: string | null = null;

  private scopeRows: ScopeRow[] = [];
  private fileRows: string[] = [];

  constructor(private onChange: () => void) {}

  /** Point the sidebar at a session, resetting everything if it changed. */
  bind(session: TerminalSession | null): void {
    const key = session ? `${session.id}:${session.destination ?? "local"}` : null;
    if (key === this.boundTo) return;
    this.boundTo = key;
    this.session = session;
    this.repos = [];
    this.selectedRepo = null;
    this.statusByRepo = new Map();
    this.scope = null;
    this.selectedFile = null;
    this.commitFiles = emptyScopeFiles();
    this.connectionError = null;
    this.diff = { text: "", parsed: parseDiff("", true), offset: 0 };
    this.scopeOffset = 0;
    this.filesOffset = 0;
    this.scopeSelection = 0;
    this.filesSelection = 0;
    this.backoff = new PollBackoff();
    this.restartPolling();
  }

  stop(): void {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }

  private restartPolling(): void {
    this.stop();
    if (this.session === null) return;
    void this.refresh(true);
  }

  private schedule(): void {
    this.stop();
    if (this.session === null) return;
    this.timer = setTimeout(() => void this.refresh(false), this.backoff.delay);
  }

  get visibleRepos(): string[] {
    if (this.selectedRepo !== null) {
      return this.repos.includes(this.selectedRepo) ? [this.selectedRepo] : [];
    }
    return this.repos;
  }

  logIn(repo: string): GitLog {
    return this.statusByRepo.get(repo)?.log ?? emptyLog();
  }

  /** The open scope's file list, whichever kind of scope it is. */
  get scopeFiles(): GitScopeFiles {
    if (this.scope === null) return emptyScopeFiles();
    if (this.scope.kind === "worktree") {
      const status = this.statusByRepo.get(this.scope.repo);
      return { changes: status?.changes ?? [], stats: status?.stats ?? {} };
    }
    return this.commitFiles;
  }

  // MARK: - Polling

  /**
   * Re-read repos, their changed files, and the open scope. Values are only
   * replaced when they actually differ, so unchanged polls don't disturb the
   * scroll position or the selection.
   */
  async refresh(showSpinner: boolean): Promise<void> {
    const session = this.session;
    if (session === null || this.refreshing) return;
    this.refreshing = true;
    if (showSpinner) {
      this.loadingRepos = true;
      this.onChange();
    }

    try {
      let discovered: string[];
      try {
        discovered = await RemoteGit.listRepos(session.transport);
        this.backoff.recordSuccess();
        this.connectionError = null;
      } catch (error) {
        // Keep the last known repos on screen rather than blanking the sidebar
        // on a transient blip; the banner explains the staleness.
        this.backoff.recordFailure();
        this.connectionError = error instanceof RemoteGitError ? error.message : String(error);
        this.loadingRepos = false;
        this.onChange();
        return;
      }

      if (discovered.join("\n") !== this.repos.join("\n")) this.repos = discovered;
      if (this.selectedRepo !== null && !discovered.includes(this.selectedRepo)) {
        this.selectedRepo = null;
      }

      const map = new Map<string, GitRepoStatus>();
      for (const repo of this.visibleRepos) {
        map.set(repo, await RemoteGit.repoStatus(session.transport, repo));
      }
      const changed = !sameStatuses(map, this.statusByRepo);
      if (changed) this.statusByRepo = map;

      // Default to the worktree when there's exactly one repo to mean by it.
      let needsReload = changed;
      const visible = this.visibleRepos;
      if (this.scope === null && visible.length === 1) {
        this.scope = worktreeTarget(visible[0]);
        needsReload = true;
      }
      if (this.validateScope()) needsReload = true;

      // Keep the open scope live. Re-reading is gated on the poll having
      // changed something: a commit range's contents are fixed for as long as
      // its commits are, and a moved base ref shows up as a changed log.
      if (needsReload) {
        await this.reloadScopeContent();
        this.validateSelectedFile();
      }
      this.loadingRepos = false;
      this.onChange();
    } finally {
      this.refreshing = false;
      this.schedule();
    }
  }

  /**
   * A scope can outlive what it points at: its repo disappears, or a rebase
   * drops the selected commits from the log. Fall back to that repo's worktree,
   * or to nothing. Returns whether it changed the selection.
   */
  private validateScope(): boolean {
    const scope = this.scope;
    if (scope === null) {
      if (this.selectedFile !== null) this.selectedFile = null;
      return false;
    }
    if (!this.visibleRepos.includes(scope.repo)) {
      this.scope = null;
      this.selectedFile = null;
      return true;
    }
    if (scope.kind === "commits") {
      const known = new Set(this.logIn(scope.repo).commits.map((commit) => commit.sha));
      if (!scope.shas.every((sha) => known.has(sha))) {
        this.scope = worktreeTarget(scope.repo);
        this.selectedFile = null;
        return true;
      }
    }
    return false;
  }

  /** A picked file can vanish from its scope the same way the scope can. */
  private validateSelectedFile(): void {
    if (this.selectedFile === null) return;
    if (this.scopeFiles.changes.some((change) => change.path === this.selectedFile)) return;
    this.selectedFile = null;
  }

  /** Re-read the open scope's files (commit scopes fetch theirs) and diff. */
  private async reloadScopeContent(): Promise<void> {
    const session = this.session;
    const scope = this.scope;
    if (session === null || scope === null) {
      this.setDiff("");
      return;
    }
    const range = commitRange(scope);
    if (range) {
      this.loadingFiles = true;
      this.onChange();
      const files = await RemoteGit.scopeFiles(
        session.transport,
        scope.repo,
        range.from,
        range.to,
      );
      if (sameTarget(this.scope, scope)) this.commitFiles = files;
      this.loadingFiles = false;
    }
    await this.reloadDiff();
  }

  private async reloadDiff(): Promise<void> {
    const session = this.session;
    const scope = this.scope;
    if (session === null || scope === null) {
      this.setDiff("");
      return;
    }
    const file = this.selectedFile;
    this.loadingDiff = true;
    this.onChange();
    const text = await this.diffText(scope, file);
    // A pick made while this was in flight owns the pane now.
    if (sameTarget(this.scope, scope) && this.selectedFile === file) this.setDiff(text);
    this.loadingDiff = false;
    this.onChange();
  }

  private diffText(scope: DiffTarget, file: string | null): Promise<string> {
    const transport = this.session!.transport;
    if (scope.kind === "worktree") {
      return file
        ? RemoteGit.fileDiff(transport, scope.repo, file)
        : RemoteGit.repoDiff(transport, scope.repo);
    }
    const range = commitRange(scope);
    if (!range) return Promise.resolve("");
    return file
      ? RemoteGit.rangeFileDiff(transport, scope.repo, range.from, range.to, file)
      : RemoteGit.rangeDiff(transport, scope.repo, range.from, range.to);
  }

  /** Re-parse only when the text really changes, so polls don't reset scroll. */
  private setDiff(text: string): void {
    if (text === this.diff.text) return;
    this.diff = {
      text,
      parsed: parseDiff(text, this.selectedFile === null),
      offset: 0,
    };
  }

  // MARK: - Selection

  async selectScope(target: DiffTarget): Promise<void> {
    // Re-clicking the selected scope drops a file pick, back to the scope's
    // whole diff.
    if (sameTarget(target, this.scope)) {
      if (this.selectedFile === null) return;
      this.selectedFile = null;
      await this.reloadDiff();
      return;
    }
    this.scope = target;
    this.selectedFile = null;
    this.filesOffset = 0;
    this.filesSelection = 0;
    await this.reloadScopeContent();
  }

  async selectFile(path: string): Promise<void> {
    this.selectedFile = path;
    await this.reloadDiff();
  }

  /** Narrow to one repo, or to all of them with null. */
  selectRepo(repo: string | null): void {
    if (repo === this.selectedRepo) return;
    this.selectedRepo = repo;
    this.scope = null;
    this.selectedFile = null;
    void this.refresh(true);
  }

  /** Step through the repo filter without opening its list. */
  cycleRepo(step: number): void {
    if (this.repos.length === 0) return;
    const options: Array<string | null> = [null, ...this.repos];
    const current = options.indexOf(this.selectedRepo);
    this.selectRepo(options[(current + step + options.length) % options.length]);
  }

  // MARK: - Rendering

  render(rect: Rect, hits: HitMap, focused: boolean): string[] {
    const lines: string[] = [];
    const width = rect.width;

    if (this.session === null) {
      return placeholder(
        width,
        rect.height,
        "No session selected",
        "Pick a session on the left to inspect its worktree.",
      );
    }

    // Header
    const destination = this.session.destination ?? "local shell";
    lines.push(
      fit(
        ` ${styled("Worktree Diff", { bold: true, fg: Color.fg })} ` +
          styled(this.loadingRepos ? "◌" : "", { fg: Color.dim }),
        width,
      ),
    );
    lines.push(fit(` ${styled(elideMiddle(destination, width - 2), { fg: Color.dim })}`, width));

    // The repo filter: a dropdown, so the whole list is one click away.
    const label = this.selectedRepo === null ? "All repos" : shortRepoLabel(this.selectedRepo);
    hits.add({ x: rect.x, y: rect.y + lines.length, width, height: 1 }, "diff.repo");
    lines.push(
      dropdown(`${label}  ${this.repos.length}`, width, {
        hovered: this.hoverRow === "diff.repo",
      }),
    );

    if (this.connectionError) {
      for (const line of wrap(`Can't reach ${destination}: ${this.connectionError}`, width - 2)) {
        lines.push(fit(` ${styled(line, { fg: Color.orange })}`, width));
        if (lines.length > 6) break;
      }
    }
    lines.push(rule(width));

    const remaining = rect.height - lines.length;
    if (remaining <= 3) return pad(lines, rect.height, width);

    if (this.repos.length === 0) {
      return pad(
        [
          ...lines,
          ...placeholder(
            width,
            remaining,
            this.loadingRepos ? "Looking for repos…" : "No git repos in ~",
            this.loadingRepos ? undefined : "The VM may still be cloning.",
          ),
        ],
        rect.height,
        width,
      );
    }

    // Three stacked panes, each with at least one row, the diff taking the rest.
    const scopeHeight = Math.max(2, Math.min(this.scopeHeight, remaining - 8));
    const filesHeight = Math.max(2, Math.min(this.filesHeight, remaining - scopeHeight - 5));
    const diffHeight = remaining - scopeHeight - filesHeight - 2;

    const scopeTop = rect.y + lines.length;
    lines.push(...this.renderScopes(rect, scopeTop, scopeHeight, hits, focused));
    hits.add({ x: rect.x, y: rect.y + lines.length, width, height: 1 }, "diff.splitScope");
    lines.push(this.splitHandle(width, "diff.splitScope"));

    const filesTop = rect.y + lines.length;
    lines.push(...this.renderFiles(rect, filesTop, filesHeight, hits, focused));
    hits.add({ x: rect.x, y: rect.y + lines.length, width, height: 1 }, "diff.splitFiles");
    lines.push(this.splitHandle(width, "diff.splitFiles"));

    const diffTop = rect.y + lines.length;
    lines.push(...this.renderDiff(rect, diffTop, diffHeight, hits));

    return pad(lines, rect.height, width);
  }

  /**
   * The rule between two of the stacked panes. It drags, so it says so under
   * the pointer rather than looking like a plain border.
   */
  private splitHandle(width: number, id: string): string {
    if (this.hoverRow !== id) return rule(width);
    const grip = "─".repeat(Math.max(0, Math.floor((width - 4) / 2)));
    return fit(styled(`${grip}════${grip}`, { fg: Color.accent }), width);
  }

  /**
   * The scope pane: what a diff can be read *of*. Each repo on screen offers its
   * working tree, an "all commits" row for the branch's whole work, and the
   * commits themselves — newest first, stopping at the default branch.
   */
  private renderScopes(
    rect: Rect,
    top: number,
    height: number,
    hits: HitMap,
    focused: boolean,
  ): string[] {
    const width = rect.width;
    const rows = this.buildScopeRows();
    this.scopeRows = rows;

    const caption = this.captionForScopes();
    const listHeight = height - 1;
    this.scopeOffset = scrollToShow(this.scopeOffset, this.scopeSelection, listHeight, rows.length);

    const lines = [caption(width)];
    const bar = scrollbar(this.scopeOffset, listHeight, rows.length);
    for (let index = 0; index < listHeight; index += 1) {
      const entry = rows[this.scopeOffset + index];
      if (!entry) {
        lines.push(fit("", width));
        continue;
      }
      const id = `diff.scope:${this.scopeOffset + index}`;
      const y = top + 1 + index;
      hits.add({ x: rect.x, y, width, height: 1 }, id);
      const hovered = this.hoverRow === id;
      lines.push(
        fit(
          listRow(this.scopeRowText(entry, width - 2), width - 1, {
            selected: this.isScopeSelected(entry),
            hovered,
            focused,
          }) + bar[index],
          width,
        ),
      );
    }
    return lines;
  }

  private buildScopeRows(): ScopeRow[] {
    const rows: ScopeRow[] = [];
    const showHeaders = this.selectedRepo === null && this.visibleRepos.length > 1;
    for (const repo of this.visibleRepos) {
      const status = this.statusByRepo.get(repo);
      const log = status?.log ?? emptyLog();
      if (showHeaders) {
        rows.push({
          kind: "repoHeader",
          repo,
          changes: status?.changes.length ?? 0,
          commits: log.commits.length,
        });
      }
      rows.push({ kind: "worktree", repo });
      if (log.commits.length > 0) {
        rows.push({ kind: "allCommits", repo, log });
        for (let index = 0; index < log.commits.length; index += 1) {
          rows.push({ kind: "commit", repo, log, index });
        }
      }
    }
    return rows;
  }

  private captionForScopes(): (width: number) => string {
    const total = [...this.statusByRepo.values()].reduce(
      (sum, status) => sum + status.log.commits.length,
      0,
    );
    const base = this.visibleRepos.length === 1 ? this.logIn(this.visibleRepos[0]).base : "";
    return (width: number) =>
      fit(
        ` ${styled(total === 1 ? "1 commit" : `${total} commits`, { fg: Color.dim })}` +
          (base ? ` ${styled(`ahead of ${base}`, { fg: Color.dimmer })}` : ""),
        width,
      );
  }

  private scopeRowText(entry: ScopeRow, width: number): string {
    switch (entry.kind) {
      case "repoHeader":
        return styled(
          `${elideHead(shortRepoLabel(entry.repo), Math.max(8, width - 22))} `,
          { fg: Color.dim, bold: true },
        ) +
          styled(`${entry.changes} changed · ${entry.commits} commits`, { fg: Color.dimmer });
      case "worktree": {
        const count = this.statusByRepo.get(entry.repo)?.changes.length ?? 0;
        return `${styled("✎ Working tree", { fg: Color.fg })} ` +
          styled(count === 1 ? "1 change" : `${count} changes`, { fg: Color.dimmer });
      }
      case "allCommits": {
        const count = entry.log.commits.length;
        return `${
          styled(count === 1 ? "⑂ All 1 commit" : `⑂ All ${count} commits`, {
            fg: Color.fg,
          })
        } ` + (entry.log.base ? styled(`vs ${entry.log.base}`, { fg: Color.dimmer }) : "");
      }
      case "commit": {
        const commit = entry.log.commits[entry.index];
        const date = commit.relativeDate;
        const room = Math.max(6, width - commit.sha.length - date.length - 4);
        return `${styled(commit.sha, { fg: Color.dim })} ` +
          `${styled(elideMiddle(commit.subject, room), { fg: Color.fg })} ` +
          styled(date, { fg: Color.dimmer });
      }
    }
  }

  private isScopeSelected(entry: ScopeRow): boolean {
    switch (entry.kind) {
      case "repoHeader":
        return false;
      case "worktree":
        return selectsWorktree(this.scope, entry.repo);
      case "allCommits":
        return selectsAll(this.scope, entry.repo, entry.log);
      case "commit":
        return selectsCommit(this.scope, entry.repo, entry.log.commits[entry.index].sha);
    }
  }

  /**
   * The files pane: the files of the selected scope. Picking one narrows the
   * diff below to it; the scope's whole diff shows while nothing is picked.
   */
  private renderFiles(
    rect: Rect,
    top: number,
    height: number,
    hits: HitMap,
    focused: boolean,
  ): string[] {
    const width = rect.width;
    const files = this.scopeFiles;
    this.fileRows = files.changes.map((change) => change.path);

    const label = this.scope ? targetLabel(this.scope, this.logIn(this.scope.repo)) : "";
    const lines = [
      fit(
        ` ${styled("Files", { fg: Color.dim, bold: true })} ` +
          styled(elideMiddle(label, Math.max(0, width - 9)), { fg: Color.dimmer }),
        width,
      ),
    ];

    const listHeight = height - 1;
    if (files.changes.length === 0) {
      return [
        ...lines,
        ...placeholder(
          width,
          listHeight,
          this.loadingFiles ? "Listing files…" : "No changed files",
          this.scope === null ? "Pick a scope above." : undefined,
        ),
      ];
    }

    this.filesOffset = scrollToShow(
      this.filesOffset,
      this.filesSelection,
      listHeight,
      files.changes.length,
    );
    const bar = scrollbar(this.filesOffset, listHeight, files.changes.length);
    for (let index = 0; index < listHeight; index += 1) {
      const change = files.changes[this.filesOffset + index];
      if (!change) {
        lines.push(fit("", width));
        continue;
      }
      const id = `diff.file:${this.filesOffset + index}`;
      hits.add({ x: rect.x, y: top + 1 + index, width, height: 1 }, id);
      const status = fileStatus(change.status);
      const stat = files.stats[change.path];
      const statText = stat ? statLabel(stat) : "";
      const room = Math.max(6, width - 6 - displayWidth(statText));
      const text = `${styled(status.letter, { fg: status.color, bold: true })} ` +
        `${styled(elideHead(change.path, room), { fg: Color.fg })} ${statText}`;
      lines.push(
        fit(
          listRow(text, width - 1, {
            selected: this.selectedFile === change.path,
            hovered: this.hoverRow === id,
            focused,
          }) + bar[index],
          width,
        ),
      );
    }
    return lines;
  }

  /** The diff pane: a unified diff with a line-number gutter and tinted rows. */
  private renderDiff(rect: Rect, top: number, height: number, hits: HitMap): string[] {
    const width = rect.width;
    if (height <= 1) return [];
    const parsed = this.diff.parsed;

    const title = this.selectedFile ??
      (this.scope ? targetLabel(this.scope, this.logIn(this.scope.repo)) : "");
    const stats =
      `${parsed.additions > 0 ? styled(`+${parsed.additions}`, { fg: Color.green }) : ""}` +
      `${parsed.deletions > 0 ? ` ${styled(`−${parsed.deletions}`, { fg: Color.red })}` : ""}`;
    const lines = [
      fit(
        ` ${styled(elideHead(title || "Diff", Math.max(4, width - 14)), { bold: true })} ${stats}`,
        width,
      ),
    ];

    const bodyHeight = height - 1;
    if (parsed.rows.length === 0) {
      return [
        ...lines,
        ...placeholder(
          width,
          bodyHeight,
          this.loadingDiff ? "Loading diff…" : "No line changes",
          this.scope === null ? "Pick a scope above to read its diff." : undefined,
        ),
      ];
    }

    hits.add({ x: rect.x, y: top + 1, width, height: bodyHeight }, "diff.body");
    this.diff.offset = Math.min(
      Math.max(0, this.diff.offset),
      Math.max(0, parsed.rows.length - bodyHeight),
    );
    const gutter = parsed.gutterWidth;
    for (let index = 0; index < bodyHeight; index += 1) {
      const diffRow = parsed.rows[this.diff.offset + index];
      if (!diffRow) {
        lines.push(fit("", width));
        continue;
      }
      lines.push(renderDiffRow(diffRow, width, gutter));
    }
    return lines;
  }

  // MARK: - Interaction

  setHover(id: string | null): void {
    if (this.hoverRow === id) return;
    this.hoverRow = id;
  }

  /**
   * Handle a click on a region this sidebar registered. `diff.repo` is not one
   * of them: it opens a dropdown, which only the app can draw over everything.
   */
  async click(id: string, shift: boolean): Promise<void> {
    if (id.startsWith("diff.scope:")) {
      const index = Number(id.slice("diff.scope:".length));
      this.scopeSelection = index;
      await this.activateScopeRow(index, shift);
      return;
    }
    if (id.startsWith("diff.file:")) {
      const index = Number(id.slice("diff.file:".length));
      this.filesSelection = index;
      const path = this.fileRows[index];
      if (path) await this.selectFile(path);
    }
  }

  private async activateScopeRow(index: number, shift: boolean): Promise<void> {
    const entry = this.scopeRows[index];
    if (!entry) return;
    switch (entry.kind) {
      case "repoHeader":
        return;
      case "worktree":
        await this.selectScope(worktreeTarget(entry.repo));
        return;
      case "allCommits":
        await this.selectScope(allCommitsTarget(entry.repo, entry.log));
        return;
      case "commit": {
        // Shift extends from the last commit picked without it, which is how a
        // range gets chosen.
        const extending = shift && this.anchor?.repo === entry.repo;
        if (!extending) this.anchor = { repo: entry.repo, index: entry.index };
        await this.selectScope(
          commitsTarget(entry.repo, entry.log, entry.index, extending ? this.anchor!.index : null),
        );
        return;
      }
    }
  }

  /** Scroll whichever pane the pointer is over. */
  scroll(id: string | null, delta: number): void {
    if (id?.startsWith("diff.scope:")) {
      this.scopeOffset = Math.max(0, this.scopeOffset + delta);
    } else if (id?.startsWith("diff.file:")) {
      this.filesOffset = Math.max(0, this.filesOffset + delta);
    } else if (id === "diff.body") {
      this.diff.offset = Math.max(0, this.diff.offset + delta);
    }
  }

  /** Keyboard navigation while the sidebar has focus. */
  async key(name: string, shift: boolean): Promise<boolean> {
    switch (name) {
      case "up":
        this.scopeSelection = Math.max(0, this.scopeSelection - 1);
        return true;
      case "down":
        this.scopeSelection = Math.min(this.scopeRows.length - 1, this.scopeSelection + 1);
        return true;
      case "pageup":
        this.diff.offset = Math.max(0, this.diff.offset - 10);
        return true;
      case "pagedown":
        this.diff.offset += 10;
        return true;
      case "enter":
      case "space":
        await this.activateScopeRow(this.scopeSelection, shift);
        return true;
      case "tab":
        this.cycleRepo(shift ? -1 : 1);
        return true;
      default:
        return false;
    }
  }

  /** Drag one of the split handles between the three panes. */
  dragSplit(which: "scope" | "files", delta: number): void {
    if (which === "scope") this.scopeHeight = Math.max(2, this.scopeHeight + delta);
    else this.filesHeight = Math.max(2, this.filesHeight + delta);
  }
}

// MARK: - Row rendering

function renderDiffRow(
  diffRow: { kind: string; number: number | null; text: string; detail: string | null },
  width: number,
  gutter: number,
): string {
  switch (diffRow.kind) {
    case "file":
      return fit(
        ` ${styled(elideHead(diffRow.text, width - 2), { bold: true, bg: Color.panelAlt })}`,
        width,
        { bg: Color.panelAlt },
      );
    case "hunk":
      return fit(
        ` ${styled(diffRow.text, { fg: Color.accent, bold: true })}` +
          (diffRow.detail ? ` ${styled(diffRow.detail, { fg: Color.dimmer })}` : ""),
        width,
        { bg: Color.selectionDim },
      );
    case "meta":
      return fit(` ${styled(diffRow.text, { fg: Color.dimmer })}`, width);
    default: {
      const marker = diffRow.kind === "addition" ? "+" : diffRow.kind === "deletion" ? "-" : " ";
      const background = diffRow.kind === "addition"
        ? "22"
        : diffRow.kind === "deletion"
        ? "52"
        : undefined;
      const markerColor = diffRow.kind === "addition"
        ? Color.green
        : diffRow.kind === "deletion"
        ? Color.red
        : Color.dimmer;
      const number = (diffRow.number === null ? "" : String(diffRow.number)).padStart(gutter);
      return fit(
        styled(number, { fg: Color.dimmer, bg: background }) +
          styled(marker, { fg: markerColor, bg: background }) +
          styled(diffRow.text, { fg: Color.fg, bg: background }),
        width,
        { bg: background },
      );
    }
  }
}

/**
 * A readable reading of git's two-character porcelain code, so the list can say
 * "M" in orange instead of " M". Commit-scope rows carry a single name-status
 * letter in the index slot.
 */
export function fileStatus(code: string): { letter: string; label: string; color: string } {
  const index = code[0] ?? " ";
  const worktree = code[1] ?? " ";
  if (code === "??") return { letter: "?", label: "Untracked", color: Color.green };
  if (code === "!!") return { letter: "!", label: "Ignored", color: Color.dim };
  if (index === "U" || worktree === "U" || code === "AA" || code === "DD") {
    return { letter: "!", label: "Conflicted", color: Color.red };
  }
  if (index === "R" || worktree === "R") {
    return { letter: "R", label: "Renamed", color: Color.purple };
  }
  if (index === "C" || worktree === "C") return { letter: "C", label: "Copied", color: Color.blue };
  if (index === "A" || worktree === "A") return { letter: "A", label: "Added", color: Color.green };
  if (index === "D" || worktree === "D") return { letter: "D", label: "Deleted", color: Color.red };
  if (index === "M" || worktree === "M") {
    return { letter: "M", label: "Modified", color: Color.orange };
  }
  return { letter: index === " " ? worktree : index, label: "Changed", color: Color.orange };
}

/** Compact `+N −M` for a changed file, so the list conveys size as well. */
function statLabel(stat: GitLineStat): string {
  if (isBinaryStat(stat)) return styled("bin", { fg: Color.dimmer });
  const parts: string[] = [];
  if (stat.added && stat.added > 0) parts.push(styled(`+${stat.added}`, { fg: Color.green }));
  if (stat.removed && stat.removed > 0) parts.push(styled(`−${stat.removed}`, { fg: Color.red }));
  return parts.join(" ");
}

function pad(lines: string[], height: number, width: number): string[] {
  while (lines.length < height) lines.push(fit("", width));
  return lines.slice(0, height);
}

function sameStatuses(
  left: Map<string, GitRepoStatus>,
  right: Map<string, GitRepoStatus>,
): boolean {
  if (left.size !== right.size) return false;
  for (const [key, value] of left) {
    const other = right.get(key);
    if (!other) return false;
    if (JSON.stringify(value) !== JSON.stringify(other)) return false;
  }
  return true;
}

export { isWorktree };
