# Exe Desktop App

A native macOS app that embeds a terminal (**libghostty**, via
[**Termini**](https://github.com/arach/Termini)) and provisions a cloud VM per
tab on [**exe.dev**](https://exe.dev):

- **Vertical session tabs** down the left — one per session, click to switch,
  `⌘T` for a new one, `⌘W` to close. Resizable, and hideable with `⌘S`. On
  launch the sidebar also lists the VMs already on your exe.dev account under
  **EXISTING**; nothing is connected until you click one.
- **The active terminal** filling the middle, with **a terminal tab strip** above
  it: for a VM session the app is the tmux client, so every tmux window (and
  every pane of a split) is its own native tab. `⌥⌘T` opens another tmux window,
  `⌥⌘W` closes the pane behind a tab, `⌥⌘←`/`⌥⌘→` move between them. Tabs appear
  and disappear as tmux's windows do, however they were opened. Each tab keeps
  its own terminal, alive in the background, so switching costs nothing. The
  strip's **+** is a small dropdown: clicking it opens a terminal as before, and
  its menu also offers **Shelley** — exe.dev's own web agent, served on the VM's
  port 9999 — as a browser tab in the same strip, complete with an address bar.
  A Shelley tab isn't tmux's, so it sits after the pane tabs and survives a
  reconnect.
- **A worktree diff sidebar** on the right. For a VM tab it lists the git repos
  in the VM's home directory (plus any git worktrees under each repo's
  `.claude/worktrees`), lets you pick one (or view all), browse changed
  files, and see each file's diff — run over SSH. For a local shell it follows
  the shell's cwd. Below the file list is **the git log for each folder shown**:
  the commits that branch has beyond its default branch, newest first. Click one
  to read its diff, shift-click a second to diff the whole run together, or take
  the **All N commits** row to diff the branch against `origin/main`. It
  auto-refreshes every 3s (including the open diff), so edits appear without
  clicking anything. Resizable, and hideable with `⌘R`.

## exe.dev VM per tab

Opening a new session (`⌘T`) provisions a fresh exe.dev VM and SSHes into it:

1. Name the session (the name becomes the VM name) or leave it blank to have the
   VM **name itself** — see below — then choose an **environment** and a
   **model**, and pick GitHub repos — selected repos hoist to the top of the
   list. Existing VMs are listed too, so a closed session can be reopened and
   continued.
2. For each chosen repo the app checks for an existing exe.dev GitHub
   integration (`integrations list`) and, if missing, creates one that acts as
   you, attached to a per-repo tag
   (`integrations add github --act-as-user --attach tag:<slug>`).
3. It creates a VM tagged for those integrations (`new --tag <slug> --json`), so
   the integrations bind to the VM.
4. The app SSHes into the VM and attaches to a tmux session named `exe`,
   creating it if needed — as a **control-mode client** (`tmux -C`), so tmux
   talks protocol to the app instead of drawing itself into a terminal.
5. The bootstrap runs as the command of that session's first window: seed
   `~/.claude/settings.json` (only if absent), write the Codex and pi
   configuration for the chosen model (only when one is chosen), run the
   environment's **setup script**, then `git clone` for each repo through the
   exe.dev GitHub proxy (`https://github.int.exe.xyz/<owner>/<repo>.git`) — so
   you watch it happen in the first tab, and it doesn't run again when you
   reattach.
6. Every directory in the VM's home dir is marked trusted in `~/.claude.json`
   (merged, never clobbering existing state), so Claude Code doesn't prompt
   per folder.

### Sessions that name themselves

Leave the name blank and the VM names itself after the work you give it. The
first prompt Claude Code or Codex receives triggers a hook on the VM, which asks
the exe.dev LLM gateway (`claude-haiku-4-5`, keyless from inside a VM) for a
two-to-four-word name and calls `rename` on the exe.dev API. The tab, the VM and
its hostname all follow — the app polls each connected VM's own
`reflection.int.exe.xyz` name every 10s, so a rename shows up in the sidebar and
in the stored workspace without you doing anything.

It happens once per VM, and only for a VM created from a blank name: a name you
typed is never replaced. The pieces on the VM are all in the home directory —
`.exe-autoname` (the script), `.exe-autoname-armed` (this VM may rename itself)
and `.exe-autoname-done` (it already tried; the file says what happened). The
hook is wired into `~/.claude/settings.json` as a `UserPromptSubmit` hook and
into `~/.codex/config.toml` as `notify`, both merged into whatever is already
there. Codex gets `notify` rather than its own `UserPromptSubmit` hook because a
Codex hook stays inert until someone runs `/hooks` and trusts it.

The VM does the renaming, so it needs a token — a **`rename`-only** one, minted
by the app (`ssh-key generate-api-key --cmds=rename`), cached in the app's
config, and passed to the VM as `EXE_RENAME_TOKEN`. It can rename that machine
and nothing else, which is the point: an agent runs on the VM with permissions
bypassed. If your account token may not mint one, the session is still created
and the new-session log says so.

If an SSH session drops while the app is in the background, it reconnects
automatically when the app regains focus — and because the panes live in tmux,
it reattaches to the running session rather than starting over, restoring each
pane's screen as its tab comes back.

`⌃⌘T` opens a plain local shell instead (no VM), useful offline.

### Setup

- **exe.dev token** — set it in Settings (`⌘,`) or the `EXE_DEV_TOKEN`
  environment variable. It is stored in `~/Library/Application Support/ExeDesktopApp/config.json`,
  never in this repo. The token needs these command permissions (`cmds`):
  `new`, `ls`, `integrations list`, `integrations add`, `integrations attach`,
  and — for sessions that name themselves — `ssh-key generate-api-key`.
- **Environments** — a named bundle of a **setup script**, a **start command**,
  and its own environment variables, edited in Settings and chosen per session.
  Ships with two: *Claude Code* (starts `claude`, with a blank
  `CLAUDE_CODE_OAUTH_TOKEN` row to paste a token into) and *Codex* (starts
  `codex`). Add your own for anything else. The setup script runs in the first
  tmux window, before the repos are cloned. The start command follows it, and
  both run only when the tmux session is first created — reconnecting attaches
  instead of starting a second copy. When the start command exits the window
  stays open at a shell; empty means just a shell. tmux itself is not
  configurable and is required — the app is a tmux client, so the remote command
  installs tmux first if the VM lacks it.
- **Global environment variables** — a `KEY=VALUE` list in Settings that
  applies whichever environment a session runs. Both lists are passed to
  `new --env`, so they're set on the VM host itself and visible to every
  process on it, not just the terminal's shell. Values with spaces or quotes
  are shell-quoted for you.
- **Model** — chosen per session from the exe.dev LLM gateway's catalogue
  (`https://exe.dev/llm-gateway-models.json`), or *Custom*, the default, which
  configures nothing and leaves the VM's own setup alone. Choosing a gateway
  model configures three harnesses and nothing else:
  - **Claude Code** — `ANTHROPIC_API_KEY=implicit`,
    `CLAUDE_CODE_OAUTH_TOKEN=` (blanked, so it can't win over the gateway),
    `ANTHROPIC_BASE_URL=https://llm.int.exe.xyz` and `ANTHROPIC_MODEL=<id>`,
    set on the VM host.
  - **Codex** — `~/.codex/config.toml` with the gateway as the `exe-llm` model
    provider, the model selected, and `approval_policy`/`sandbox_mode` set to
    skip approvals and the sandbox entirely. A `config.toml` that doesn't
    mention `exe-llm` is treated as yours and left alone, with a note on the
    terminal.
  - **pi** — the `exe-llm` provider merged into `~/.pi/agent/models.json`
    (Anthropic models over `anthropic-messages`, everything else over
    `openai-completions`), and `defaultProvider`/`defaultModel` merged into
    `~/.pi/agent/settings.json`. Both merges leave your other providers and
    settings in place.
- **Terminal font** — family and size in Settings; `⌘+`/`⌘-` adjust size and
  `⌘0` resets.
- **Claude settings** — the `~/.claude/settings.json` seeded onto each VM
  (dark theme, `permissions.defaultMode: bypassPermissions`, commit
  attribution off, PR attribution on, `remoteControlAtStartup: true`).
  Editable in Settings; an
  existing file on the VM is never overwritten.
- **GitHub repo listing** — uses a token discovered from `GITHUB_TOKEN`/`GH_TOKEN`
  or the `gh` CLI (`gh auth token`). Without one, the picker still accepts a
  manually typed `owner/repo`.
- **SSH** — your machine needs an SSH key registered with exe.dev (the same one
  `ssh <vm>.exe.xyz` uses).

> The diff sidebar reaches VM repos by running `git` over SSH, reusing the
> terminal's multiplexed connection (ControlMaster), so it's cheap once the tab
> has connected.

## Architecture

```
┌───────────┬──────────────────────────┬─────────────────┐
│ Session   │ tmux windows as tabs     │  Changed files  │
│ tabs      ├──────────────────────────┼─────────────────┤
│ (⌘T/⌘W)   │   Active terminal        │  Commit log     │
│           │   (libghostty)           ├─────────────────┤
│           │                          │  Diff           │
└───────────┴──────────────────────────┴─────────────────┘
```

SwiftUI provides the window chrome and both sidebars; the terminal itself is a
libghostty surface — Ghostty's terminal engine, rendered on the GPU — wrapped as
a SwiftUI view by Termini. Each tab owns a `TerminiTerminalController`, which is
that surface's transport end: the app pumps bytes both ways through it, from a
local PTY for a plain shell and from tmux for a VM session's panes.

**The tmux client is the app.** Rather than SSHing into a shell and running
tmux, which would render tmux's own status bar and prefix keys inside one
terminal, the remote command is `tmux -C` — [control
mode](https://github.com/tmux/tmux/wiki/Control-Mode). tmux then speaks a line
protocol on stdout: `%output %<pane> <escaped bytes>` for everything a pane
writes, notifications when windows and panes come, go and get renamed, and a
`%begin`/`%end` block per command sent back on stdin. So:

- each pane's bytes are fed to that pane's own libghostty surface — one tab each;
- keystrokes go back as `send-keys -H <hex>`, byte for byte, so typed UTF-8
  arrives as the bytes the terminal produced;
- the visible tab's size is reported with `refresh-client -C`, which is what
  sizes the session's windows;
- a pane the app hasn't seen is restored with `capture-pane`, because tmux
  replays nothing on attach.

| Area | Files |
| --- | --- |
| tmux protocol | `Sources/Tmux/TmuxControl.swift` — parsing control mode and building its commands; `TmuxClient.swift` — the ssh process and its byte plumbing |
| Terminal session | `Sources/Model/TerminalSession.swift` — a local shell, or a tmux session whose panes are `TerminalTab`s |
| Terminal output | `Sources/Model/TerminalOSC.swift` — reads the title and cwd out of a local shell's byte stream |
| Provisioning | `Sources/Model/SessionProvisioner.swift` — repo pick → integration → VM → SSH bootstrap |
| exe.dev API | `Sources/Exe/` — `ExeClient` (HTTPS `/exec`), `ExeService` (integrations, VM create), `RemoteVM` (what a VM says its name is now) |
| GitHub | `Sources/GitHub/GitHubRepos.swift` — lists accessible repos for the picker |
| Config | `Sources/Config/` — persisted token, font, env vars, environments (`AppConfig`, `EnvVar`, `SessionEnvironment`) |
| Bootstrap | `Sources/Model/Bootstrap.swift` — VM naming + the remote bootstrap script |
| Auto-naming | `Sources/Model/AutoName.swift` — the script a VM renames itself with, and the token it uses |
| Model gateway | `Sources/Model/LLMGateway.swift` — the exe.dev model catalogue and the harness configuration a choice turns into |
| App state | `Sources/Model/Workspace.swift` — sessions + exe.dev service |
| Git diff | `Sources/Git/GitWorktree.swift` (local) and `Sources/Git/RemoteGit.swift` (git over SSH on the VM) |
| Git log | `Sources/Git/GitLog.swift` — commits ahead of the default branch; `Sources/Model/DiffTarget.swift` — what a click or shift-click selects |
| UI | `Sources/Views/` — sidebars, terminal host, resize handle, new-session sheet, settings |
| App entry | `Sources/App/` — `@main` SwiftUI `App` + `AppDelegate` |

**How the diff follows the terminal:** a local shell reports its working
directory via OSC 7. libghostty renders that sequence but doesn't report it back
to the embedding app, so `TerminalOSCScanner` reads it (and the title, OSC 0/2)
off the PTY stream on its way to the surface and updates the session's
`@Published workingDirectory`; the diff sidebar then recomputes `git diff HEAD`
for that directory whenever it changes. A VM session's panes are inside tmux,
which consumes OSC 7 itself, so the path comes from tmux's
`#{pane_current_path}` in the same listing that builds the tabs.

> OSC 7 reporting requires shell integration that emits it (local shells only —
> a VM session gets its path from tmux). macOS zsh and bash
> set up under Terminal.app already do; if the sidebar isn't tracking `cd`,
> enable OSC 7 in your shell profile (search "shell integration OSC 7"). Untracked
> directories simply show "Not a git repository".

## Building

Termini is vendored under `Vendor/Termini` (see its `README.md` for why) as a
local Swift package, which still fetches the prebuilt `GhosttyKit.xcframework`
for you — nothing to build by hand. There are two ways to build.

### Swift CLI (fastest for dev)

```sh
swift run          # builds and launches the app
# or
swift build        # just compile
```

Every push is built and tested on a macOS runner by
`.github/workflows/build.yml`. That job is the real gate: it's the only place
the AppKit and SwiftUI code is compiled.

On a non-Mac (Linux CI, agent sandboxes) a full build is impossible, because
AppKit and SwiftUI don't exist there. `scripts/check-linux.sh` does what can be
done without them:

1. checks that every source importing no Apple-only framework is listed as
   portable — so a new pure file can't be added and silently go untested;
2. syntax-parses every file;
3. runs the real test suite against the portable sources, by assembling a
   scratch package from them plus the repo's actual test files. The tests it
   runs are the committed ones, not a copy that can drift.

The same workflow runs it on a Linux runner. Most of the logic lives in
Foundation-only files precisely so it can be covered this way; the deliberate
split is why the suite runs in seconds off a Mac.

This runs the app as a bare executable rather than a `.app` bundle, so
`Info.plist`/entitlements aren't applied — that's fine here since the app needs
no sandbox, and it makes itself a regular foreground app at launch. Requires the
Xcode toolchain (`xcode-select --install`), macOS 14+.

### Xcode project

Generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen); produces a
proper signed `.app` bundle.

```sh
brew install xcodegen
xcodegen generate                 # creates ExeDesktopApp.xcodeproj
open ExeDesktopApp.xcodeproj  # then press ⌘R
```

or headless:

```sh
xcodebuild -scheme ExeDesktopApp -configuration Debug build
```

In Xcode, set the target's Signing team (or "Sign to Run Locally"). The app
disables the App Sandbox so it can spawn shells and run `git` against any
directory.
