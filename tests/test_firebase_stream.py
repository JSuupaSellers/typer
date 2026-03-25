from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from pi_keystream_bridge.config import AppConfig
from pi_keystream_bridge.firebase_stream import FirebaseCommandSource


class _FakeRef:
    def __init__(self, payload=None) -> None:
        self.payload = payload
        self.updates: list[dict[str, object]] = []

    def get(self):
        return self.payload

    def update(self, payload) -> None:
        self.updates.append(dict(payload))


class FirebaseCommandSourceTests(unittest.TestCase):
    def test_publish_applied_seq_updates_state_and_clears_acknowledged_commands(self) -> None:
        source = FirebaseCommandSource(AppConfig(queue_cleanup_enabled=True), lambda _message: None, lambda _status: None)
        source._commands_ref = _FakeRef()
        source._state_ref = _FakeRef({"last_applied_seq": 0, "last_cleared_seq": 0})
        source._last_cleared_seq = 0

        source.publish_applied_seq(3)

        self.assertEqual(source._state_ref.updates[-1]["last_applied_seq"], 3)
        self.assertEqual(source._state_ref.updates[-1]["last_cleared_seq"], 3)
        self.assertEqual(source._commands_ref.updates[-1], {"1": None, "2": None, "3": None})

    def test_publish_bridge_status_writes_bridge_subdocument(self) -> None:
        source = FirebaseCommandSource(AppConfig(), lambda _message: None, lambda _status: None)
        source._state_ref = _FakeRef()

        source.publish_bridge_status({"running": True, "ready": True, "buffered_commands": 0})

        bridge_update = source._state_ref.updates[-1]["bridge"]
        self.assertTrue(bridge_update["running"])
        self.assertTrue(bridge_update["ready"])
        self.assertEqual(bridge_update["buffered_commands"], 0)
        self.assertIn("last_seen_unix_s", bridge_update)


if __name__ == "__main__":
    unittest.main()
