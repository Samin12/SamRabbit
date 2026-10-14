"""Each device gets its own addendum to the R1's voice instructions (samrabbit_realtime_profile.instructions)."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import samrabbit_realtime_profile as profile  # noqa: E402


class DeviceInstructionsTest(unittest.TestCase):
    def test_each_device_hears_where_it_is(self) -> None:
        for device, start in (("watch", "Apple Watch:"), ("iphone", "iPhone:"), ("mac", "Mac:")):
            with self.subTest(device):
                text = profile.instructions(t3=False, mac=False, visuals=False, device=device, earlier="x")
                self.assertTrue(text.startswith(profile.PRIMARY_VOICE_INSTRUCTION))
                self.assertIn(start, text)
                self.assertIn(f"Earlier in this {profile.DEVICE_NAMES[device]} conversation", text)
                others = [value for key, value in profile.DEVICE_INSTRUCTIONS.items() if key != device]
                self.assertFalse(any(other in text for other in others))

    def test_the_phone_is_told_its_own_now_line(self) -> None:
        self.assertIn("device: phone]", profile.IPHONE_INSTRUCTION)  # samrabbit_assistant tags iOS turns "phone"
        self.assertIn('"ios": "phone"', (ROOT / "samrabbit_assistant.py").read_text())
        self.assertIn('"ios": "iphone"', (ROOT / "samrabbit_assistant.py").read_text())

    def test_an_unknown_device_is_the_watch(self) -> None:
        self.assertIn(profile.WATCH_INSTRUCTION, profile.instructions(t3=False, mac=False, visuals=False, device="?"))


if __name__ == "__main__":
    unittest.main()
