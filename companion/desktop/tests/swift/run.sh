#!/usr/bin/env bash
# Unit tests for the Agent Dock's pure logic: inbox decoding and order, placement maths (corner + gap, clamping,
# snapping, the list's side) and its memory (Wave 6's spot converted once), the visibility, show/hide/minimize and
# list state machines (the menus' pointer-free hide and show too), the keyboard model and the global shortcuts
# (parsing, rules), voice notes (⌃⌥N's hold and tap, the outbox, the bridge's answers) and the morning brief.
# Compiles those sources (Foundation only, no AppKit) with the tests in this
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
  "$DESKTOP/Sources/DockVisibility.swift" "$DESKTOP/Sources/DockKeyboard.swift" "$DESKTOP/Sources/DockShortcut.swift" \
  "$DESKTOP/Sources/DockBriefing.swift" "$DESKTOP/Sources/VoiceNoteModels.swift" \
  "$HERE"/*.swift -o "$OUT/dock-tests"
DOCK_FIXTURE="$DESKTOP/dev/samples/inbox.json" "$OUT/dock-tests" "$@"
