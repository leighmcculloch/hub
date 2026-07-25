#!/usr/bin/env bash
# Partial verification for non-macOS machines (CI on Linux, agent sandboxes).
#
# The app targets macOS, so AppKit/SwiftUI files can only be compiled by
# `swift build` on a Mac. This script does what *is* possible elsewhere:
#
#   1. syntax-parse every source file
#   2. type-check the platform-independent sources (exe.dev client, git, GitHub)
#
# On Linux, URLRequest/URLSession live in FoundationNetworking rather than
# Foundation, so those sources are copied to a temp dir with that import
# injected before type-checking. The repo itself stays macOS-only.

set -euo pipefail
cd "$(dirname "$0")/.."

PORTABLE=(
  Sources/Exe/ExeClient.swift
  Sources/Exe/ExeService.swift
  Sources/Git/GitWorktree.swift
  Sources/Git/RemoteGit.swift
  Sources/GitHub/GitHubRepos.swift
)

echo "==> syntax-parsing all sources"
swiftc -parse $(find Sources -name '*.swift')

echo "==> type-checking platform-independent sources"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for f in "${PORTABLE[@]}"; do
  awk 'NR==1{print "#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif"}1' \
    "$f" > "$work/$(basename "$f")"
done
swiftc -typecheck "$work"/*.swift

echo '==> ok (AppKit/SwiftUI files still need "swift build" on macOS)'
