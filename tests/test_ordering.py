from __future__ import annotations

from pathlib import Path
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()
