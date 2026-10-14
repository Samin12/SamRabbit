#!/usr/bin/env bash
# Unit tests of the "Hey Rabbit" matcher, the listener's energy gate and its sample ring (pure Swift, no microphone,
# no speech framework): compiles Sources/VoiceWakeMatcher.swift with WakeMatcherTests.swift and runs it.
#
#   companion/desktop/tests/voice/run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/samrabbit-voice-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
TARGET=arm64-apple-macos26.0
[ "$(uname -m)" = x86_64 ] && TARGET=x86_64-apple-macos26.0
xcrun swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" \
  "$HERE/../../Sources/VoiceWakeMatcher.swift" "$HERE/WakeMatcherTests.swift" -o "$WORK/wake-tests"
"$WORK/wake-tests"
