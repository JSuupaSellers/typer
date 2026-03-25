from __future__ import annotations

from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import queue
import threading
from typing import Any

import serial

from .config import AppConfig
from .firebase_stream import AckPublisher, FirebaseCommandSource
from .models import KeyboardCommand
from .ordering import PendingCommandBuffer
from .serial_bridge import SerialTransport
from .state import LocalStateStore


@dataclass(slots=True)
class BridgeSnapshot:
    running: bool
    firebase_connected: bool
    serial_connected: bool
    last_applied_seq: int
    buffered_commands: int
    dispatched_commands: int
    last_command: str
    last_error: str


class BridgeController:
    def __init__(self, config: AppConfig) -> None:
        self._config = config
        self._state_store = LocalStateStore(Path(config.state_file))
        self._transport = SerialTransport(config)
        self._logs: deque[str] = deque(maxlen=config.log_limit)
        self._status_lock = threading.Lock()
        self._queue: queue.Queue[KeyboardCommand | None] = queue.Queue()
        self._stop_event = threading.Event()
        self._worker: threading.Thread | None = None
        self._heartbeat_worker: threading.Thread | None = None
        self._firebase = FirebaseCommandSource(config, self.log, self._set_firebase_connected)
        self._ack_publisher = AckPublisher(self._firebase, config.ack_debounce_ms, self.log)
        self._state = self._state_store.load()
        self._buffer = PendingCommandBuffer(next_seq=self._state.last_applied_seq + 1)
        self._running = False
        self._firebase_connected = False
        self._serial_connected = False
        self._dispatched_commands = 0
        self._last_command = "-"
        self._last_error = ""

    def start(self) -> None:
        validation_errors = self._config.validate()
        if validation_errors:
            raise ValueError("; ".join(validation_errors))
        if self._running:
            return
        self._stop_event.clear()
        self._state = self._state_store.load()
        self._buffer = PendingCommandBuffer(next_seq=self._state.last_applied_seq + 1)
        self._drain_queue()
        try:
            self._transport.open()
            self._serial_connected = self._transport.is_open()
            self._worker = threading.Thread(target=self._worker_loop, name="serial-dispatch", daemon=True)
            self._worker.start()
            self._firebase.start(self._handle_commands)
            self._ack_publisher.start()
            self._running = True
            self._heartbeat_worker = threading.Thread(target=self._heartbeat_loop, name="bridge-heartbeat", daemon=True)
            self._heartbeat_worker.start()
            self._publish_bridge_status()
        except Exception:
            self.stop()
            raise
        self.log(f"Bridge started at seq {self._state.last_applied_seq}")

    def stop(self) -> None:
        if not self._running and self._worker is None:
            return
        self._stop_event.set()
        self._publish_bridge_status(
            override_running=False,
            override_firebase_connected=False,
            override_serial_connected=False,
        )
        self._ack_publisher.stop()
        self._firebase.stop()
        self._queue.put(None)
        if self._worker is not None and self._worker.is_alive():
            self._worker.join(timeout=3)
        self._worker = None
        if self._heartbeat_worker is not None and self._heartbeat_worker.is_alive():
            self._heartbeat_worker.join(timeout=2)
        self._heartbeat_worker = None
        self._transport.close()
        self._serial_connected = False
        self._firebase_connected = False
        self._running = False
        self.log("Bridge stopped")

    def snapshot(self) -> BridgeSnapshot:
        with self._status_lock:
            return BridgeSnapshot(
                running=self._running,
                firebase_connected=self._firebase_connected,
                serial_connected=self._serial_connected,
                last_applied_seq=self._state.last_applied_seq,
                buffered_commands=self._buffer.pending_count() + self._queue.qsize(),
                dispatched_commands=self._dispatched_commands,
                last_command=self._last_command,
                last_error=self._last_error,
            )

    def logs_text(self) -> str:
        with self._status_lock:
            return "\n".join(self._logs)

    def log(self, message: str) -> None:
        timestamp = datetime.now().strftime("%H:%M:%S")
        with self._status_lock:
            self._logs.append(f"[{timestamp}] {message}")

    def _set_firebase_connected(self, connected: bool) -> None:
        with self._status_lock:
            self._firebase_connected = connected

    def _handle_commands(self, commands: list[KeyboardCommand]) -> None:
        ready = self._buffer.push(commands)
        for command in ready:
            self._queue.put(command)
        if ready:
            self.log(f"Queued {len(ready)} command(s); next seq {self._buffer.next_seq}")
        self._publish_bridge_status()

    def _worker_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                command = self._queue.get(timeout=0.25)
            except queue.Empty:
                continue
            if command is None:
                break
            self._dispatch_command(command)

    def _dispatch_command(self, command: KeyboardCommand) -> None:
        while not self._stop_event.is_set():
            try:
                self._transport.send(command)
                break
            except serial.SerialException as exc:
                with self._status_lock:
                    self._serial_connected = False
                    self._last_error = str(exc)
                self.log(f"Serial link failed, retrying in {self._config.serial_reconnect_interval_s:.1f}s: {exc}")
                self._transport.close()
                if self._stop_event.wait(self._config.serial_reconnect_interval_s):
                    return
            except Exception as exc:
                with self._status_lock:
                    self._last_error = str(exc)
                self.log(f"Command {command.seq} failed: {exc}")
                return
        else:
            return

        self._serial_connected = self._transport.is_open() or command.kind == "delay"
        self._state = self._state_store.save(command.seq)
        self._ack_publisher.mark(command.seq)
        self._dispatched_commands += 1
        self._last_command = f"{command.seq}: {command.describe()}"
        self._last_error = ""
        if command.kind != "delay":
            self.log(f"Sent {self._last_command} via {self._transport.serial_details()}")
        else:
            self.log(f"Applied {self._last_command}")
        self._publish_bridge_status()

    def _drain_queue(self) -> None:
        while True:
            try:
                self._queue.get_nowait()
            except queue.Empty:
                return

    def _heartbeat_loop(self) -> None:
        while not self._stop_event.wait(self._config.bridge_heartbeat_interval_s):
            self._publish_bridge_status()

    def _publish_bridge_status(
        self,
        *,
        override_running: bool | None = None,
        override_firebase_connected: bool | None = None,
        override_serial_connected: bool | None = None,
    ) -> None:
        buffered_commands = self._buffer.pending_count() + self._queue.qsize()
        self._firebase.publish_bridge_status(
            {
                "running": self._running if override_running is None else override_running,
                "firebase_connected": (
                    self._firebase_connected if override_firebase_connected is None else override_firebase_connected
                ),
                "serial_connected": self._serial_connected if override_serial_connected is None else override_serial_connected,
                "ready": bool(
                    (self._running if override_running is None else override_running)
                    and (self._firebase_connected if override_firebase_connected is None else override_firebase_connected)
                    and (self._serial_connected if override_serial_connected is None else override_serial_connected)
                    and buffered_commands == 0
                ),
                "buffered_commands": buffered_commands,
                "dispatched_commands": self._dispatched_commands,
                "last_applied_seq": self._state.last_applied_seq,
                "last_command": self._last_command,
                "last_error": self._last_error,
            }
        )
