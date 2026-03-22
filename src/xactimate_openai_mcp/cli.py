from __future__ import annotations

import argparse

from .server import create_server


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Serve Xactimate tools as a remote MCP server for OpenAI.")
    parser.add_argument("serve", nargs="?", default="serve", help=argparse.SUPPRESS)
    parser.add_argument("--runtime-db", required=True, help="Path to the runtime SQLite catalog database")
    parser.add_argument("--producer-config", required=True, help="Path to the producer config JSON")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host")
    parser.add_argument("--port", type=int, default=8000, help="Bind port")
    parser.add_argument(
        "--transport",
        choices=("streamable-http", "sse"),
        default="streamable-http",
        help="MCP transport to serve",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    server = create_server(
        runtime_database_path=args.runtime_db,
        producer_config_path=args.producer_config,
        host=args.host,
        port=args.port,
    )
    server.run(args.transport)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
