from __future__ import annotations

import unittest

from pi_keystream_bridge.protocol import extract_commands


class ProtocolTests(unittest.TestCase):
    def test_extract_commands_accepts_dense_list_payloads_from_firebase(self) -> None:
        payload = [
            None,
            {"seq": 1, "kind": "upall"},
            {"seq": 2, "kind": "text", "text": "hello from laptop"},
            {"seq": 3, "kind": "key", "key": "ENTER"},
        ]

        commands = extract_commands("/", payload)

        self.assertEqual([command.seq for command in commands], [1, 2, 3])
        self.assertEqual(commands[0].kind, "upall")
        self.assertEqual(commands[1].kind, "text")
        self.assertEqual(commands[1].text, "hello from laptop")
        self.assertEqual(commands[2].kind, "key")
        self.assertEqual(commands[2].key, "ENTER")


if __name__ == "__main__":
    unittest.main()
