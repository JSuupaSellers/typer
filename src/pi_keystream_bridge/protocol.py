from __future__ import annotations

from typing import Any

from .models import KeyboardCommand


def _extract_seq(key: str, payload: dict[str, Any]) -> int:
    seq = payload.get("seq")
    if seq is not None:
        try:
            return int(seq)
        except (TypeError, ValueError):
            return 0
    try:
        return int(key)
    except (TypeError, ValueError):
        return 0


def extract_commands(event_path: str, data: Any) -> list[KeyboardCommand]:
    if data is None or not isinstance(data, dict):
        return []
    key_from_path = event_path.strip("/").split("/")[-1] if event_path else ""
    if key_from_path and (key_from_path.isdigit() or "seq" in data):
        seq = _extract_seq(key_from_path, data)
        if seq > 0:
            try:
                return [KeyboardCommand.from_mapping(seq, data)]
            except ValueError:
                return []
    commands: list[KeyboardCommand] = []
    for key, payload in data.items():
        if not isinstance(payload, dict):
            continue
        seq = _extract_seq(str(key), payload)
        if seq <= 0:
            continue
        try:
            commands.append(KeyboardCommand.from_mapping(seq, payload))
        except ValueError:
            continue
    commands.sort(key=lambda command: command.seq)
    return commands

