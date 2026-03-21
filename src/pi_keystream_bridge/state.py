from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import tempfile
from time import time


@dataclass(slots=True)
class BridgeState:
    last_applied_seq: int = 0
    updated_unix_s: float = 0.0


class LocalStateStore:
    def __init__(self, path: Path) -> None:
        self._path = path

    def load(self) -> BridgeState:
        if not self._path.exists():
            return BridgeState()
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return BridgeState()
        return BridgeState(
            last_applied_seq=max(int(data.get("last_applied_seq", 0)), 0),
            updated_unix_s=float(data.get("updated_unix_s", 0.0)),
        )

    def save(self, seq: int) -> BridgeState:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "last_applied_seq": max(int(seq), 0),
            "updated_unix_s": time(),
        }
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=self._path.parent,
            delete=False,
        ) as handle:
            json.dump(payload, handle, separators=(",", ":"))
            temp_name = handle.name
        Path(temp_name).replace(self._path)
        return BridgeState(**payload)

