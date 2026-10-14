#!/usr/bin/env bash
# The Mac voice end to end, headless and silent: MacVoice (Sources/Voice*.swift, with SamRabbitKit) in fixture mode
# against the fake sync server's canned /v1/desktop/assistant/* routes, one scenario at a time.
#
#   companion/desktop/tests/voice/headless.sh [turns] [wake] [wake-alone] [wake-pause] [wake-later] [wake-noise]
#                                             [bargein] [talkover] [mute] [devices] [note] [note-hold] [note-offline]
#                                             [note-suggest] [note-retry]
#                                             [listen <seconds>] [listen-speech <seconds>]   (default: all but listen*)
#
# * The "Hey Rabbit" scenarios: `wake` (the phrase and the question in one breath, the first sound the listener
#   hears), `wake-alone` ("Hey Rabbit." on its own; the question comes once it listens), `wake-pause` ("Hey Rabbit.",
#   3 s, the question), `wake-later` (a sentence, 2 s, "So, hey Rabbit, what's on my calendar…"), `wake-noise` (20
#   bursts of noise a second apart, then the phrase: the listener must never stop or pause). Each must wake, and the
#   first utterance sent must be the question without the phrase (transcribed again on device).
# * `note`, `note-hold`, `note-offline`, `note-suggest`: a voice note (VoiceNote*.swift) from the dock's button (it ends
#   on the pause), with ⌃⌥N held, with the bridge refusing it for now (kept in the outbox, sent when it is back), and
#   kept as a note with a suggestion the bar's button takes on its second click; against the fake's
#   /v1/desktop/capture, the outbox in the temp folder. `note-retry`: two notes waiting in the outbox go to a slow
#   bridge while "the bridge is back" comes again mid-pass (none is called off or counted as failed). What went up is
#   transcribed again on device.
# * `mute`: mute is the conversation's; a muted conversation still ends by itself; muted while idle, "Hey Rabbit"
#   waits and says why. `devices`: reads this Mac's audio inputs (CoreAudio, no microphone opened) and the wake
#   listener's choice.
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
[ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(turns wake wake-alone wake-pause wake-later wake-noise bargein talkover mute devices note note-hold note-offline note-suggest note-retry)

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
voice alone "Hey Rabbit."
voice pause "Hey Rabbit. [[slnc 3000]] What's on my calendar this afternoon?"
voice later "I was testing the new build this morning. [[slnc 2000]] So, hey Rabbit, what's on my calendar this afternoon?"
voice note "Put this in my journal: shipped the voice notes on the Mac today."
# 20 bursts of noise (0.15 s at about -29 dBFS, a second apart: dishes, a cough, a door), then the phrase; and a
# moment of digital quiet (the fixture's room noise is added to it).
/usr/bin/python3 -I - "$WORK/hey.wav" "$WORK/noise.wav" "$WORK/quiet.wav" <<'EOF'
import random, struct, sys, wave
def write(path, samples):
    with wave.open(path, "wb") as out:
        out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
        out.writeframes(struct.pack("<%dh" % len(samples), *samples))
with wave.open(sys.argv[1], "rb") as source:
    hey = list(struct.unpack("<%dh" % source.getnframes(), source.readframes(source.getnframes())))
noise = random.Random(17)
samples = [0] * 16000
for _ in range(20):
    samples += [int(noise.uniform(-2015, 2015)) for _ in range(2400)] + [0] * 16000
write(sys.argv[2], samples + hey)
write(sys.argv[3], [0] * 1600)
EOF
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
  HOME="$WORK/home" SAMRABBIT_FAKE_ASSISTANT_SAVE="$WORK/sent" SAMRABBIT_FAKE_CAPTURE_SAVE="$WORK/sent" \
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
conversations = 2 if scenario == "mute" else 1
good = ok(len(sessions) == conversations, "one warm-up per conversation (%d)" % len(sessions))
good &= ok(all(t["stream"] and t["accept"] == "application/x-samrabbit-stream" for t in turns), "every turn streamed")
if turns:
    good &= ok(len({t["conversationId"] for t in turns}) == 1 and turns[0]["conversationId"] == sessions[0]["conversationId"],
               "one conversation, named by the warm-up")
audio = [t for t in turns if t["kind"] == "audio"]
good &= ok(all(t["bytes"] > 10000 and t["deviceTime"] for t in audio), "utterances went up as WAV")
if scenario == "turns":
    good &= ok([t["kind"] for t in turns] == ["audio", "audio"], "two utterances: %s" % [t["kind"] for t in turns])
    good &= ok(not cancels and not ends, "ended by the assistant (no cancel, no /end)")
    print("  utterances: %s s" % [t["seconds"] for t in audio])
elif scenario.startswith("wake"):
    good &= ok([t["kind"] for t in turns] == ["audio", "audio"], "two utterances: %s" % [t["kind"] for t in turns])
    first = audio[0]["seconds"] if audio else 0
    # "What's on my calendar this afternoon?" is about 2 s: in one breath with the phrase, it is all that was sent
    # (the phrase is about 1 s more); said after it, what was sent is it and the quiet before it.
    longest = 4.5 if scenario in ("wake-alone", "wake-pause") else 2.8
    good &= ok(1.2 <= first <= longest, "the first utterance is what followed the phrase (%.2f s)" % first)
elif scenario == "talkover":
    good &= ok([t["kind"] for t in turns] == ["audio", "audio"], "two utterances: %s" % [t["kind"] for t in turns])
    good &= ok(any(c["cancelled"] for c in cancels) and turns[0].get("interrupted") is True,
               "talking over the reply cancelled it on the bridge")
    print("  utterances: %s s" % [t["seconds"] for t in audio])
elif scenario == "mute":
    good &= ok(len(ends) >= 2 and all(e["ended"] for e in ends), "both conversations told the bridge they ended")
elif scenario == "bargein":
    good &= ok([t["kind"] for t in turns] == ["audio", "announce"], "an utterance, then the announcement: %s"
               % [t["kind"] for t in turns])
    good &= ok(any(c["cancelled"] for c in cancels), "the barge-in cancelled the reply on the bridge")
    good &= ok(bool(cancels) and all(c.get("turnId") == turns[0]["turnId"] for c in cancels if c["cancelled"]),
               "the cancel named the turn it meant (turnId)")
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
  local scenario=$1 fixture wake=0 idle=45
  case "$scenario" in
    turns|bargein|talkover) fixture="$WORK/ask.wav,$WORK/bye.wav" ;;
    wake) fixture="$WORK/hey.wav,$WORK/bye.wav"; wake=1 ;;
    wake-alone) fixture="$WORK/alone.wav,$WORK/ask.wav,$WORK/bye.wav"; wake=1 ;;
    wake-pause) fixture="$WORK/pause.wav,$WORK/bye.wav"; wake=1 ;;
    wake-later) fixture="$WORK/later.wav,$WORK/bye.wav"; wake=1 ;;
    wake-noise) fixture="$WORK/noise.wav,$WORK/bye.wav"; wake=1 ;;
    mute|devices) fixture="$WORK/quiet.wav"; idle=5 ;;
    note|note-hold|note-offline|note-suggest|note-retry) fixture="$WORK/note.wav" ;;
    listen) fixture="$WORK/bye.wav" ;;
    listen-speech) fixture="$WORK/talk.wav"; wake=1 ;;
    *) echo "unknown scenario $scenario" >&2; exit 64 ;;
  esac
  [ "$scenario" = bargein ] && fixture="$WORK/ask.wav"
  local enabled=NO harness=$scenario
  [ "$wake" = 1 ] || [ "$scenario" = listen ] || [ "$scenario" = mute ] && enabled=YES
  case "$scenario" in note*) enabled=YES ;; esac
  [ "$scenario" = listen-speech ] && harness=listen
  case "$scenario" in wake-*) harness=wake ;; esac
  echo "== $scenario"
  start_server
  local status=0 pid sampler
  speech_pids > "$WORK/speech-before.txt"
  : > "$WORK/speech-samples.txt"
  SAMRABBIT_APP_URL="http://127.0.0.1:$PORT/app/" SAMRABBIT_DESKTOP_TOKEN_FILE="$WORK/token" \
    SAMRABBIT_VOICE_FIXTURE="$fixture" SAMRABBIT_VOICE_FIXTURE_WAKE=$wake SAMRABBIT_VOICE_IDLE=$idle \
    SAMRABBIT_VOICE_BARGE_IN=$([ "$scenario" = talkover ] && echo 1 || echo 0) SAMRABBIT_CAPTURE_OUTBOX="$WORK/outbox-$scenario" \
    "$WORK/voice-harness" "$harness" "${@:2}" -VoiceWakeEnabled "$enabled" > "$WORK/out.txt" 2> "$WORK/harness.log" &
  pid=$!
  sample_speech "$pid" &
  sampler=$!
  wait "$pid" || status=$?
  wait "$sampler" || true
  grep -E "harness: (state|heard|ok|FAILED)|voice: (fixture|wake|a wake|the wake|audio started|turn|microphone)|note: " \
    "$WORK/harness.log" | sed 's/^/  /'
  cat "$WORK/out.txt" | sed 's/^/  /'
  if [ "$harness" = wake ]; then
    # When the listener woke, from when the first file began (after its 0.6 s lead). "Hey Rabbit." (0.8 s) said
    # on its own must wake it within a moment of the quiet after it, not when the next sound comes.
    local within=0
    case "$scenario" in wake-alone|wake-pause) within=2.8 ;; esac
    /usr/bin/python3 -I - "$WORK/harness.log" "$within" <<'EOF' || status=1
import re, sys
log = open(sys.argv[1]).read()
within = float(sys.argv[2])
said = re.search(r"^\s*([0-9.]+) voice: fixture says file 1 \((\d+) ms\)", log, re.M)
woke = re.search(r"^\s*([0-9.]+) voice: wake phrase heard", log, re.M)
if said and woke:
    at = float(woke.group(1)) - float(said.group(1)) - 0.6
    print("  woke %.2f s into the first file (it lasts %.2f s)" % (at, int(said.group(2)) / 1000))
    if within:
        print(("  ok: " if at <= within else "  FAILED: ") + "the phrase alone woke it within %.1f s" % within)
        sys.exit(0 if at <= within else 1)
EOF
  fi
  if [ "$scenario" = wake-noise ]; then
    if grep -qE "run stopped|listener pauses|keeps stopping|wake phrase off" "$WORK/harness.log"; then
      echo "  FAILED: the wake listener stopped or paused during the noise"
      status=1
    else
      echo "  ok: the wake listener never stopped or paused during the noise"
    fi
  fi
  if [ "$harness" = listen ]; then
    echo "  localspeechrecognition CPU meanwhile: $(speech_cpu)"
  elif [ "$status" = 0 ] && [ "${scenario#note}" != "$scenario" ]; then
    # What went up is the note as said (the bridge's own on-device transcriber hears it again).
    if [ -x "$WORK/transcribe" ]; then
      local said
      said=$("$WORK/transcribe" --file "$WORK/sent/capture-1.wav" | /usr/bin/python3 -I -c \
        'import json, sys; print(json.load(sys.stdin).get("text", ""))')
      echo "  the note transcribes as: “${said}”"
      /usr/bin/python3 -I -c '
import re, sys
words = re.sub(r"[^a-z\x27 ]", "", sys.argv[1].lower())
good = "journal" in words and "voice notes" in words
print(("  ok: " if good else "  FAILED: ") + "the whole note went up (“journal” … “voice notes”)")
sys.exit(0 if good else 1)' "$said" || status=1
    fi
    local left
    left=$(find "$WORK/outbox-$scenario" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$left" = 0 ]; then echo "  ok: the temp outbox is empty"; else echo "  FAILED: $left file(s) left in the outbox"; status=1; fi
  elif [ "$status" = 0 ] && [ "$scenario" != devices ]; then
    check_log "$scenario" || status=1
    if [ -x "$WORK/transcribe" ] && { [ "$harness" = wake ] || [ "$scenario" = talkover ]; }; then
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
