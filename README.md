# Exe Desktop App

A native macOS app that embeds a terminal ([**SwiftTerm**](https://github.com/migueldeicaza/SwiftTerm))
and provisions a cloud VM per tab on [**exe.dev**](https://exe.dev):

- **Vertical session tabs** down the left — one per session, click to switch,
  `⌘T` for a new one, `⌘W` to close. Resizable, and hideable with `⌘S`. On
  launch the sidebar also lists the VMs already on your exe.dev account under
  **EXISTING**; nothing is connected until you click one.
- **The active terminal** filling the middle. Each tab is a real terminal on its
  own PTY, kept alive in the background so it survives tab switches.
- **A worktree diff sidebar** on the right. For a VM tab it lists the git repos
  in the VM's home directory, lets you pick one (or view all), browse changed
  files, and see each file's diff — run over SSH. For a local shell it follows
  the shell's cwd. It auto-refreshes every 3s (including the open diff), so
  edits appear without clicking anything. Resizable, and hideable with `⌘R`.

## exe.dev VM per tab

Opening a new session (`⌘T`) provisions a fresh exe.dev VM and SSHes into it:

1. Name the session (the name becomes the VM name) and pick GitHub repos —
   selected repos hoist to the top of the list. Existing VMs are listed too, so
   a closed session can be reopened and continued.
2. For each chosen repo the app checks for an existing exe.dev GitHub
   integration (`integrations list`) and, if missing, creates one that acts as
   you, attached to a per-repo tag
   (`integrations add github --act-as-user --attach tag:<slug>`).
3. It creates a VM tagged for those integrations (`new --tag <slug> --json`), so
   the integrations bind to the VM.
4. The terminal SSHes into the VM and runs, as its first commands: seed
   `~/.claude/settings.json` (only if absent), your configurable **setup
   script**, then `git clone` for each repo through the exe.dev GitHub proxy
   (`https://github.int.exe.xyz/<owner>/<repo>.git`).
5. It then attaches to a tmux session named `exe` on the VM, creating it if
   needed. Everything runs inside tmux, so a dropped connection reattaches with
   work intact.

If an SSH session drops while the app is in the background, it reconnects
automatically when the app regains focus — and because the shell lives in tmux,
it reattaches to the running session rather than starting over.

`⌃⌘T` opens a plain local shell instead (no VM), useful offline.

### Setup

- **exe.dev token** — set it in Settings (`⌘,`) or the `EXE_DEV_TOKEN`
  environment variable. It is stored in `~/Library/Application Support/ExeDesktopApp/config.json`,
  never in this repo. The token needs these command permissions (`cmds`):
  `new`, `ls`, `integrations list`, `integrations add`, `integrations attach`.
- **Setup script** — edited in Settings, persisted in the same config file.
  Defaults to `echo insert setup script here`.
- **Start command** — what runs *inside* tmux, and only when the tmux session is
  first created (e.g. `claude`). Reconnecting attaches instead of starting a
  second copy. Empty means a plain shell. tmux itself is not configurable; the
  bootstrap installs it if the VM lacks it, and falls back to a login shell if
  that fails.
- **Environment variables** — a `KEY=VALUE` list in Settings, passed to
  `new --env` so they're set on the VM host itself and visible to every process
  on it, not just the terminal's shell. Values with spaces or quotes are shell-
  quoted for you.
- **Terminal font** — family and size in Settings; `⌘+`/`⌘-` adjust size and
  `⌘0` resets.
- **Claude settings** — the `~/.claude/settings.json` seeded onto each VM
  (dark theme, `permissions.defaultMode: auto`, commit attribution off, PR
  attribution on, `remoteControlAtStartup: true`). Editable in Settings; an
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
│ Session   │                          │  Worktree Diff  │
│ tabs      │   Active terminal         │  (git diff of   │
│ (⌘T/⌘W)   │   (SwiftTerm)             │   the terminal's│
│           │                          │   cwd)          │
└───────────┴──────────────────────────┴─────────────────┘
```

SwiftUI provides the window chrome and both sidebars; the terminal itself is
SwiftTerm's `LocalProcessTerminalView`, an AppKit view that spawns a shell over a
PTY and renders it.

| Area | Files |
| --- | --- |
| Terminal session | `Sources/Model/TerminalSession.swift` — wraps a SwiftTerm `LocalProcessTerminalView`; local shell or SSH-into-VM |
| Provisioning | `Sources/Model/SessionProvisioner.swift` — repo pick → integration → VM → SSH bootstrap |
| exe.dev API | `Sources/Exe/` — `ExeClient` (HTTPS `/exec`), `ExeService` (integrations, VM create) |
| GitHub | `Sources/GitHub/GitHubRepos.swift` — lists accessible repos for the picker |
| Config | `Sources/Config/` — persisted token, font, env vars, scripts (`AppConfig`, `EnvVar`) |
| Bootstrap | `Sources/Model/Bootstrap.swift` — VM naming + the remote bootstrap script |
| App state | `Sources/Model/Workspace.swift` — sessions + exe.dev service |
| Git diff | `Sources/Git/GitWorktree.swift` (local) and `Sources/Git/RemoteGit.swift` (git over SSH on the VM) |
| UI | `Sources/Views/` — sidebars, terminal host, resize handle, new-session sheet, settings |
| App entry | `Sources/App/` — `@main` SwiftUI `App` + `AppDelegate` |

**How the diff follows the terminal:** the shell reports its working directory
via OSC 7. SwiftTerm surfaces that through its
`hostCurrentDirectoryUpdate(source:directory:)` delegate callback, which updates
the session's `@Published workingDirectory`; the diff sidebar then recomputes
`git diff HEAD` for that directory whenever it changes.

> OSC 7 reporting requires shell integration that emits it. macOS zsh and bash
> set up under Terminal.app already do; if the sidebar isn't tracking `cd`,
> enable OSC 7 in your shell profile (search "shell integration OSC 7"). Untracked
> directories simply show "Not a git repository".

## Building

SwiftTerm is pulled via Swift Package Manager — no binary frameworks to vendor.
There are two ways to build.

### Swift CLI (fastest for dev)

```sh
swift run          # builds and launches the app
# or
swift build        # just compile
```

Every push is built on a macOS runner by `.github/workflows/build.yml`.

On a non-Mac (Linux CI, agent sandboxes) a full build is impossible — AppKit and
SwiftUI don't exist there. `scripts/check-linux.sh` does what can be done
without them: syntax-parse every file, and type-check the platform-independent
sources (exe.dev client, git, GitHub).

This runs the app as a bare executable rather than a `.app` bundle, so
`Info.plist`/entitlements aren't applied — that's fine here since the app needs
no sandbox, and it makes itself a regular foreground app at launch. Requires the
Xcode toolchain (`xcode-select --install`), macOS 13+.

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
