import { assertEquals } from "@std/assert";
import {
  LOG_SEPARATOR,
  parseRepoStatus,
  STATUS_SEPARATOR,
  unquotePath,
} from "../src/git/git-status.ts";
import { parseScopeFiles, SCOPE_SEPARATOR } from "../src/git/git-scope-files.ts";
import { exclusiveBase, type GitLog, parseCommits } from "../src/git/git-log.ts";
import { parseDiff } from "../src/git/diff-parse.ts";
import {
  allCommitsTarget,
  commitRange,
  commitsTarget,
  newestSha,
  selectsAll,
  selectsCommit,
  targetLabel,
  worktreeTarget,
} from "../src/git/diff-target.ts";
import { fileDiffCommand, repoDiffCommand, statusCommand } from "../src/git/remote-git.ts";

const US = "\x1f";

function log(shas: string[], base = "origin/main"): GitLog {
  return {
    base,
    commits: shas.map((sha) => ({
      sha,
      subject: `subject ${sha}`,
      author: "Ada",
      relativeDate: "1 day ago",
    })),
  };
}

Deno.test("unquotePath undoes git's C-style quoting", () => {
  assertEquals(unquotePath(`"a b.txt"`), "a b.txt");
  assertEquals(unquotePath(`"tab\\there"`), "tab\there");
  assertEquals(unquotePath(`"say \\"hi\\""`), `say "hi"`);
  assertEquals(unquotePath("plain.txt"), "plain.txt");
});

Deno.test("parseRepoStatus reads status, numstat and log from one payload", () => {
  const output = [
    " M src/a.swift",
    "?? new.txt",
    STATUS_SEPARATOR,
    "3\t1\tsrc/a.swift",
    "-\t-\timage.png",
    LOG_SEPARATOR,
    "origin/main",
    ["abc1234", "fix login", "Ada", "2 days ago"].join(US),
  ].join("\n");

  const status = parseRepoStatus(output);
  assertEquals(status.changes, [
    { status: " M", path: "src/a.swift" },
    { status: "??", path: "new.txt" },
  ]);
  assertEquals(status.stats["src/a.swift"], { added: 3, removed: 1 });
  assertEquals(status.stats["image.png"], { added: null, removed: null });
  assertEquals(status.log.base, "origin/main");
  assertEquals(status.log.commits.length, 1);
  assertEquals(status.log.commits[0].subject, "fix login");
});

Deno.test("parseRepoStatus tolerates each half being absent", () => {
  assertEquals(parseRepoStatus("").changes, []);
  const statusOnly = parseRepoStatus(` M a.txt\n${STATUS_SEPARATOR}`);
  assertEquals(statusOnly.changes.length, 1);
  assertEquals(statusOnly.log.commits, []);
});

Deno.test("parseRepoStatus unquotes so the numstat lookup matches", () => {
  const output = [
    ` M "a b.txt"`,
    STATUS_SEPARATOR,
    "1\t0\ta b.txt",
  ].join("\n");
  const status = parseRepoStatus(output);
  assertEquals(status.changes[0].path, "a b.txt");
  assertEquals(status.stats[status.changes[0].path], { added: 1, removed: 0 });
});

Deno.test("an empty base line means plain history, not a missing section", () => {
  const output = [
    STATUS_SEPARATOR,
    LOG_SEPARATOR,
    "",
    ["abc", "s", "a", "now"].join(US),
  ].join("\n");
  const status = parseRepoStatus(output);
  assertEquals(status.log.base, "");
  assertEquals(status.log.commits.length, 1);
});

Deno.test("parseCommits skips rows with the wrong field count", () => {
  const output = [
    ["abc", "subject", "Ada", "now"].join(US),
    "malformed",
    ["def", "with" + US + "separator", "Ada", "now"].join(US),
  ].join("\n");
  const commits = parseCommits(output);
  assertEquals(commits.length, 2);
  // Only the first three separators are structural; the rest stay in the tail.
  assertEquals(commits[1].sha, "def");
});

Deno.test("parseScopeFiles reads name-status and numstat", () => {
  const output = ["M\tsrc/a.ts", "A\tsrc/b.ts", SCOPE_SEPARATOR, "2\t0\tsrc/a.ts"].join("\n");
  const files = parseScopeFiles(output);
  assertEquals(files.changes, [
    { status: "M ", path: "src/a.ts" },
    { status: "A ", path: "src/b.ts" },
  ]);
  assertEquals(files.stats["src/a.ts"], { added: 2, removed: 0 });
});

Deno.test("exclusiveBase walks to the next older commit, then the base ref", () => {
  const history = log(["c3", "c2", "c1"]);
  assertEquals(exclusiveBase(history, 0), "c2");
  assertEquals(exclusiveBase(history, 2), "origin/main");
  assertEquals(exclusiveBase({ ...history, base: "" }, 2), "c1^");
});

Deno.test("commitsTarget selects one commit, or a run when extending", () => {
  const history = log(["c3", "c2", "c1"]);
  const single = commitsTarget("repo", history, 1);
  assertEquals(newestSha(single), "c2");
  assertEquals(commitRange(single), { from: "c1", to: "c2" });

  const run = commitsTarget("repo", history, 2, 0);
  assertEquals(commitRange(run), { from: "origin/main", to: "c3" });
});

Deno.test("commitsTarget extends in either direction", () => {
  const history = log(["c3", "c2", "c1"]);
  assertEquals(commitRange(commitsTarget("repo", history, 0, 2)), {
    from: "origin/main",
    to: "c3",
  });
});

Deno.test("an out-of-range pick selects nothing rather than throwing", () => {
  const target = commitsTarget("repo", log(["c1"]), 9);
  assertEquals(newestSha(target), null);
  assertEquals(commitRange(target), null);
});

Deno.test("allCommitsTarget covers the branch and is recognised as such", () => {
  const history = log(["c3", "c2", "c1"]);
  const all = allCommitsTarget("repo", history);
  assertEquals(selectsAll(all, "repo", history), true);
  assertEquals(selectsCommit(all, "repo", "c2"), true);
  assertEquals(selectsAll(commitsTarget("repo", history, 0), "repo", history), false);
});

Deno.test("targetLabel names the worktree, a commit, and a run", () => {
  const history = log(["c3", "c2"]);
  assertEquals(targetLabel(worktreeTarget("repo"), history), "Working tree");
  assertEquals(targetLabel(commitsTarget("repo", history, 0), history), "c3  subject c3");
  assertEquals(
    targetLabel(commitsTarget("repo", history, 1, 0), history),
    "2 commits  c2…c3",
  );
});

Deno.test("parseDiff counts additions and deletions and numbers the lines", () => {
  const diff = [
    "diff --git a/a.ts b/a.ts",
    "index 111..222 100644",
    "--- a/a.ts",
    "+++ b/a.ts",
    "@@ -1,3 +1,4 @@ function go()",
    " keep",
    "-gone",
    "+added",
    "+also",
    "",
  ].join("\n");
  const parsed = parseDiff(diff, true);
  assertEquals(parsed.additions, 2);
  assertEquals(parsed.deletions, 1);
  assertEquals(parsed.rows[0].kind, "file");
  assertEquals(parsed.rows[0].text, "a.ts");
  assertEquals(parsed.rows[1].kind, "hunk");
  assertEquals(parsed.rows[1].detail, "function go()");
  assertEquals(parsed.rows[2], { kind: "context", number: 1, text: "keep", detail: null });
  // Deletions are numbered on the old side, additions on the new one.
  assertEquals(parsed.rows[3], { kind: "deletion", number: 2, text: "gone", detail: null });
  assertEquals(parsed.rows[4], { kind: "addition", number: 2, text: "added", detail: null });
  assertEquals(parsed.rows[5].number, 3);
});

Deno.test("a deleted line beginning with -- is content, not a file header", () => {
  const diff = ["@@ -1,1 +1,0 @@", "--- a SQL comment"].join("\n");
  const parsed = parseDiff(diff, true);
  assertEquals(parsed.deletions, 1);
  assertEquals(parsed.rows[1].text, "-- a SQL comment");
});

Deno.test("parseDiff drops the file header when the pane already names the file", () => {
  const diff = ["diff --git a/a.ts b/a.ts", "@@ -1 +1 @@", "+x"].join("\n");
  assertEquals(parseDiff(diff, false).rows[0].kind, "hunk");
});

Deno.test("remote commands quote the repo and survive a non-zero git exit", () => {
  const command = statusCommand("owner's repo");
  assertEquals(command.includes(`'owner'\\''s repo'`), true);
  assertEquals(command.endsWith("exit 0"), true);
  assertEquals(fileDiffCommand("repo", "a b.txt").endsWith("exit 0"), true);
  assertEquals(repoDiffCommand("repo").includes("ls-files --others"), true);
});
