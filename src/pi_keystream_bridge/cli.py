from __future__ import annotations

import argparse
import json
from pathlib import Path
import time
import uuid

import firebase_admin
from firebase_admin import credentials, db

from .config import AppConfig
from .controller import BridgeController


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Firebase to serial keystream bridge")
    parser.add_argument("--config", default="config.local.json", help="Path to the JSON config file")
    subparsers = parser.add_subparsers(dest="mode", required=False)
    subparsers.add_parser("gui", help="Run the Tkinter control panel")
    subparsers.add_parser("daemon", help="Run the bridge without a GUI")
    push_test = subparsers.add_parser("push-test", help="Push a small structured test command set into Firebase")
    push_test.add_argument(
        "--preset",
        choices=("hello", "note", "tab"),
        default="hello",
        help="Command preset to push",
    )
    push_test.add_argument(
        "--text",
        default="",
        help="Optional text override for the preset payload",
    )
    push_test.add_argument(
        "--start-seq",
        type=int,
        default=0,
        help="Optional explicit starting seq; defaults to the next safe sequence in Firebase",
    )
    push_test.add_argument(
        "--print-only",
        action="store_true",
        help="Print the Firebase payload without writing it",
    )
    parser.set_defaults(mode="gui")
    return parser


def _run_daemon(config_path: Path) -> None:
    config = AppConfig.load(config_path) if config_path.exists() else AppConfig().resolved(config_path.parent)
    controller = BridgeController(config)
    controller.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        controller.stop()


def _extract_int(value: object, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _max_command_seq(snapshot: object) -> int:
    if not isinstance(snapshot, dict):
        return 0
    highest = 0
    for key, payload in snapshot.items():
        if isinstance(payload, dict):
            highest = max(highest, _extract_int(payload.get("seq"), 0))
        highest = max(highest, _extract_int(key, 0))
    return highest


def _next_start_seq(commands_snapshot: object, state_snapshot: object, explicit_start: int = 0) -> int:
    if explicit_start > 0:
        return explicit_start
    state = state_snapshot if isinstance(state_snapshot, dict) else {}
    floor = max(
        _max_command_seq(commands_snapshot),
        _extract_int(state.get("last_applied_seq"), 0),
        _extract_int(state.get("last_reserved_seq"), 0),
        _extract_int(state.get("max_published_seq"), 0),
    )
    return floor + 1


def _test_commands(preset: str, text_override: str = "") -> list[dict[str, object]]:
    if preset == "note":
        note_text = text_override.strip() or "Pi bridge test note"
        return [
            {"kind": "key", "key": "F9", "delay_after_ms": 250},
            {"kind": "text", "text": note_text, "delay_after_ms": 90},
            {"kind": "key", "key": "ENTER", "delay_after_ms": 250},
        ]
    if preset == "tab":
        return [
            {"kind": "key", "key": "TAB", "delay_after_ms": 120},
        ]
    hello_text = text_override.strip() or "hello world from firebase"
    return [
        {"kind": "text", "text": hello_text, "delay_after_ms": 90},
        {"kind": "key", "key": "ENTER", "delay_after_ms": 150},
    ]


def _build_test_payload(start_seq: int, preset: str, text_override: str = "") -> dict[str, dict[str, object]]:
    commands = _test_commands(preset, text_override)
    payload: dict[str, dict[str, object]] = {}
    seq = max(start_seq, 1)
    for command in commands:
        entry = dict(command)
        entry["seq"] = seq
        payload[str(seq)] = entry
        seq += 1
    return payload


def _run_push_test(config_path: Path, preset: str, text_override: str, explicit_start: int, print_only: bool) -> None:
    config = AppConfig.load(config_path)
    validation_errors = config.validate()
    if validation_errors:
        raise ValueError("; ".join(validation_errors))

    app_name = f"pi-keybridge-push-test-{uuid.uuid4().hex}"
    credential = credentials.Certificate(config.firebase_credentials_path)
    app = firebase_admin.initialize_app(
        credential,
        {"databaseURL": config.firebase_database_url},
        name=app_name,
    )
    try:
        commands_ref = db.reference(config.firebase_commands_path, app=app)
        state_ref = db.reference(config.firebase_state_path, app=app) if config.firebase_state_path else None
        commands_snapshot = commands_ref.get()
        state_snapshot = state_ref.get() if state_ref is not None else {}
        start_seq = _next_start_seq(commands_snapshot, state_snapshot, explicit_start)
        payload = _build_test_payload(start_seq, preset, text_override)

        print(json.dumps(payload, indent=2))
        if print_only:
            return

        commands_ref.update(payload)
        print(f"Pushed {len(payload)} command(s) to {config.firebase_commands_path} starting at seq {start_seq}")
    finally:
        firebase_admin.delete_app(app)


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()
    config_path = Path(args.config).expanduser().resolve()
    if args.mode == "daemon":
        _run_daemon(config_path)
        return
    if args.mode == "push-test":
        _run_push_test(config_path, args.preset, args.text, args.start_seq, args.print_only)
        return
    if not config_path.exists():
        AppConfig().resolved(config_path.parent).save(config_path)
    from .gui import run_gui

    run_gui(config_path)


if __name__ == "__main__":
    main()
