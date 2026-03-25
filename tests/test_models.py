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

    def test_renders_teensy_protocol_lines(self) -> None:
        combo = KeyboardCommand.from_mapping(
            14,
            {
                "kind": "combo",
                "key": "esc",
                "modifiers": ["ctrl", "shift"],
            },
        )
        self.assertEqual(combo.to_teensy_lines(), ("COMBO:CTRL+SHIFT+ESC",))

        text = KeyboardCommand.from_mapping(
            15,
            {
                "kind": "text",
                "text": "hello world",
                "repeat": 2,
            },
        )
        self.assertEqual(text.to_teensy_lines(), ("TEXT:hello world", "TEXT:hello world"))

    def test_supports_down_upall_and_raw(self) -> None:
        down = KeyboardCommand.from_mapping(16, {"kind": "down", "key": "shift"})
        upall = KeyboardCommand.from_mapping(17, {"kind": "upall"})
        raw = KeyboardCommand.from_mapping(18, {"kind": "raw", "line": "KEY:F9"})

        self.assertEqual(down.to_teensy_lines(), ("DOWN:SHIFT",))
        self.assertEqual(upall.to_teensy_lines(), ("UPALL",))
        self.assertEqual(raw.to_teensy_lines(), ("KEY:F9",))

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
