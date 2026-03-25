from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from pi_keystream_bridge.config import AppConfig
from pi_keystream_bridge.models import KeyboardCommand
from pi_keystream_bridge.serial_bridge import SerialTransport


class _FakeSerial:
    def __init__(self) -> None:
        self.is_open = True
        self.name = "/dev/fake-teensy"
        self.writes: list[bytes] = []
        self.flush_count = 0

    def write(self, data: bytes) -> None:
        self.writes.append(data)

    def flush(self) -> None:
        self.flush_count += 1


class SerialTransportTests(unittest.TestCase):
    def test_sends_teensy_lines_over_serial(self) -> None:
        transport = SerialTransport(AppConfig())
        fake = _FakeSerial()
        transport._serial = fake  # type: ignore[attr-defined]

        command = KeyboardCommand.from_mapping(
            21,
            {
                "kind": "combo",
                "key": "c",
                "modifiers": ["ctrl"],
                "repeat": 2,
            },
        )

        transport.send(command)

        self.assertEqual(fake.writes, [b"COMBO:CTRL+C\n", b"COMBO:CTRL+C\n"])
        self.assertEqual(fake.flush_count, 1)

    def test_preserves_single_character_key_case(self) -> None:
        transport = SerialTransport(AppConfig())
        fake = _FakeSerial()
        transport._serial = fake  # type: ignore[attr-defined]

        command = KeyboardCommand.from_mapping(22, {"kind": "key", "key": "a"})

        transport.send(command)

        self.assertEqual(fake.writes, [b"KEY:a\n"])


if __name__ == "__main__":
    unittest.main()
