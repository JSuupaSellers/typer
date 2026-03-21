from __future__ import annotations

from dataclasses import asdict, dataclass
import json
from pathlib import Path


def _normalize_db_path(value: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        return ""
    if not cleaned.startswith("/"):
        cleaned = f"/{cleaned}"
    return cleaned.rstrip("/") or "/"


@dataclass(slots=True)
class AppConfig:
    firebase_credentials_path: str = ""
    firebase_database_url: str = ""
    firebase_commands_path: str = "/bridges/default/commands"
    firebase_state_path: str = "/bridges/default/state"
    serial_port: str = "/dev/ttyACM0"
    serial_baudrate: int = 115200
    serial_write_timeout_s: float = 1.0
    serial_reconnect_interval_s: float = 2.0
    state_file: str = "runtime/bridge-state.json"
    log_limit: int = 250
    ui_refresh_ms: int = 250
    ack_debounce_ms: int = 250

    @classmethod
    def load(cls, path: Path) -> "AppConfig":
        data = json.loads(path.read_text(encoding="utf-8"))
        return cls(**data).resolved(path.parent)

    def resolved(self, base_dir: Path) -> "AppConfig":
        payload = asdict(self)
        for key in ("firebase_credentials_path", "state_file"):
            value = str(payload[key]).strip()
            if value:
                payload[key] = str((base_dir / value).resolve()) if not Path(value).is_absolute() else value
        payload["firebase_commands_path"] = _normalize_db_path(str(payload["firebase_commands_path"]))
        payload["firebase_state_path"] = _normalize_db_path(str(payload["firebase_state_path"]))
        return AppConfig(**payload)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")

    def validate(self) -> list[str]:
        errors: list[str] = []
        if not self.firebase_credentials_path:
            errors.append("firebase_credentials_path is required")
        if not self.firebase_database_url:
            errors.append("firebase_database_url is required")
        if not self.firebase_commands_path:
            errors.append("firebase_commands_path is required")
        if not self.serial_port:
            errors.append("serial_port is required")
        if self.serial_baudrate <= 0:
            errors.append("serial_baudrate must be positive")
        if self.serial_write_timeout_s <= 0:
            errors.append("serial_write_timeout_s must be positive")
        if self.serial_reconnect_interval_s <= 0:
            errors.append("serial_reconnect_interval_s must be positive")
        if self.log_limit <= 0:
            errors.append("log_limit must be positive")
        if self.ui_refresh_ms < 50:
            errors.append("ui_refresh_ms must be at least 50")
        if self.ack_debounce_ms < 0:
            errors.append("ack_debounce_ms cannot be negative")
        credentials_path = Path(self.firebase_credentials_path)
        if self.firebase_credentials_path and not credentials_path.exists():
            errors.append(f"firebase_credentials_path does not exist: {credentials_path}")
        return errors

