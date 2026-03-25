from __future__ import annotations

from pathlib import Path
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from pi_keystream_bridge.models import KeyboardCommand
from pi_keystream_bridge.ordering import PendingCommandBuffer


class PendingCommandBufferTests(unittest.TestCase):
    def test_holds_until_gap_is_filled(self) -> None:
        buffer = PendingCommandBuffer(next_seq=8)
        later = KeyboardCommand.from_mapping(9, {"kind": "key", "key": "TAB"})
        now = KeyboardCommand.from_mapping(8, {"kind": "key", "key": "ENTER"})

        ready = buffer.push([later])
        self.assertEqual(ready, [])

        ready = buffer.push([now])
        self.assertEqual([command.seq for command in ready], [8, 9])

    def test_recovers_stale_gap_after_timeout(self) -> None:
        buffer = PendingCommandBuffer(next_seq=8)
        later = KeyboardCommand.from_mapping(10, {"kind": "key", "key": "TAB"})

        with mock.patch("pi_keystream_bridge.ordering.monotonic", side_effect=[100.0, 105.1]):
            ready = buffer.push([later])
            self.assertEqual(ready, [])

            recovery = buffer.recover_stale_gap(4.0)

        self.assertIsNotNone(recovery)
        assert recovery is not None
        self.assertEqual(recovery.skipped_from_seq, 8)
        self.assertEqual(recovery.skipped_to_seq, 9)
        self.assertEqual([command.seq for command in recovery.ready], [10])
        self.assertEqual(buffer.next_seq, 11)


if __name__ == "__main__":
    unittest.main()
