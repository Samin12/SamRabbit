#!/usr/bin/env bash
# Unit tests of the "Hey Rabbit" matcher, the listener's energy gate and its sample ring, and of how a conversation's
# microphone starts (pure Swift, no microphone, no speech framework, no audio): compiles
# Sources/VoiceWakeMatcher.swift with WakeMatcherTests.swift, and Sources/VoiceStart.swift with StartTests.swift,
# and runs both.
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
xcrun swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" \
  "$HERE/../../Sources/VoiceStart.swift" "$HERE/StartTests.swift" -o "$WORK/start-tests"
"$WORK/start-tests"
