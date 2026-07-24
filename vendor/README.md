# GhosttyKit.xcframework

This app links against **libghostty**, shipped as `GhosttyKit.xcframework`. The
framework is a binary artifact and is intentionally **not** checked into this
repository (see `.gitignore`). Build it from a Ghostty source checkout and drop
it here at `vendor/GhosttyKit.xcframework`.

## Build it

Requires a recent [Zig](https://ziglang.org) toolchain (matching the version
Ghostty pins) and Xcode command line tools.

```sh
git clone https://github.com/ghostty-org/ghostty
cd ghostty
# Produces macos/GhosttyKit.xcframework
zig build xcframework
cp -R macos/GhosttyKit.xcframework /path/to/this/repo/vendor/
```

The exact `zig build` invocation and output path can drift between Ghostty
versions — check Ghostty's own `README`/`build.zig` if `xcframework` is not a
recognized step.

## Version pinning matters

The Swift bindings in `Sources/Ghostty` call the C API declared in the
`ghostty.h` header bundled inside this xcframework. That embedding API is still
evolving, so **a few struct field names, enum cases, and function signatures are
version-sensitive**. Every place that touches the C API is marked with a
`// GHOSTTY API:` comment. If the project fails to compile after dropping in a
freshly built framework, open the header and reconcile those call sites:

```sh
open vendor/GhosttyKit.xcframework/macos-arm64/GhosttyKit.framework/Headers/ghostty.h
```

Pin the Ghostty commit you built from in your own notes so the bindings and the
framework stay in lockstep.
