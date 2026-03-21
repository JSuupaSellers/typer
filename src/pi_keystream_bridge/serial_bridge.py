from __future__ import annotations

import json
import time
from typing import Any

import serial

from .config import AppConfig
from .models import KeyboardCommand


class SerialTransport:
    def __init__(self, config: AppConfig) -> None:
        self._config = config
        self._serial: serial.Serial | None = None

    def open(self) -> None:
        if self._serial is not None and self._serial.is_open:
            return
        self._serial = serial.Serial(
            port=self._config.serial_port,
            baudrate=self._config.serial_baudrate,
            timeout=0,
            write_timeout=self._config.serial_write_timeout_s,
        )

    def close(self) -> None:
        if self._serial is not None:
            self._serial.close()
            self._serial = None

    def send(self, command: KeyboardCommand) -> None:
        if command.kind == "delay":
            time.sleep(command.duration_ms / 1000.0)
            return
        self.open()
        if self._serial is None:
            raise serial.SerialException("serial device is not available")
        payload = command.to_serial_payload()
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"
        self._serial.write(encoded)
        self._serial.flush()
        if command.delay_after_ms > 0:
            time.sleep(command.delay_after_ms / 1000.0)

    def is_open(self) -> bool:
        return self._serial is not None and self._serial.is_open

    def serial_details(self) -> str:
        if self._serial is None:
            return self._config.serial_port
        name = getattr(self._serial, "name", self._config.serial_port)
        return str(name)

