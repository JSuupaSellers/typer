from __future__ import annotations

import argparse
from pathlib import Path
import time

from .config import AppConfig
from .controller import BridgeController


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Firebase to serial keystream bridge")
    parser.add_argument("--config", default="config.local.json", help="Path to the JSON config file")
    subparsers = parser.add_subparsers(dest="mode", required=False)
    subparsers.add_parser("gui", help="Run the Tkinter control panel")
    subparsers.add_parser("daemon", help="Run the bridge without a GUI")
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


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()
    config_path = Path(args.config).expanduser().resolve()
    if args.mode == "daemon":
        _run_daemon(config_path)
        return
    if not config_path.exists():
        AppConfig().resolved(config_path.parent).save(config_path)
    from .gui import run_gui

    run_gui(config_path)


if __name__ == "__main__":
    main()
