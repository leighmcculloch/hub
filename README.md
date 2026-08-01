# hub

A terminal workspace for working with coding agents on ephemeral cloud VMs.
Each session opens a fresh VM on **exe.dev** or **sprites.dev**, connects to it,
and gives you a real terminal — driving the VM's tmux from the outside. No tmux
status bar, no prefix keys, no remote shell pretending to be your terminal:
every tmux window and split pane is its own tab, and the app *is* the tmux
client.

It runs in your terminal, written in TypeScript on [Deno](https://deno.com),
with mouse support, resizable panes and a full key map.

```
┌───────────┬──────────────────────────┬─────────────────┐
│ Sessions  │ tmux windows as tabs     │  Scope          │
│           ├──────────────────────────┤  Changed files  │
│ Existing  │   Active terminal        ├─────────────────┤
│ VMs       │                          │  Diff           │
└───────────┴──────────────────────────┴─────────────────┘
```

## Running it

```
deno task start
```

Or install it as a command:

```
deno install --global -n hub -f \
  --allow-read --allow-write --allow-env --allow-net --allow-run --allow-sys \
  src/main.ts
```

The permissions are what the app actually does: read and write its config, read
the environment for tokens, reach the provider and GitHub APIs, and spawn `ssh`
(or the `sprite` CLI) and your browser.

## What you see

Three panes, all resizable (drag the dividers) and hideable:

- **Left — sessions.** One row per open session; click to switch. Below them,
  under **EXISTING**, the VMs already on your account — nothing is connected
  until you click one. `Alt+S` toggles the pane.
- **Middle — the terminal.** A tab strip above the pane, one tab per tmux pane.
  The app is the tmux client, so every tmux window (and every pane of a split)
  is its own tab — they appear and disappear as tmux's windows do, however they
  were opened. The screen itself comes from `capture-pane -e`, so what you see
  is exactly what tmux has rendered, colours included.
- **Right — the worktree diff.** Three stacked panes: **scope**, **files** and
  the **diff**. The scope list offers every git repo in the VM's home directory
  (plus any worktrees under a repo's `.claude/worktrees`), each with its working
  tree, an **All N commits** row for the branch's whole work against its default
  branch, and the commits themselves. Click a commit to read its diff,
  shift-click a second to diff the run together. It re-polls every few seconds —
  backing off while a VM is unreachable — so edits appear without clicking
  anything. `Alt+R` toggles the pane.

The diff pane reaches VM repos by running `git` over the same transport the
terminal holds, reusing SSH's multiplexed connection, so it is cheap once a
session has connected.

## Keys

The whole interface is reachable from the keyboard. `Tab` and `Shift+Tab` walk
a focus ring through every control — the session list, the New Session button,
the tab strip, the repo dropdown, the scope and file lists, the diff — and the
arrow keys move within whichever one has the keyboard.

The terminal pane is the single exception, and it has to be: while you are
typing in it, every key belongs to the program running there, `Tab` included —
a shell without tab completion is not a shell. `Alt+F` steps out of it, `Enter`
on the tab strip (or a click) steps back in, and the status bar always says
which of the two you are in.

Everything else is an `Alt` chord, for the same reason.

| Key | |
| --- | --- |
| `Tab` / `Shift+Tab` | Move between controls |
| `↑ ↓ ← →` | Move within the focused control |
| `Enter` | Activate; on the tab strip, start typing |
| `Alt+F` | Leave the terminal |
| `Esc` | Back to typing in the terminal |
| `Alt+N` | New session on a fresh VM |
| `Alt+L` | New local shell |
| `Alt+W` | Close the session (leaves the VM running) |
| `Alt+D` | Delete the session and destroy its VM |
| `Alt+O` | Open this VM's URL in the system browser |
| `Alt+S` / `Alt+R` | Toggle the left / right pane |
| `Alt+1`…`Alt+9` | Select a session (9 is the last) |
| `Alt+[` / `Alt+]` | Previous / next session |
| `Alt+T` | New tmux window in this session |
| `Alt+←` / `Alt+→` | Previous / next terminal tab |
| `Alt+K` | Reconnect a dropped session |
| `Alt+,` | Settings |
| `F1` | Key map |
| `Alt+Q` | Quit |

The mouse works throughout: click to select, drag the dividers between panes and
the splits inside the diff sidebar, and use the wheel to scroll any list.
Anything that responds to a click tints under the pointer, so it is always
visible what is interactive and what is just text.

Every field marked `▾` is a dropdown. Clicking it — or pressing Enter on it —
opens the full list rather than stepping to the next value, so you can see what
the options are; type to filter it, which is what makes the model catalogue
usable. The arrow keys still step through the values without opening the list.
A text field that has the keyboard shows a caret where the next character will
land.

There is no built-in browser. `Alt+O` hands the current VM's URL to your system
browser instead, which is the one thing a terminal can't do for itself.

## Getting started

### Prerequisites

- **Deno** 2.x.
- A **VM provider account** and API token — either [exe.dev](https://exe.dev) or
  [sprites.dev](https://sprites.dev) (chosen in Settings).
- For **exe.dev**: an **SSH key** registered with exe.dev — the same one
  `ssh <vm>.exe.xyz` uses.
- For **sprites.dev**: the **`sprite` CLI** installed locally — the app drives
  sprites through `sprite exec` the way it drives exe.dev VMs through `ssh`.
- (Optional) the **GitHub CLI** (`gh`) or a `GITHUB_TOKEN`, so the repo picker
  can list your repositories. exe.dev brokers private-repo cloning itself;
  sprites.dev clones with this token from github.com.

### The VM provider and token

Choose a provider in **Settings** (`Alt+,`): **exe.dev** or **sprites.dev**. New
sessions provision on the chosen provider; existing sessions keep the provider
they were opened with, and switching reloads the **EXISTING** list.

Set the active provider's token in Settings or via an environment variable; it
is stored in the config file, never in this repo.

| Provider | Env var | Notes |
| --- | --- | --- |
| exe.dev | `EXE_DEV_TOKEN` | SSHes into `<vm>.exe.xyz`; brokers GitHub via `github.int.exe.xyz`. |
| sprites.dev | `SPRITE_TOKEN` | Reaches sprites through the `sprite` CLI (`sprite exec`); clones from github.com with your GitHub token. |

The exe.dev token needs these command permissions (`cmds`):

| Command | Why |
| --- | --- |
| `new` | Create a VM |
| `ls` | List existing VMs |
| `rm` | Delete a VM |
| `integrations list` | Check for existing GitHub integrations |
| `integrations add` | Create a GitHub integration |
| `integrations attach` | Bind an integration to a tag |
| `ssh-key generate-api-key` | Mint the rename-only token for auto-naming (optional) |

### Your first session

`Alt+N` opens the picker:

- a **name** (optional — leave it blank and the VM names itself after the
  agent's first prompt);
- an **environment**, which supplies the setup script, the command started
  inside tmux (`claude`, `codex`, …) and its environment variables;
- a **model** from the provider's LLM gateway, wired into Claude Code, Codex
  and pi — or **Custom**, which leaves whatever the VM is already configured
  with;
- the **repositories** to clone, chosen from your GitHub account or typed by
  name. Repos are optional: a session with none is just a bare VM.

The second tab, **Reopen VM**, connects to a VM that already exists.

For exe.dev, provisioning first checks for an existing GitHub integration per
repo and creates one that acts as you if there isn't one, attached to a per-repo
tag; the VM is then created with those tags so the integrations bind to it. For
sprites.dev there is no integration step — the sprite gets a `GITHUB_TOKEN` in
its environment and clones straight from github.com.

## How it connects

The app never runs an interactive `tmux attach`. It runs `tmux -C` — control
mode — over the provider's transport:

- **exe.dev** — `ssh` to `<name>.exe.xyz`, with ControlMaster multiplexing.
- **sprites.dev** — the `sprite exec` CLI, non-TTY, with
  `--max-run-after-disconnect=0` so a dropped connection reattaches to a live
  session.

Neither asks for a remote TTY: the control protocol is a byte stream on stdout,
and a PTY would only translate it. Keystrokes go back as `send-keys -H`, byte
for byte, so the pane's program sees exactly what your terminal produced. The
pane's screen is read back with `capture-pane -e` whenever it changes, which is
why the app carries no terminal emulator of its own.

The bootstrap that runs on connect is base64-encoded into the remote command, so
arbitrary multi-line content (your setup script, the Claude settings JSON)
survives argument and remote-shell parsing. It runs *inside* tmux, in the
session's first window, because stdout is the control protocol and nothing may
print on it before tmux does.

## Sessions that name themselves

A session created without a name gets a VM that names itself. The bootstrap
installs a small Python script and wires it into Claude Code's
`UserPromptSubmit` hook and Codex's `notify`; the first prompt either receives
goes to the provider's LLM gateway, which answers with a name, and the VM
renames itself through a token scoped to `rename` and nothing else. The sidebar
picks the new name up on its next poll, and the session follows the VM's new
hostname.

exe.dev only — sprites.dev has no rename API, so an unnamed sprites session
keeps its generated name.

## Configuration

Settings (`Alt+,`) holds the provider, both API tokens, the session environments
and the global environment variables. GitHub access is discovered from
`GITHUB_TOKEN`, `GH_TOKEN` or `gh auth token`.

Config lives in `~/Library/Application Support/ExeDesktopApp` on macOS and
`~/.config/hub` elsewhere; `HUB_CONFIG_DIR` overrides it. The macOS path is the
one the earlier SwiftUI version of this app used, so an existing install's
token, environments and open sessions are picked up as they are.

## Development

```
deno task check   # type-check
deno task test    # the test suite
deno task lint
deno task fmt
```

The tests cover the parts worth testing on their own: the tmux control-mode
parser, the bootstrap script builder, the diff and status parsers, the commit
range arithmetic, the config decoders, and the terminal layer's width arithmetic
and input decoding.
