from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from pi_keystream_bridge.models import KeyboardCommand
from pi_keystream_bridge.protocol import extract_commands


class KeyboardCommandTests(unittest.TestCase):
    def test_builds_text_command(self) -> None:
        command = KeyboardCommand.from_mapping(
            12,
            {
                "kind": "text",
                "text": "Line item",
                "delay_after_ms": 150,
            },
        )
        self.assertEqual(command.seq, 12)
        self.assertEqual(command.kind, "text")
        self.assertEqual(command.text, "Line item")
        self.assertEqual(command.delay_after_ms, 150)

    def test_extracts_sorted_commands_from_snapshot(self) -> None:
        commands = extract_commands(
            "/",
            {
                "5": {"kind": "delay", "duration_ms": 300},
                "3": {"kind": "key", "key": "TAB"},
                "meta": {"status": "ignored"},
            },
        )
        self.assertEqual([command.seq for command in commands], [3, 5])


if __name__ == "__main__":
    unittest.main()
