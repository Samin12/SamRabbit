from __future__ import annotations

from dataclasses import replace
import json
import tempfile
import unittest
from urllib.request import Request, urlopen

from test_heptabase_application import TOKEN, _Bridge

from sam_runtime.agents import AgentAudience
from sam_runtime.application import RuntimeApplication
from sam_runtime.config import RuntimeConfig
from sam_runtime.domains.briefing import BRIEFING_TOOL_SET
from sam_runtime.storage.migrations import LATEST_VERSION


class BriefingCaptureApplicationWiringTest(unittest.TestCase):
    def test_runtime_boots_with_capture_and_briefing_routes_and_hidden_tools(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = replace(RuntimeConfig.create(directory, TOKEN), local_api_port=0)
            config.prepare_directories()
            application = RuntimeApplication(config, credential_bridge=_Bridge())
            application.start()
            try:
                self.assertLessEqual(LATEST_VERSION, 45, "no migration for voice notes or the brief")
                binding = application._audience_router.binding_for(BRIEFING_TOOL_SET)  # noqa: SLF001
                self.assertEqual(AgentAudience.VOICE, binding.audience)
                names = {item["name"] for item in application._tools.realtime_definitions()}  # noqa: SLF001
                self.assertFalse({"briefing_read", "briefing_act"} & names, "hidden until the Mac is connected")
                port = application._server.port  # noqa: SLF001
                with urlopen(Request(f"http://127.0.0.1:{port}/v1/briefing",
                                     headers={"Authorization": "Bearer " + TOKEN}), timeout=5) as response:
                    view = json.loads(response.read())
                self.assertEqual((False, False, "unconfigured"), (view["configured"], view["available"],
                                                                   view["status"]))
                with urlopen(Request(f"http://127.0.0.1:{port}/v1/captures",
                                     headers={"Authorization": "Bearer " + TOKEN}), timeout=5) as response:
                    self.assertEqual(0, json.loads(response.read())["queued"])
            finally:
                application.stop()


if __name__ == "__main__":
    unittest.main()
