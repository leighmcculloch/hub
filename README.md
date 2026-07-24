# Ghostty Workspace

A native macOS app that embeds [**libghostty**](https://github.com/ghostty-org/ghostty)
to give you a multi-session terminal with:

- **Vertical session tabs** down the left — one per libghostty terminal, click to
  switch, `⌘T` for a new one, `⌘W` to close.
- **The active terminal** filling the middle. Each tab is a real libghostty
  surface, kept alive in the background so its shell survives tab switches.
- **A worktree diff sidebar** on the right that automatically shows `git diff`
  for whatever directory the focused terminal is currently in — it follows the
  shell's working directory as you `cd` around. Toggle it with `⌥⌘D`.

## Architecture

```
┌───────────┬──────────────────────────┬─────────────────┐
│ Session   │                          │  Worktree Diff  │
│ tabs      │   Active libghostty       │  (git diff of   │
│ (⌘T/⌘W)   │   surface                 │   the terminal's│
│           │                          │   cwd)          │
└───────────┴──────────────────────────┴─────────────────┘
```

SwiftUI provides the window chrome and both sidebars; the terminal itself is an
AppKit `NSView` hosting a libghostty Metal surface.

| Area | Files |
| --- | --- |
| libghostty bindings | `Sources/Ghostty/` — app/config/surface wrappers over the C embedding API |
| Terminal surface view | `Sources/Ghostty/SurfaceView.swift` — Metal host + input forwarding |
| App state | `Sources/Model/` — `Workspace` and `TerminalSession` |
| Git | `Sources/Git/GitWorktree.swift` — shells out to `git`, no libghostty coupling |
| UI | `Sources/Views/` — sidebar, terminal host, diff sidebar, layout |
| App entry | `Sources/App/` — `@main` SwiftUI `App` + `AppDelegate` |

**How the diff follows the terminal:** libghostty reports the shell's working
directory (via OSC 7) through its action callback. `GhosttyApp` routes that to the
owning `TerminalSession`, whose `workingDirectory` is `@Published`; the diff
sidebar recomputes `git diff HEAD` for that directory whenever it changes.

## Building

This project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and links a prebuilt `GhosttyKit.xcframework`.

```sh
# 1. Provide libghostty (see vendor/README.md for the full recipe)
#    -> place the framework at vendor/GhosttyKit.xcframework

# 2. Generate the Xcode project
brew install xcodegen
xcodegen generate

# 3. Build & run
open GhosttyWorkspace.xcodeproj      # then ⌘R
#   or headless:
xcodebuild -scheme GhosttyWorkspace -configuration Debug build
```

Requirements: macOS 13+, Xcode 15+, and a `GhosttyKit.xcframework` built from a
Ghostty checkout.

## Status & caveats

This is a working scaffold, not a shipped product. Two things to know:

1. **libghostty's embedding API is still evolving.** Every call into the C API is
   marked with a `// GHOSTTY API:` comment. If it doesn't compile against your
   freshly built framework, reconcile those call sites against the bundled
   `ghostty.h` (struct field names, enum cases, and a couple of function
   signatures are the usual drift points). See `vendor/README.md`.
2. **Input handling is pragmatic, not exhaustive.** Printable text and IME go
   through `NSTextInputClient`; control keys and mouse/scroll are forwarded
   directly. Ghostty's own app has a richer keymap layer you can borrow from if
   you need full fidelity.
