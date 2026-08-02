import { assert, assertEquals, assertStringIncludes, assertThrows } from "@std/assert";
import { exeFailure } from "../src/providers/exe-client.ts";
import { apiKeyFrom, attachedTag, exeQuote, repoSlug } from "../src/providers/exe-service.ts";
import { recordFromExeVM } from "../src/providers/exe-provider.ts";
import { recordFromSprite, spritesCloneConfig } from "../src/providers/sprites-provider.ts";
import { SSHTransport, summarizeSSH } from "../src/providers/ssh-transport.ts";
import { SpritesCLITransport } from "../src/providers/sprites-cli-transport.ts";
import { NamespaceCLITransport } from "../src/providers/namespace-cli-transport.ts";
import {
  failureMessage,
  isLoginFailure,
  NamespaceError,
  parseDevBoxes,
} from "../src/providers/namespace-cli.ts";
import { namespaceClone, NamespaceProvider } from "../src/providers/namespace-provider.ts";
import { LocalTransport } from "../src/providers/local-transport.ts";
import { afterMarker, markedCommand, OUTPUT_MARKER } from "../src/git/remote-git.ts";
import { condense, tokenHint } from "../src/model/message-text.ts";
import {
  codexConfig,
  gatewayEnvironment,
  modelLabel,
  modelsFromCatalog,
  piProvider,
  piSettings,
} from "../src/model/llm-gateway.ts";
import { EXE_GATEWAY } from "../src/providers/types.ts";
import { PollBackoff } from "../src/model/poll-backoff.ts";
import { indexForShortcut, indexFrom } from "../src/model/tab-navigation.ts";
import { shortRepoLabel } from "../src/model/repo-label.ts";
import { renameCommand, TOKEN_MAX_AGE_MS, tokenIsStale } from "../src/model/auto-name.ts";

Deno.test("condense collapses a body to one readable line", () => {
  assertEquals(condense("  a\n b   c "), "a b c");
  assertEquals(condense(""), "(empty response)");
  assertEquals(condense("x".repeat(300), 10), `${"x".repeat(10)}…`);
});

Deno.test("tokenHint names the fix only for auth failures", () => {
  assertEquals(tokenHint(401, "TOKEN"), " — check TOKEN.");
  assertEquals(tokenHint(403, "TOKEN"), " — check TOKEN.");
  assertEquals(tokenHint(500, "TOKEN"), "");
});

Deno.test("exeFailure reads an error body regardless of status", () => {
  const failure = exeFailure(200, `{"error":"no such vm"}`);
  assert(failure !== null);
  assertStringIncludes(failure.message, "no such vm");
});

Deno.test("exeFailure passes a successful non-error response", () => {
  assertEquals(exeFailure(200, `{"vms":[]}`), null);
});

Deno.test("exeFailure condenses an HTML body from an intermediary", () => {
  const failure = exeFailure(502, "<html>\n  <body>Bad gateway</body>\n</html>");
  assert(failure !== null);
  assertStringIncludes(failure.message, "Bad gateway");
  assertStringIncludes(failure.message, "HTTP 502");
});

Deno.test("exeFailure points at the token on a 401", () => {
  const failure = exeFailure(401, "nope");
  assert(failure !== null);
  assertStringIncludes(failure.message, "EXE_DEV_TOKEN");
});

Deno.test("apiKeyFrom finds a token by shape, wherever it is nested", () => {
  assertEquals(apiKeyFrom(`{"key":{"secret":"exe0.abc"}}`), "exe0.abc");
  assertEquals(apiKeyFrom(`[{"a":"nope"},{"b":"exe1.def"}]`), "exe1.def");
  assertEquals(apiKeyFrom(`{"a":"not-a-token"}`), null);
  assertEquals(apiKeyFrom("not json"), null);
});

Deno.test("apiKeyFrom resolves the same way whatever the property order", () => {
  assertEquals(apiKeyFrom(`{"b":"exe0.second","a":"exe0.first"}`), "exe0.first");
});

Deno.test("repoSlug produces a tag exe.dev accepts", () => {
  assertEquals(repoSlug("owner/Repo.Name"), "owner-repo-name");
  assertEquals(repoSlug("4d63/x"), "r-4d63-x");
});

Deno.test("exeQuote survives spaces and quotes", () => {
  assertEquals(exeQuote("A=b c"), "'A=b c'");
  assertEquals(exeQuote("it's"), `'it'\\''s'`);
});

Deno.test("attachedTag reads the first tag attachment", () => {
  assertEquals(
    attachedTag({ name: "n", type: "github", attachments: ["user:me", "tag:owner-repo"] }),
    "owner-repo",
  );
  assertEquals(attachedTag({ name: "n", type: "github", attachments: [] }), null);
});

Deno.test("recordFromExeVM fills the destination in from either field", () => {
  assertEquals(recordFromExeVM({ vm_name: "box", ssh_dest: "box.exe.xyz", status: "running" }), {
    name: "box",
    destination: "box.exe.xyz",
    webURL: "https://box.exe.xyz",
    status: "running",
    provider: "exe",
  });
  assertEquals(recordFromExeVM({ vm_name: "box" }).destination, "box.exe.xyz");
});

Deno.test("recordFromSprite keeps the URL the API gave, since the name lacks it", () => {
  assertEquals(
    recordFromSprite({ name: "s", url: "https://org.sprites.dev/s", status: "running" }),
    {
      name: "s",
      destination: "s",
      webURL: "https://org.sprites.dev/s",
      status: "running",
      provider: "sprites",
    },
  );
});

Deno.test("the sprites clone config carries the token out of the URL", () => {
  assertEquals(spritesCloneConfig(null).extraConfig, "");
  assertStringIncludes(spritesCloneConfig("t").extraConfig, "$GITHUB_TOKEN");
  assertEquals(spritesCloneConfig("t").urlPrefix, "https://github.com");
});

Deno.test("summarizeSSH picks the informative line out of ssh's chatter", () => {
  const stderr = [
    "Warning: Permanently added 'host' to the list of known hosts.",
    "ssh: connect to host box.exe.xyz port 22: Connection refused",
  ].join("\n");
  assertEquals(
    summarizeSSH(stderr, 255),
    "ssh: connect to host box.exe.xyz port 22: Connection refused",
  );
});

Deno.test("summarizeSSH falls back to the last line, then to the exit code", () => {
  assertEquals(summarizeSSH("something odd\n", 1), "something odd");
  assertEquals(summarizeSSH("   \n", 3), "ssh exited with status 3");
});

Deno.test("the SSH transport multiplexes and never asks for a tty", () => {
  const transport = new SSHTransport("box.exe.xyz");
  const spec = transport.interactiveSpec("tmux -C");
  assertEquals(spec.executable, "/usr/bin/ssh");
  assert(spec.arguments.includes("ControlMaster=auto"));
  assert(!spec.arguments.includes("-t"));
  assertEquals(spec.arguments[spec.arguments.length - 1], "tmux -C");
  assert(transport.oneshotSpec("git status").arguments.includes("BatchMode=yes"));
});

Deno.test("the sprite transport runs exec with the sprite name and no unknown flags", () => {
  const spec = new SpritesCLITransport("mysprite").interactiveSpec("tmux -C");
  assertEquals(spec.arguments.slice(0, 4), ["sprite", "exec", "-s", "mysprite"]);
  // `sprite exec` has no keep-alive flag; passing one makes the CLI print its
  // usage and refuse to run, so the transport must not invent one.
  assertEquals(spec.arguments.includes("--max-run-after-disconnect=0"), false);
  assertEquals(spec.arguments[4], "--");
  assertEquals(spec.arguments[spec.arguments.length - 1], "tmux -C");
});

Deno.test("the namespace transport runs the command through `devbox ssh`", () => {
  const spec = new NamespaceCLITransport("clock-salt-5kcr").interactiveSpec("tmux -C");
  assertEquals(spec.arguments.slice(0, 4), ["devbox", "ssh", "-T", "clock-salt-5kcr"]);
  // No PTY: tmux's control protocol is a byte stream, and a remote terminal
  // would only translate it.
  assert(!spec.arguments.includes("-t"));
  assertEquals(spec.arguments[4], "--");
  assertEquals(spec.arguments[spec.arguments.length - 1], "tmux -C");
});

Deno.test("a devbox failure is summarized with the way out of it", () => {
  const transport = new NamespaceCLITransport("box");
  assertStringIncludes(
    transport.summarize("not logged in, run `devbox login`\n", 1),
    "devbox login",
  );
  assertEquals(transport.summarize("", 3), "devbox exited with status 3");
  assertEquals(transport.summarize("boom\nno such devbox\n", 1), "no such devbox");
});

Deno.test("the devbox listing is read for the name and state of each box", () => {
  const boxes = parseDevBoxes(`[
    {"name":"one","status":"RUNNING"},
    {"name":"two","status":"stopped"}
  ]`);
  assertEquals(boxes, [
    { name: "one", status: "running" },
    { name: "two", status: "stopped" },
  ]);
});

Deno.test("the listing survives the shapes its undocumented JSON might take", () => {
  // Wrapped in an object, keyed by id rather than name, or with the state
  // nested: none of these is worth losing the whole list over.
  assertEquals(parseDevBoxes(`{"devboxes":[{"id":"box-1"}]}`), [{ name: "box-1", status: null }]);
  assertEquals(parseDevBoxes(`[{"name":"a","status":{"state":"Running"}}]`), [{
    name: "a",
    status: "running",
  }]);
  // Nothing at all is an empty list, not a failure.
  assertEquals(parseDevBoxes("[]"), []);
  // An entry with no name to connect to is skipped rather than guessed at.
  assertEquals(parseDevBoxes(`[{"cpu":4}]`), []);
});

Deno.test("prose in JSON mode means an empty account, not a broken response", () => {
  // `-o json` is not a promise of JSON: with nothing to list the CLI says so in
  // words, on stdout, and exits 0. Reading that as corruption put an error in
  // the sidebar where "you have no dev boxes" was the whole story.
  assertEquals(parseDevBoxes("No devbox available yet. Try running `devbox create`."), []);
  assertEquals(parseDevBoxes("no Devboxes found"), []);
});

Deno.test("JSON that isn't a listing is still an error", () => {
  // A spoken message is one thing; a structured response this can't read is a
  // broken contract, and hiding it as "no dev boxes" would be a lie.
  assertThrows(() => parseDevBoxes(`{"error":"nope"}`), NamespaceError);
  assertThrows(() => parseDevBoxes(`[{"name":`), NamespaceError);
});

Deno.test("a failed devbox command carries the fix, when there is one", () => {
  // The CLI already names the command here, so it isn't repeated.
  const login = failureMessage(
    "list dev boxes",
    1,
    "not logged in, run `devbox login` to authenticate",
  );
  assertStringIncludes(login, "devbox login");
  assertEquals(login.match(/devbox login/g)?.length, 1);
  // A CLI that isn't installed comes back from `env` as a failed exit.
  assertStringIncludes(
    failureMessage("list dev boxes", 127, "/usr/bin/env: 'devbox': No such file or directory"),
    "get.namespace.so",
  );
  // Anything else is reported as the CLI put it, with no invented advice.
  const other = failureMessage("create dev box x", 1, "quota exceeded");
  assertStringIncludes(other, "quota exceeded");
  assert(!other.includes("devbox login"));
});

Deno.test("a failure explains itself from whichever stream the CLI used", () => {
  // This CLI writes its human messages to stdout, so a failure that says
  // nothing on stderr used to be reported as "the devbox CLI failed" — which
  // is exactly the report that sent someone looking in the wrong place.
  assertStringIncludes(
    failureMessage("list dev boxes", 1, "", "not logged in, run `devbox login` to authenticate"),
    "not logged in",
  );
  // Nothing on either stream: the exit code is at least something to go on.
  const silent = failureMessage("list dev boxes", 2, "  \n", "");
  assertStringIncludes(silent, "status 2");
  assert(!silent.includes("failed."), `an empty failure should say what it knows: ${silent}`);
});

Deno.test("a refused login is marked, so the app can offer the way back in", () => {
  assert(isLoginFailure("not logged in, run `devbox login` to authenticate"));
  assert(isLoginFailure("Unauthorized"));
  assert(!isLoginFailure("quota exceeded"));
});

Deno.test("namespace clones from github.com with the box's own token", () => {
  assertEquals(namespaceClone(null).extraConfig, "");
  assertStringIncludes(namespaceClone("t").extraConfig, "$GITHUB_TOKEN");
  assertEquals(namespaceClone("t").urlPrefix, "https://github.com");
});

Deno.test("namespace brokers no models, so no wiring is offered for one", () => {
  const provider = new NamespaceProvider();
  assertEquals(provider.harnessWiring({ provider: "anthropic", model: "m" }), null);
  assertEquals(provider.credential.kind, "cli");
  assertEquals(provider.effectiveToken(), "");
  assertEquals(provider.supportsAutoNaming, false);
});

Deno.test("gateway environment blanks the OAuth token so the gateway wins", () => {
  const environment = gatewayEnvironment({ provider: "anthropic", model: "m" }, EXE_GATEWAY);
  assertEquals(environment.find((one) => one.key === "CLAUDE_CODE_OAUTH_TOKEN")?.value, "");
  assertEquals(
    environment.find((one) => one.key === "ANTHROPIC_BASE_URL")?.value,
    EXE_GATEWAY.baseURL,
  );
});

Deno.test("codexConfig escapes a model id rather than trusting the catalogue", () => {
  const config = codexConfig({ provider: "p", model: `we"ird` }, EXE_GATEWAY);
  assertStringIncludes(config, `model = "we\\"ird"`);
  assertStringIncludes(config, `approval_policy = "never"`);
});

Deno.test("pi routes Anthropic models over Messages and everything else over completions", () => {
  assertStringIncludes(
    piProvider({ provider: "anthropic", model: "m" }, EXE_GATEWAY),
    `"anthropic-messages"`,
  );
  assertStringIncludes(
    piProvider({ provider: "fireworks", model: "m" }, EXE_GATEWAY),
    `"openai-completions"`,
  );
  assertStringIncludes(piSettings({ provider: "p", model: "m" }, EXE_GATEWAY), `"defaultModel"`);
});

Deno.test("modelsFromCatalog keeps chat models and drops embedders", () => {
  const catalog = {
    providers: [
      {
        id: "anthropic",
        models: [
          { id: "claude", output: ["text"] },
          { id: "embed", output: ["embedding"] },
          { id: "unknown" },
        ],
      },
    ],
  };
  assertEquals(modelsFromCatalog(catalog).map((one) => one.model), ["claude", "unknown"]);
  assertEquals(modelsFromCatalog({}), []);
});

Deno.test("modelLabel keeps only the last path component", () => {
  assertEquals(
    modelLabel({ provider: "fireworks", model: "accounts/fireworks/models/glm-5p2" }),
    "fireworks/glm-5p2",
  );
});

Deno.test("PollBackoff doubles on failure and snaps back on success", () => {
  const backoff = new PollBackoff();
  assertEquals(backoff.delay, PollBackoff.base);
  backoff.recordFailure();
  assertEquals(backoff.delay, PollBackoff.base);
  backoff.recordFailure();
  assertEquals(backoff.delay, PollBackoff.base * 2);
  for (let index = 0; index < 40; index += 1) backoff.recordFailure();
  assertEquals(backoff.delay, PollBackoff.maximum);
  backoff.recordSuccess();
  assertEquals(backoff.delay, PollBackoff.base);
});

Deno.test("shortcut 9 is the last tab, and past the end selects nothing", () => {
  assertEquals(indexForShortcut(1, 3), 0);
  assertEquals(indexForShortcut(9, 3), 2);
  assertEquals(indexForShortcut(4, 2), null);
  assertEquals(indexForShortcut(1, 0), null);
});

Deno.test("adjacent selection wraps at both ends", () => {
  assertEquals(indexFrom(2, 1, 3), 0);
  assertEquals(indexFrom(0, -1, 3), 2);
  assertEquals(indexFrom(null, 1, 3), 0);
  assertEquals(indexFrom(null, -1, 3), 2);
  assertEquals(indexFrom(0, 1, 0), null);
});

Deno.test("a worktree path reads as repo then branch", () => {
  assertEquals(shortRepoLabel("hub/.claude/worktrees/fix"), "hub › fix");
  assertEquals(shortRepoLabel("hub"), "hub");
  assertEquals(shortRepoLabel("hub/.claude/worktrees/"), "hub/.claude/worktrees/");
});

Deno.test("a rename token is stale when unminted, old, or from the future", () => {
  const now = Date.now();
  assertEquals(tokenIsStale(null, now), true);
  assertEquals(tokenIsStale(now - 1000, now), false);
  assertEquals(tokenIsStale(now - TOKEN_MAX_AGE_MS - 1, now), true);
  assertEquals(tokenIsStale(now + 60_000, now), true);
});

Deno.test("renameCommand carries the prompt through a login shell as JSON", () => {
  const command = renameCommand(`say "hi"\nplease`);
  assertStringIncludes(command, "bash -l -c");
  assertStringIncludes(command, "python3");
  // The quotes and newline survive as JSON escapes rather than breaking out.
  assertStringIncludes(command, '\\"hi\\"');
});

Deno.test("the local transport never runs a login shell", () => {
  const transport = new LocalTransport();
  for (const spec of [transport.interactiveSpec("tmux -C"), transport.oneshotSpec("git status")]) {
    // A profile that prints would land on stdout ahead of the real output —
    // corrupting tmux's control protocol, and inventing repos in the sidebar.
    assert(!spec.arguments.includes("-l"), `login shell in ${spec.arguments.join(" ")}`);
    assertEquals(spec.executable, "/bin/sh");
    assertEquals(spec.arguments[0], "-c");
  }
});

Deno.test("a one-shot's output starts after the marker it prints", () => {
  const command = markedCommand("git status");
  assertStringIncludes(command, OUTPUT_MARKER);
  assertStringIncludes(command, "git status");

  const noisy = `== welcome ==\nnvm: using v22\n${OUTPUT_MARKER}\nreal output\n`;
  assertEquals(afterMarker(noisy), "real output\n");
});

Deno.test("output with no marker is kept whole rather than discarded", () => {
  assertEquals(afterMarker("plain output\n"), "plain output\n");
  assertEquals(afterMarker(""), "");
});

Deno.test("only the first marker splits, so output containing one survives", () => {
  const output = `${OUTPUT_MARKER}\nfirst\n${OUTPUT_MARKER}\nsecond\n`;
  assertEquals(afterMarker(output), `first\n${OUTPUT_MARKER}\nsecond\n`);
});
