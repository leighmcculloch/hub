Vendored copy of the macOS half of [arach/Termini](https://github.com/arach/Termini)
at revision `5fe5375dc7742fc436a5c03583e17c9a64afb6e2` (the same revision this
app pinned as a package dependency), trimmed to what this app actually uses:
`TerminiSSH`, the iOS surface, the demo app, and its tests are dropped, along
with the swift-nio dependencies that only `TerminiSSH` needed.

It's vendored instead of a package dependency for one reason: Termini's
`write_clipboard_cb` (`Sources/Termini/TerminiRuntime.swift`) was a no-op, so
copy never worked — not mouse-selection copy-on-select, not the `Cmd+C`
`copy_to_clipboard` keybind. Both are handled inside libghostty's own
keybinding engine (default on macOS; see ghostty's `copy-on-select` and
`copy_to_clipboard` binding), not the OS Edit menu, so there was no
responder-chain `copy(_:)` to hook from the app side — the fix has to live in
Termini's clipboard callback. `write_clipboard_cb` now forwards to
`TerminiSurfaceView.writeClipboard`, which puts the copied text on
`NSPasteboard.general`, mirroring the existing `read_clipboard_cb` /
`readClipboard` pattern used for paste.

If this lands upstream, drop this directory and go back to a package
dependency on `arach/Termini`.
