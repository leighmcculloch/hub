#!/usr/bin/env bash
# Verification for non-macOS machines (Linux CI, agent sandboxes).
#
# The app targets macOS, so AppKit/SwiftUI files can only be compiled by
# `swift build` on a Mac, and `swift test` likewise. This script does what *is*
# possible elsewhere:
#
#   1. syntax-parse every source file
#   2. run the real test suite against the platform-independent sources
#
# For (2) it assembles a scratch SwiftPM package from the portable sources plus
# the repo's actual test files, so the tests being run are the committed ones,
# not a copy that can drift. On Linux, URLRequest/URLSession live in
# FoundationNetworking rather than Foundation, so that import is injected into
# the scratch copies. The repo itself stays macOS-only.

set -euo pipefail
cd "$(dirname "$0")/.."

PORTABLE=(
  Sources/Config/AppConfigData.swift
  Sources/Config/EnvVar.swift
  Sources/Config/SessionStore.swift
  Sources/Model/Bootstrap.swift
  Sources/Model/MessageText.swift
  Sources/Model/PollBackoff.swift
  Sources/Model/RepoLabel.swift
  Sources/Model/TabNavigation.swift
  Sources/Model/TerminalOSC.swift
  Sources/Exe/ExeClient.swift
  Sources/Exe/ExeService.swift
  Sources/Git/DiffParse.swift
  Sources/Git/GitWorktree.swift
  Sources/Git/RemoteGit.swift
  Sources/GitHub/GitHubRepos.swift
  Sources/GitHub/RepoReference.swift
)

# A source file that imports none of the Apple-only frameworks below could be
# tested here, so it must be listed above. Without this check, adding a new
# Foundation-only file and forgetting to list it means its logic silently never
# runs on this path — the tests would still pass, having simply not covered it.
echo "==> checking the portable list is complete"
apple_only='^import (AppKit|SwiftUI|WebKit|Termini|Combine)'
missing=$(comm -23 \
  <(find Sources -name '*.swift' | while read -r f; do
      grep -qE "$apple_only" "$f" || echo "$f"
    done | sort) \
  <(printf '%s\n' "${PORTABLE[@]}" | sort))
if [ -n "$missing" ]; then
  echo "error: these sources import no Apple-only framework but are not in PORTABLE:" >&2
  echo "$missing" >&2
  echo "Add them to scripts/check-linux.sh so their tests run here." >&2
  exit 1
fi

echo "==> syntax-parsing all sources"
swiftc -parse $(find Sources -name '*.swift')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/ExeDesktopApp" "$work/Tests/ExeDesktopAppTests"

cat > "$work/Package.swift" <<'MANIFEST'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "ExeDesktopApp",
    targets: [
        .target(name: "ExeDesktopApp", path: "Sources/ExeDesktopApp"),
        .testTarget(
            name: "ExeDesktopAppTests",
            dependencies: ["ExeDesktopApp"],
            path: "Tests/ExeDesktopAppTests"
        ),
    ]
)
MANIFEST

for f in "${PORTABLE[@]}"; do
  awk 'NR==1{print "#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif"}1' \
    "$f" > "$work/Sources/ExeDesktopApp/$(basename "$f")"
done
cp Tests/ExeDesktopAppTests/*.swift "$work/Tests/ExeDesktopAppTests/"

echo "==> running tests against the portable sources"
# `swift test` output is filtered to the summary, but pipefail keeps a test
# failure fatal rather than being masked by the filter's exit status.
( cd "$work" && swift test 2>&1 | grep -E "error:|Executed [0-9]+ tests" | tail -20 )

echo '==> ok (AppKit/SwiftUI files still need "swift build" on macOS)'
