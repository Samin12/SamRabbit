"""The watch's realtime profile still matches the R1 runtime it was copied from.

``samrabbit_realtime_profile`` vendors the R1's Primary Voice instructions, the T3 / Mac / visuals addenda and the
T3 and Mac tool specs verbatim (the bridge is Python 3.9 and cannot import ``sam_runtime``). These tests read the
runtime's own source files (``runtime/sam_runtime``, without importing them: ``ast`` evaluates the string, tuple,
list and dict constants), rebuild exactly what the R1 sends, and compare. When the runtime changes, copy the new text
into the profile.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest tests.test_realtime_profile -q
"""

from __future__ import annotations

import ast
import json
from pathlib import Path
import sys
import unittest
from typing import Any, Dict

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
RUNTIME = ROOT.parent.parent / "runtime" / "sam_runtime"
sys.path.insert(0, str(ROOT))

import samrabbit_realtime_profile as profile  # noqa: E402


def constants(path: Path, env: Dict[str, Any] = None) -> Dict[str, Any]:
    """The module-level constants of ``path`` that are plain data (strings, numbers, tuples, lists, dicts, names of
    earlier constants, ``"sep".join((...))``), in order, the way Python would compute them."""
    values: Dict[str, Any] = dict(env or {})

    def evaluate(node: ast.AST) -> Any:
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Name):
            if node.id in values:
                return values[node.id]
            if node.id in ("True", "False", "None"):
                return {"True": True, "False": False, "None": None}[node.id]
            raise KeyError(node.id)
        if isinstance(node, ast.Tuple):
            return tuple(evaluate(item) for item in node.elts)
        if isinstance(node, ast.List):
            return [evaluate(item) for item in node.elts]
        if isinstance(node, ast.Dict):
            return {evaluate(key): evaluate(value) for key, value in zip(node.keys, node.values)}
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return evaluate(node.left) + evaluate(node.right)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "join" and \
                len(node.args) == 1:
            return evaluate(node.func.value).join(evaluate(node.args[0]))
        raise ValueError(type(node).__name__)

    for node in ast.parse(path.read_text(encoding="utf-8")).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            name, value = node.targets[0].id, node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
            name, value = node.target.id, node.value
        else:
            continue
        try:
            values[name] = evaluate(value)
        except (KeyError, ValueError):
            continue
    return values


@unittest.skipUnless(RUNTIME.is_dir(), "the R1 runtime is not in this checkout")
class RuntimeSyncTest(unittest.TestCase):
    def test_primary_voice_instruction_is_the_r1s_verbatim(self) -> None:
        genui = constants(RUNTIME / "tools" / "genui.py")
        modes = constants(RUNTIME / "realtime" / "modes.py",
                          {"GENUI_VOICE_INSTRUCTION": genui["GENUI_VOICE_INSTRUCTION"]})
        self.assertEqual(modes["PRIMARY_VOICE_INSTRUCTION"], profile.PRIMARY_VOICE_INSTRUCTION)
        self.assertTrue(profile.PRIMARY_VOICE_INSTRUCTION.startswith("You are SamRabbit Voice."))
        for name in ("TOOL_RESULT_HONESTY_INSTRUCTION", "CALENDAR_WINDOW_INSTRUCTION"):
            self.assertEqual(modes[name], getattr(profile, name), name)
        self.assertEqual(genui["GENUI_VOICE_INSTRUCTION"], profile.GENUI_VOICE_INSTRUCTION)

    def test_the_domain_addenda_are_the_r1s_verbatim(self) -> None:
        for path, name in ((RUNTIME / "domains" / "t3" / "voice.py", "T3_VOICE_INSTRUCTION"),
                           (RUNTIME / "domains" / "mac" / "voice.py", "MAC_VOICE_INSTRUCTION"),
                           (RUNTIME / "domains" / "generated_ui" / "voice.py", "GENERATED_UI_VOICE_INSTRUCTION")):
            with self.subTest(name=name):
                self.assertEqual(constants(path)[name], getattr(profile, name))

    def test_the_t3_and_mac_tools_are_the_r1s_verbatim(self) -> None:
        t3 = constants(RUNTIME / "domains" / "t3" / "tools.py")
        mac = constants(RUNTIME / "domains" / "mac" / "tools.py")
        self.assertEqual(t3["T3_TOOL_SPECS"], profile.R1_T3_TOOL_SPECS)
        self.assertEqual(mac["MAC_TOOL_SPECS"], profile.R1_MAC_TOOL_SPECS)

    def test_every_other_tool_keeps_an_r1_name(self) -> None:
        sources = {
            "calendar_list_upcoming": RUNTIME / "tools" / "calendar" / "contract.py",
            "calendar_create_event": RUNTIME / "tools" / "calendar" / "contract.py",
            "journal_add": RUNTIME / "domains" / "heptabase_journal" / "tools.py",
            "journal_read": RUNTIME / "domains" / "heptabase_journal" / "tools.py",
            "ui_generate": RUNTIME / "domains" / "generated_ui" / "tools.py",
        }
        for name, path in sources.items():
            with self.subTest(name=name):
                self.assertIn(f'"{name}"', path.read_text(encoding="utf-8"))
        cards = {item["name"] for item in json.loads((RUNTIME / "tools" / "genui_tools.json").read_text())}
        self.assertEqual(cards, {tool["name"] for tool in profile.CARD_TOOLS})
        self.assertEqual(set(sources) | cards | {name for name, *_rest in profile.R1_T3_TOOL_SPECS} |
                         {name for name, *_rest in profile.R1_MAC_TOOL_SPECS}, set(profile.R1_TOOL_NAMES))
        # The only names that are not the R1's are the watch's own two and the dock's Mark seen.
        own = {tool["name"] for tool in profile.tool_definitions()} - set(profile.R1_TOOL_NAMES)
        self.assertEqual({"get_status", "recent_conversations", "mark_seen"}, own)

    def test_the_session_is_the_r1s_shape(self) -> None:
        source = (RUNTIME / "providers" / "openai" / "platform.py").read_text(encoding="utf-8")
        for fragment in ('"type": "realtime"', '"output_modalities": ["audio"]', '"voice": "marin"',
                         '"format": {"type": "audio/pcm", "rate": 24_000}', '"tool_choice": "auto"'):
            self.assertIn(fragment, source)
        config = profile.session_config(instructions_text="x", tools=[])
        self.assertEqual(("realtime", ["audio"], "marin", {"type": "audio/pcm", "rate": 24000}, "auto"),
                         (config["type"], config["output_modalities"], config["audio"]["output"]["voice"],
                          config["audio"]["output"]["format"], config["tool_choice"]))
        self.assertIn('"gpt-realtime', source)
        self.assertEqual("gpt-realtime-2.1", profile.DEFAULT_MODEL, "the R1's preferred realtime model")


if __name__ == "__main__":
    unittest.main()
