#!/usr/bin/env bash
# Unit tests for the Agent Dock's pure logic: inbox decoding and order, placement maths, the visibility and list
# state machines, the keyboard model. Compiles those sources (Foundation only, no AppKit) with the tests in this
# directory into a throwaway binary and runs it. Needs Xcode's command line tools.
#
#   companion/desktop/tests/swift/run.sh [name-filter]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DESKTOP=$(cd "$HERE/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/dock-tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
TARGET=arm64-apple-macos14.0
[ "$(uname -m)" = x86_64 ] && TARGET=x86_64-apple-macos14.0

xcrun swiftc -swift-version 5 -target "$TARGET" -module-name DockTests \
  "$DESKTOP/Sources/DockModels.swift" "$DESKTOP/Sources/DockPlacement.swift" \
  "$DESKTOP/Sources/DockVisibility.swift" "$DESKTOP/Sources/DockKeyboard.swift" \
  "$HERE"/*.swift -o "$OUT/dock-tests"
DOCK_FIXTURE="$DESKTOP/dev/samples/inbox.json" "$OUT/dock-tests" "$@"
