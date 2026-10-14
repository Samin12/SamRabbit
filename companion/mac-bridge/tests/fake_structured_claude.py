"""Stand-in for the headless Claude Code CLI (``claude -p ... --output-format json --json-schema ...``) as the voice-note
router and the morning brief call it (``samrabbit_claude.ClaudeJson``). Tests only; it never talks to the network.

Invoked as ``fake_structured_claude.py --state <dir> <claude args...>`` (a shell wrapper adds ``--state``). Each call
appends ``{args, stdin, cwd, cwdEntries, envKeys, tmpdir, system}`` to ``<dir>/calls.jsonl`` (``system``: the system
prompt file's text, read while the call runs). ``<dir>/answers.json`` is a list of answers consumed one per call (the
last repeats): ``{"mode": "ok", "output": {...}}`` (the structured output), or a mode alone: ``busy``,
``signed_out``, ``garbage``, ``slow`` (sleeps 30 s), ``budget``, ``no_output``.
"""

from __future__ import annotations

import json
import os
import sys
import time


def main() -> int:
    state = sys.argv[2]
    args = sys.argv[3:]
    stdin = sys.stdin.read()
    calls_file = os.path.join(state, "calls.jsonl")
    count = 0
    if os.path.exists(calls_file):
        with open(calls_file, encoding="utf-8") as handle:
            count = sum(1 for _ in handle)
    system = ""
    if "--system-prompt-file" in args:
        with open(args[args.index("--system-prompt-file") + 1], encoding="utf-8") as handle:
            system = handle.read()
    with open(calls_file, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"args": args, "stdin": stdin, "cwd": os.getcwd(), "cwdEntries": sorted(os.listdir(".")),
                                 "envKeys": sorted(os.environ), "tmpdir": os.environ.get("TMPDIR"),
                                 "system": system}) + "\n")
    try:
        with open(os.path.join(state, "answers.json"), encoding="utf-8") as handle:
            answers = json.load(handle)
    except (OSError, ValueError):
        answers = [{"mode": "garbage"}]
    answer = answers[min(count, len(answers) - 1)] if answers else {"mode": "garbage"}
    mode = answer.get("mode", "ok")
    envelope = {"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "duration_ms": 1234,
                "total_cost_usd": 0.0612, "modelUsage": {"claude-sonnet-5-5": {}}, "result": "", "session_id": "fake"}
    if mode == "ok":
        envelope["structured_output"] = answer.get("output") or {}
    elif mode == "slow":
        time.sleep(30)
        envelope["structured_output"] = answer.get("output") or {}
    elif mode == "busy":
        envelope.update({"is_error": True, "subtype": "error_during_execution", "api_error_status": 529,
                         "result": "Overloaded"})
    elif mode == "signed_out":
        envelope.update({"is_error": True, "result": "Not logged in. Please run /login"})
    elif mode == "budget":
        envelope.update({"is_error": True, "subtype": "error_max_budget_usd", "result": "budget"})
    elif mode == "no_output":
        envelope["result"] = "I can't do that."
    elif mode == "garbage":
        sys.stdout.write("this is not json")
        return 1
    sys.stdout.write(json.dumps(envelope))
    return 0


if __name__ == "__main__":
    sys.exit(main())
