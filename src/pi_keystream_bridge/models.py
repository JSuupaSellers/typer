from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Mapping


_RESERVED_FIELDS = {
    "command",
    "delay_after_ms",
    "duration_ms",
    "key",
    "kind",
    "line",
    "modifiers",
    "ms",
    "post_delay_ms",
    "repeat",
    "seq",
    "text",
    "type",
}


def _as_int(value: Any, default: int = 0) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return parsed


def _guess_kind(payload: Mapping[str, Any]) -> str | None:
    raw_kind = payload.get("kind", payload.get("type"))
    if isinstance(raw_kind, str) and raw_kind.strip():
        normalized = raw_kind.strip().lower().replace("-", "_")
        if normalized == "up_all":
            return "upall"
        return normalized
    if "text" in payload:
        return "text"
    if "line" in payload or "command" in payload:
        return "raw"
    if "duration_ms" in payload or "ms" in payload:
        return "delay"
    if "key" in payload:
        modifiers = payload.get("modifiers")
        if isinstance(modifiers, list) and modifiers:
            return "combo"
        return "key"
    return None


@dataclass(slots=True, frozen=True)
class KeyboardCommand:
    seq: int
    kind: str
    key: str | None = None
    text: str | None = None
    line: str | None = None
    modifiers: tuple[str, ...] = ()
    duration_ms: int = 0
    delay_after_ms: int = 0
    repeat: int = 1
    passthrough: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_mapping(cls, seq: int, payload: Mapping[str, Any]) -> "KeyboardCommand":
        if seq <= 0:
            raise ValueError("seq must be positive")
        kind = _guess_kind(payload)
        if kind not in {"combo", "delay", "down", "key", "raw", "text", "upall"}:
            raise ValueError(f"unsupported command kind for seq {seq}: {kind}")
        key = payload.get("key")
        text = payload.get("text")
        line = payload.get("line", payload.get("command", payload.get("text")))
        modifiers_raw = payload.get("modifiers", ())
        if isinstance(modifiers_raw, str):
            modifiers = tuple(part.strip().upper() for part in modifiers_raw.split("+") if part.strip())
        else:
            modifiers = tuple(str(part).strip().upper() for part in modifiers_raw if str(part).strip())
        duration_ms = max(_as_int(payload.get("duration_ms", payload.get("ms"))), 0)
        delay_after_ms = max(_as_int(payload.get("delay_after_ms", payload.get("post_delay_ms"))), 0)
        repeat = max(_as_int(payload.get("repeat"), 1), 1)

        if kind in {"combo", "down", "key"} and (not isinstance(key, str) or not key.strip()):
            raise ValueError(f"command {seq} is missing key")
        if kind == "text" and not isinstance(text, str):
            raise ValueError(f"command {seq} is missing text")
        if kind == "raw" and (not isinstance(line, str) or not line.strip()):
            raise ValueError(f"command {seq} is missing line")
        if kind == "delay" and duration_ms <= 0:
            raise ValueError(f"command {seq} is missing duration_ms")

        passthrough = {
            str(key_name): value
            for key_name, value in payload.items()
            if key_name not in _RESERVED_FIELDS
        }
        return cls(
            seq=seq,
            kind=kind,
            key=key if isinstance(key, str) else None,
            text=text if isinstance(text, str) else None,
            line=line if isinstance(line, str) else None,
            modifiers=modifiers,
            duration_ms=duration_ms,
            delay_after_ms=delay_after_ms,
            repeat=repeat,
            passthrough=passthrough,
        )

    def describe(self) -> str:
        if self.kind == "delay":
            return f"delay {self.duration_ms}ms"
        if self.kind == "text":
            preview = self.text or ""
            return f'text "{preview[:20]}"'
        if self.kind == "raw":
            preview = (self.line or "").strip()
            return f"raw {preview[:24]}"
        if self.kind == "down":
            return f"hold {self.key or ''}".strip()
        if self.kind == "upall":
            return "release all"
        if self.kind == "combo":
            combo = "+".join((*self.modifiers, self.key or ""))
            return combo.strip("+")
        return self.key or self.kind

    def to_teensy_lines(self) -> tuple[str, ...]:
        if self.kind == "delay":
            return ()

        repeat = max(self.repeat, 1)
        if self.kind == "text":
            safe_text = (self.text or "").replace("\r", " ").replace("\n", " ")
            line = f"TEXT:{safe_text}"
        elif self.kind == "combo":
            combo = "+".join(part for part in (*self.modifiers, (self.key or "").strip().upper()) if part)
            line = f"COMBO:{combo}"
        elif self.kind == "key":
            line = f"KEY:{(self.key or '').strip().upper()}"
        elif self.kind == "down":
            line = f"DOWN:{(self.key or '').strip().upper()}"
        elif self.kind == "upall":
            line = "UPALL"
        elif self.kind == "raw":
            line = (self.line or "").replace("\r", "").replace("\n", "")
        else:
            raise ValueError(f"unsupported teensy line kind: {self.kind}")
        return tuple(line for _ in range(repeat))
