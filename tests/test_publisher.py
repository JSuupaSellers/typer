from __future__ import annotations

from contextlib import contextmanager
from time import time
import unittest

from xactimate_producer.config import ProducerConfig
from xactimate_producer.publisher import FirebaseCommandPublisher


class _StaticRef:
    def __init__(self, payload):
        self._payload = payload

    def get(self):
        return self._payload


class _StaticSnapshotPublisher(FirebaseCommandPublisher):
    def __init__(self, config: ProducerConfig, *, commands_payload, state_payload) -> None:
        super().__init__(config)
        self._commands_payload = commands_payload
        self._state_payload = state_payload

    @contextmanager
    def _session(self, bridge_id: str):
        yield _StaticRef(self._commands_payload), _StaticRef(self._state_payload)


class PublisherSnapshotTests(unittest.TestCase):
    def test_snapshot_prefers_live_bridge_ready_state_over_stale_future_sequence(self) -> None:
        config = ProducerConfig(
            runtime_api_base_url="http://127.0.0.1:8787",
            firebase_credentials_path="/tmp/service-account.json",
            firebase_database_url="https://example.firebaseio.com",
        )
        state_payload = {
            "last_applied_seq": 67,
            "bridge": {
                "running": True,
                "firebase_connected": True,
                "serial_connected": True,
                "ready": True,
                "buffered_commands": 0,
                "last_seen_unix_s": time(),
            },
        }
        commands_payload = {
            "99": {"seq": 99, "kind": "key", "key": "A"},
        }
        publisher = _StaticSnapshotPublisher(
            config,
            commands_payload=commands_payload,
            state_payload=state_payload,
        )

        snapshot = publisher.snapshot("default")

        self.assertTrue(snapshot.bridge_online)
        self.assertTrue(snapshot.bridge_ready)
        self.assertEqual(snapshot.pending_command_count, 0)
        self.assertEqual(snapshot.max_published_seq, 99)


if __name__ == "__main__":
    unittest.main()
