#!/usr/bin/env bash
# Unit tests for the main window's bridge rules (Sources/MainWindowMessages.swift): the page's requests, the voice
# state the shell pushes, how often it pushes, and the script it evaluates. Foundation only, no AppKit or WebKit:
# compiled with the tests here into a throwaway binary and run. Needs Xcode's command line tools.
#
#   companion/desktop/tests/window/run.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DESKTOP=$(cd "$HERE/../.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/window-tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
TARGET=arm64-apple-macos14.0
[ "$(uname -m)" = x86_64 ] && TARGET=x86_64-apple-macos14.0

xcrun swiftc -swift-version 5 -target "$TARGET" -module-name WindowTests \
  "$DESKTOP/Sources/MainWindowMessages.swift" "$HERE"/*.swift -o "$OUT/window-tests"
"$OUT/window-tests"
