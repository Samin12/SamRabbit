#!/usr/bin/env bash
# Headless screenshots of the desktop web UI against the fake sync server (dev only).
#   companion/desktop/dev/shoot.sh <out-dir> [port]
# Needs a running fake_sync_server.py and its token file in $SR_TOKEN_FILE (never printed). W/H size the viewport,
# SCALE=2 shoots at retina density; HASH is appended to the page's query (e.g. HASH="&morning=1": the morning brief at
# any hour).
# STEPS: shot:<name> open:<conversation> view:<home|tasks|chats|calendar|settings> eval:<file.js> click:<selector>
#        key:<key> type:<search text> post:<path> viewport:<WxH> wait:<ms> top bottom scroll:<px> errors
set -euo pipefail
OUT=${1:?out dir}; PORT=${2:-3790}
AB=${AGENT_BROWSER:-$HOME/.hermes/tools/agent-browser-0.26.0-darwin-arm64/bin/agent-browser-darwin-arm64}
TOKEN_FILE=${SR_TOKEN_FILE:-$HOME/.config/samrabbit/desktop-token}
BASE="http://127.0.0.1:$PORT"
S=sr-shoot-$$
mkdir -p "$OUT"
ab() { "$AB" --session "$S" "$@" >/dev/null; }
js() { "$AB" --session "$S" eval "$1"; }
trap '"$AB" --session "$S" close >/dev/null 2>&1 || true' EXIT
ab set viewport "${W:-1280}" "${H:-800}" ${SCALE:+"$SCALE"}
ab set media dark
ab cookies set sr_desktop "$(cat "$TOKEN_FILE")" --url "$BASE" --httpOnly --sameSite Strict
ab open "$BASE/app/?chrome=1${HASH:-}"
ab wait "${WAIT:-2500}"
for step in ${STEPS:-shot:main}; do
  kind=${step%%:*}; arg=${step#*:}
  case "$kind" in
    shot) ab screenshot "$OUT/$arg.png" ;;
    open) js "SamRabbitApp.openConversation('$arg')" >/dev/null; ab wait 1200 ;;
    top) js "document.getElementById('scroller').scrollTop=0" >/dev/null; ab wait 400 ;;
    bottom) js "const s=document.getElementById('scroller');s.scrollTop=s.scrollHeight" >/dev/null; ab wait 400 ;;
    scroll) js "document.getElementById('scroller').scrollTop=$arg" >/dev/null; ab wait 400 ;;
    click) ab click "$arg"; ab wait 700 ;;
    wait) ab wait "$arg" ;;
    key) ab press "$arg"; ab wait 400 ;;
    type) ab fill '#search' "$arg"; ab wait 700 ;;
    post) curl -s -X POST -H "X-SamRabbit-Desktop: $(cat "$TOKEN_FILE")" "$BASE$arg" >/dev/null ;;
    viewport) ab set viewport "${arg%x*}" "${arg#*x}"; ab wait 500 ;;
    view) js "SamRabbitApp.show('$arg')" >/dev/null; ab wait 900 ;;
    eval) js "$(cat "$arg")" >/dev/null; ab wait 700 ;;
    errors) "$AB" --session "$S" errors || true ;;
  esac
done
