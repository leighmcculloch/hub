# Terminal Workspace

A native macOS app that embeds a terminal ([**SwiftTerm**](https://github.com/migueldeicaza/SwiftTerm))
to give you a multi-session terminal with:

- **Vertical session tabs** down the left — one per terminal, click to switch,
  `⌘T` for a new one, `⌘W` to close.
- **The active terminal** filling the middle. Each tab is a real shell running on
  its own PTY, kept alive in the background so it survives tab switches.
- **A worktree diff sidebar** on the right that automatically shows `git diff`
  for whatever directory the focused terminal is currently in — it follows the
  shell's working directory as you `cd` around. Toggle it with `⌥⌘D`.

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
| Terminal session | `Sources/Model/TerminalSession.swift` — wraps a SwiftTerm `LocalProcessTerminalView` |
| App state | `Sources/Model/Workspace.swift` — the list of sessions |
| Git | `Sources/Git/GitWorktree.swift` — shells out to `git`, no terminal coupling |
| UI | `Sources/Views/` — sidebar, terminal host, diff sidebar, layout |
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

This runs the app as a bare executable rather than a `.app` bundle, so
`Info.plist`/entitlements aren't applied — that's fine here since the app needs
no sandbox, and it makes itself a regular foreground app at launch. Requires the
Xcode toolchain (`xcode-select --install`), macOS 13+.

### Xcode project

Generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen); produces a
proper signed `.app` bundle.

```sh
brew install xcodegen
xcodegen generate                 # creates TerminalWorkspace.xcodeproj
open TerminalWorkspace.xcodeproj  # then press ⌘R
```

or headless:

```sh
xcodebuild -scheme TerminalWorkspace -configuration Debug build
```

In Xcode, set the target's Signing team (or "Sign to Run Locally"). The app
disables the App Sandbox so it can spawn shells and run `git` against any
directory.
