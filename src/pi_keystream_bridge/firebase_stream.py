from __future__ import annotations

from collections.abc import Callable
import threading
from time import sleep, time
from typing import Any
import uuid

import firebase_admin
from firebase_admin import credentials, db

from .config import AppConfig
from .models import KeyboardCommand
from .protocol import extract_commands


class FirebaseCommandSource:
    def __init__(
        self,
        config: AppConfig,
        log: Callable[[str], None],
        on_status: Callable[[bool], None],
    ) -> None:
        self._config = config
        self._log = log
        self._on_status = on_status
        self._app: firebase_admin.App | None = None
        self._commands_ref: Any = None
        self._state_ref: Any = None
        self._listener: Any = None
        self._active = threading.Event()
        self._write_lock = threading.Lock()
        self._last_cleared_seq = 0

    def start(self, callback: Callable[[list[KeyboardCommand]], None]) -> None:
        if self._active.is_set():
            return
        credential = credentials.Certificate(self._config.firebase_credentials_path)
        app_name = f"pi-keybridge-{uuid.uuid4().hex}"
        self._app = firebase_admin.initialize_app(
            credential,
            {"databaseURL": self._config.firebase_database_url},
            name=app_name,
        )
        self._commands_ref = db.reference(self._config.firebase_commands_path, app=self._app)
        if self._config.firebase_state_path:
            self._state_ref = db.reference(self._config.firebase_state_path, app=self._app)
            state_payload = self._state_ref.get() or {}
            if isinstance(state_payload, dict):
                self._last_cleared_seq = max(
                    int(state_payload.get("last_cleared_seq", 0) or 0),
                    int(state_payload.get("last_applied_seq", 0) or 0),
                )
        self._active.set()
        self._listener = self._commands_ref.listen(lambda event: self._handle_event(event, callback))
        self._on_status(True)
        self._log(f"Firebase listener connected to {self._config.firebase_commands_path}")

    def stop(self) -> None:
        self._active.clear()
        if self._listener is not None:
            self._listener.close()
            self._listener = None
        self._on_status(False)
        if self._app is not None:
            firebase_admin.delete_app(self._app)
            self._app = None
        self._commands_ref = None
        self._state_ref = None

    def publish_applied_seq(self, seq: int) -> None:
        if not self._state_ref:
            return
        with self._write_lock:
            payload = {
                "last_applied_seq": int(seq),
                "last_applied_at_unix_s": time(),
            }
            if self._config.queue_cleanup_enabled:
                payload["last_cleared_seq"] = int(seq)
            self._state_ref.update(payload)
            if self._config.queue_cleanup_enabled and self._commands_ref is not None and seq > self._last_cleared_seq:
                cleanup_payload = {
                    str(current_seq): None
                    for current_seq in range(self._last_cleared_seq + 1, int(seq) + 1)
                }
                if cleanup_payload:
                    self._commands_ref.update(cleanup_payload)
                    self._last_cleared_seq = int(seq)

    def publish_bridge_status(self, payload: dict[str, Any]) -> None:
        if not self._state_ref:
            return
        status_payload = dict(payload)
        status_payload["last_seen_unix_s"] = time()
        with self._write_lock:
            self._state_ref.update({"bridge": status_payload})

    def _handle_event(self, event: Any, callback: Callable[[list[KeyboardCommand]], None]) -> None:
        if not self._active.is_set():
            return
        commands = extract_commands(getattr(event, "path", "/"), getattr(event, "data", None))
        if not commands:
            return
        callback(commands)


class AckPublisher:
    def __init__(
        self,
        source: FirebaseCommandSource,
        debounce_ms: int,
        log: Callable[[str], None],
    ) -> None:
        self._source = source
        self._debounce_s = max(debounce_ms, 0) / 1000.0
        self._log = log
        self._pending_seq = 0
        self._lock = threading.Lock()
        self._wake_event = threading.Event()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, name="firebase-ack-publisher", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        self._wake_event.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None

    def mark(self, seq: int) -> None:
        with self._lock:
            self._pending_seq = max(self._pending_seq, seq)
        self._wake_event.set()

    def _run(self) -> None:
        while not self._stop_event.is_set():
            self._wake_event.wait(timeout=0.5)
            self._wake_event.clear()
            if self._debounce_s:
                sleep(self._debounce_s)
            with self._lock:
                seq = self._pending_seq
                self._pending_seq = 0
            if seq <= 0:
                continue
            try:
                self._source.publish_applied_seq(seq)
            except Exception as exc:  # pragma: no cover - network failure path
                self._log(f"Firebase state update failed: {exc}")
        with self._lock:
            seq = self._pending_seq
            self._pending_seq = 0
        if seq > 0:
            try:
                self._source.publish_applied_seq(seq)
            except Exception as exc:  # pragma: no cover - network failure path
                self._log(f"Final Firebase state update failed: {exc}")
