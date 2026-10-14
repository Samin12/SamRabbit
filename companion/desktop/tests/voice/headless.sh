#!/usr/bin/env bash
# The Mac voice end to end, headless and silent: MacVoice (Sources/Voice*.swift, with SamRabbitKit) in fixture mode
# against the fake sync server's canned /v1/desktop/assistant/* routes, one scenario at a time.
#
#   companion/desktop/tests/voice/headless.sh [turns] [wake] [bargein] [talkover] [listen <seconds>]
#                                             [listen-speech <seconds>]          (default: the first four)
#
# * No microphone: the fixture microphone "says" WAV files rendered with `say -o` (to a file, never out loud) and
#   converted to 16 kHz with afconvert. No speaker: the conversation's audio is rendered into memory.
# * Its own fake server on a free loopback port, a temp desktop token, a temp HOME for the fake; the harness logs to
#   stderr and reads its settings from its arguments (nothing written to any defaults or the app's log).
# * `listen <seconds>` only runs the "Hey Rabbit" listener on a quiet room and reports its CPU use (the harness and
#   the Speech framework's localspeechrecognition service); `listen-speech <seconds>` the same while about 30 s of
#   talk without the phrase plays into it (someone on a call next to the Mac).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DESKTOP=$(cd "$HERE/../.." && pwd)
TARGET=arm64-apple-macos26.0
[ "$(uname -m)" = x86_64 ] && TARGET=x86_64-apple-macos26.0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/samrabbit-voice.XXXXXX")
SERVER=""
cleanup() {
  local status=$?
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  rm -rf "$WORK"
  exit $status
}
trap cleanup EXIT

SCENARIOS=("$@")
[ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(turns wake bargein talkover)

# 1. Build: SamRabbitKit (cached next to build.sh's default output) and the harness.
KIT=${SAMRABBIT_KIT_CACHE:-$DESKTOP/build/SamRabbitKit}
"$DESKTOP/tools/build_samrabbitkit.sh" "$KIT" "$TARGET"
echo "compiling the voice harness"
xcrun swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" -I "$KIT" -L "$KIT" -lSamRabbitKit \
  "$DESKTOP"/Sources/Voice*.swift "$HERE/HarnessSupport.swift" "$HERE/VoiceHarness.swift" -o "$WORK/voice-harness" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreMedia -framework Speech -framework Carbon

# The bridge's own on-device transcriber (companion/mac-bridge/transcribe), to hear what the voice sent.
xcrun swiftc -O -parse-as-library "$DESKTOP/../mac-bridge/transcribe/samrabbit_transcribe.swift" -o "$WORK/transcribe" \
  2> "$WORK/transcribe-build.log" || echo "(the transcriber did not build: the sent audio is not transcribed)"

# 2. Fixture voices (rendered to files; nothing is played).
voice() {
  say -o "$WORK/$1.aiff" "$2"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/$1.aiff" "$WORK/$1.wav"
}
voice ask "What's on my calendar this afternoon?"
voice hey "Hey Rabbit, what's on my calendar this afternoon?"
voice bye "Thanks, that's all."
case " $* " in *" listen-speech "*)
  voice talk "So the plan for this week is to finish the release notes, then move the calendar client over to the \
new API, and after that we review the onboarding flow with the design team. I think the biggest risk is the \
migration of the old events, because some of them have no time zone. Let's check in again on Thursday afternoon \
and see where we are, and if anything slips we can move the review to next Monday." ;;
esac

# 3. A temp token and the fake server on a free port.
umask 077
/usr/bin/python3 -I -c 'import secrets, sys; sys.stdout.write(secrets.token_urlsafe(32) + "\n")' > "$WORK/token"
mkdir -p "$WORK/home"
start_server() {
  PORT=$(/usr/bin/python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  rm -rf "$WORK/sent"; mkdir -p "$WORK/sent"
  HOME="$WORK/home" SAMRABBIT_FAKE_ASSISTANT_SAVE="$WORK/sent" \
    /usr/bin/python3 -I "$DESKTOP/dev/fake_sync_server.py" --port "$PORT" --token-file "$WORK/token" \
    --live-delay -1 --empty 2> "$WORK/server.log" > /dev/null &
  SERVER=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/v1/sync/conversations" && return 0
    sleep 0.1
  done
  echo "the fake server did not start" >&2
  cat "$WORK/server.log" >&2
  exit 1
}
stop_server() {
  kill "$SERVER" 2>/dev/null || true
  wait "$SERVER" 2>/dev/null || true
  SERVER=""
}

# What the fake server saw (byte counts and ids only), checked per scenario.
check_log() {
  curl -s -H "X-SamRabbit-Desktop: $(cat "$WORK/token")" "http://127.0.0.1:$PORT/dev/assistant" > "$WORK/log.json"
  /usr/bin/python3 -I - "$1" "$WORK/log.json" <<'EOF'
import json, sys
scenario, path = sys.argv[1], sys.argv[2]
log = json.load(open(path))
turns, sessions, cancels, ends = log["turns"], log["sessions"], log["cancels"], log["ends"]
def ok(condition, what):
    print(("  ok: " if condition else "  FAILED: ") + what)
    return condition
good = ok(len(sessions) == 1, "one warm-up (%d)" % len(sessions))
good &= ok(all(t["stream"] and t["accept"] == "application/x-samrabbit-stream" for t in turns), "every turn streamed")
good &= ok(len({t["conversationId"] for t in turns}) == 1 and turns[0]["conversationId"] == sessions[0]["conversationId"],
           "one conversation, named by the warm-up")
audio = [t for t in turns if t["kind"] == "audio"]
good &= ok(all(t["bytes"] > 10000 and t["deviceTime"] for t in audio), "utterances went up as WAV")
if scenario == "turns":
    good &= ok([t["kind"] for t in turns] == ["audio", "audio"], "two utterances: %s" % [t["kind"] for t in turns])
    good &= ok(not cancels and not ends, "ended by the assistant (no cancel, no /end)")
    print("  utterances: %s s" % [t["seconds"] for t in audio])
elif scenario == "wake":
    good &= ok([t["kind"] for t in turns] == ["audio", "audio"], "two utterances: %s" % [t["kind"] for t in turns])
    first = audio[0]["seconds"] if audio else 0
    # "Hey Rabbit, what's on my calendar this afternoon?" is about 3 s; what followed the phrase about 2 s.
    good &= ok(1.2 <= first <= 2.8, "the first utterance is what followed the phrase (%.2f s)" % first)
elif scenario == "talkover":
    good &= ok([t["kind"] for t in turns] == ["audio", "audio"], "two utterances: %s" % [t["kind"] for t in turns])
    good &= ok(any(c["cancelled"] for c in cancels) and turns[0].get("interrupted") is True,
               "talking over the reply cancelled it on the bridge")
    print("  utterances: %s s" % [t["seconds"] for t in audio])
elif scenario == "bargein":
    good &= ok([t["kind"] for t in turns] == ["audio", "announce"], "an utterance, then the announcement: %s"
               % [t["kind"] for t in turns])
    good &= ok(any(c["cancelled"] for c in cancels), "the barge-in cancelled the reply on the bridge")
    good &= ok(turns[0].get("interrupted") is True, "its stream ended interrupted")
    good &= ok(len(ends) == 1 and ends[0]["ended"], "end() told the bridge")
sys.exit(0 if good else 1)
EOF
}

# The Speech framework's on-device recognizer runs in a localspeechrecognition service started for the harness (it
# goes away with it): sampled every second while the harness runs, the CPU time of those that were not there before.
speech_pids() { ps -Ao pid=,comm= | awk '/localspeechrecognition/ { print $1 }' | sort; }
sample_speech() {
  while kill -0 "$1" 2>/dev/null; do
    ps -Ao pid=,time=,comm= | awk '/localspeechrecognition/ { print $1, $2 }' >> "$WORK/speech-samples.txt"
    sleep 1
  done
}
speech_cpu() {
  /usr/bin/python3 -I - "$WORK/speech-before.txt" "$WORK/speech-samples.txt" <<'EOF'
import sys
before = set(open(sys.argv[1]).read().split())
seen = {}
for line in open(sys.argv[2]):
    pid, time = line.split()
    if pid in before:
        continue
    minutes, seconds = time.split(":")
    seen[pid] = max(seen.get(pid, 0.0), int(minutes) * 60 + float(seconds))
print("%.2f s in %d service(s)" % (sum(seen.values()), len(seen)))
EOF
}

run() {
  local scenario=$1 fixture wake=0
  case "$scenario" in
    turns|bargein|talkover) fixture="$WORK/ask.wav,$WORK/bye.wav" ;;
    wake) fixture="$WORK/hey.wav,$WORK/bye.wav"; wake=1 ;;
    listen) fixture="$WORK/bye.wav" ;;
    listen-speech) fixture="$WORK/talk.wav"; wake=1 ;;
    *) echo "unknown scenario $scenario" >&2; exit 64 ;;
  esac
  [ "$scenario" = bargein ] && fixture="$WORK/ask.wav"
  local enabled=NO harness=$scenario
  [ "$wake" = 1 ] || [ "$scenario" = listen ] && enabled=YES
  [ "$scenario" = listen-speech ] && harness=listen
  echo "== $scenario"
  start_server
  local status=0 pid sampler
  speech_pids > "$WORK/speech-before.txt"
  : > "$WORK/speech-samples.txt"
  SAMRABBIT_APP_URL="http://127.0.0.1:$PORT/app/" SAMRABBIT_DESKTOP_TOKEN_FILE="$WORK/token" \
    SAMRABBIT_VOICE_FIXTURE="$fixture" SAMRABBIT_VOICE_FIXTURE_WAKE=$wake SAMRABBIT_VOICE_IDLE=45 \
    SAMRABBIT_VOICE_BARGE_IN=$([ "$scenario" = talkover ] && echo 1 || echo 0) \
    "$WORK/voice-harness" "$harness" "${@:2}" -VoiceWakeEnabled "$enabled" > "$WORK/out.txt" 2> "$WORK/harness.log" &
  pid=$!
  sample_speech "$pid" &
  sampler=$!
  wait "$pid" || status=$?
  wait "$sampler" || true
  grep -E "harness: (state|heard|ok|FAILED)|voice: (fixture|wake|audio started|turn)" "$WORK/harness.log" | sed 's/^/  /'
  cat "$WORK/out.txt" | sed 's/^/  /'
  if [ "$harness" = listen ]; then
    echo "  localspeechrecognition CPU meanwhile: $(speech_cpu)"
  elif [ "$status" = 0 ]; then
    check_log "$scenario" || status=1
    if [ -x "$WORK/transcribe" ] && { [ "$scenario" = wake ] || [ "$scenario" = talkover ]; }; then
      # wake: what went up first is the question that followed "Hey Rabbit", without the phrase.
      # talkover: what was said over the reply went up whole, from its first word.
      local turn=1 expect="what's" refuse="rabbit"
      [ "$scenario" = talkover ] && { turn=2; expect="thanks"; refuse="calendar"; }
      local words
      words=$("$WORK/transcribe" --file "$WORK/sent/turn-$turn.wav" | /usr/bin/python3 -I -c \
        'import json, sys; print(json.load(sys.stdin).get("text", ""))')
      echo "  utterance $turn transcribes as: “${words}”"
      /usr/bin/python3 -I -c '
import re, sys
words = re.sub(r"[^a-z\x27 ]", "", sys.argv[1].lower())
good = words.split()[:1] == [sys.argv[2]] and sys.argv[3] not in words
print(("  ok: " if good else "  FAILED: ") + "it starts with “%s” and has no “%s”" % (sys.argv[2], sys.argv[3]))
sys.exit(0 if good else 1)' "$words" "$expect" "$refuse" || status=1
    fi
  fi
  stop_server
  [ "$status" = 0 ] || { echo "== $scenario FAILED"; tail -40 "$WORK/harness.log"; return 1; }
  echo "== $scenario passed"
}

failed=0
index=0
while [ $index -lt ${#SCENARIOS[@]} ]; do
  scenario=${SCENARIOS[$index]}
  if [ "$scenario" = listen ] || [ "$scenario" = listen-speech ]; then
    seconds=${SCENARIOS[$((index + 1))]:-60}
    index=$((index + 2))
    run "$scenario" "$seconds" || failed=1
  else
    index=$((index + 1))
    run "$scenario" || failed=1
  fi
done
exit $failed
