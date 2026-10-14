#!/usr/bin/env bash
# The window's page under a real mouse (clicks/main.swift): a WKWebView off every display loads the app from the fake
# sync server while the voice and the inbox change underneath it as they do live, and NSEvent presses (down, 110 ms,
# up) go to the Talk button, the voice panel's buttons, the Tasks rows, a row's ✕, the toast's Undo and the detail
# pane's Dismiss. Also checks the keys (⌃N / ⌃K stay a text
# field's, nothing moves behind a sheet) and that a hidden window stops reading the bridge. Silent: no microphone, no
# speaker, nothing on any display, no permission prompt.
#
#   companion/desktop/tests/window/clicks.sh
#
# Its own fake server on a free loopback port, a temp desktop token, a temp HOME; never the bridge on :3780.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DESKTOP=$(cd "$HERE/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/window-clicks.XXXXXX")
SERVER=""
cleanup() {
  local status=$?
  if [ -n "$SERVER" ]; then
    kill "$SERVER" 2>/dev/null || true
    wait "$SERVER" 2>/dev/null || true
  fi
  rm -rf "$WORK"
  exit $status
}
trap cleanup EXIT
TARGET=arm64-apple-macos14.0
[ "$(uname -m)" = x86_64 ] && TARGET=x86_64-apple-macos14.0

xcrun swiftc -swift-version 5 -parse-as-library -target "$TARGET" "$HERE/clicks/main.swift" -o "$WORK/clicks" \
  -framework AppKit -framework WebKit

umask 077
/usr/bin/python3 -I -c 'import secrets, sys; sys.stdout.write(secrets.token_urlsafe(32) + "\n")' > "$WORK/token"
mkdir -p "$WORK/home"
PORT=$(/usr/bin/python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
# Working threads move every 0.15 s: the Tasks list changes under the pointer the way a busy inbox does.
HOME="$WORK/home" /usr/bin/python3 -I "$DESKTOP/dev/fake_sync_server.py" --port "$PORT" --token-file "$WORK/token" \
  --live-delay -1 --inbox-tick 0.15 2> "$WORK/server.log" > /dev/null &
SERVER=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/v1/sync/conversations" && break
  sleep 0.1
done

SR_BASE="http://127.0.0.1:$PORT" SR_TOKEN_FILE="$WORK/token" "$WORK/clicks"
