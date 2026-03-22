from __future__ import annotations

import argparse
from pathlib import Path

import uvicorn

from .api import create_app
from .models import RecommendationQuery
from .repository import RuntimeCatalogRepository, build_runtime_database


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Runtime search API for curated Xactimate exports.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    import_parser = subparsers.add_parser("import", help="Import a curator JSON export into the runtime SQLite database.")
    import_parser.add_argument("--export", required=True, help="Path to xactimate-curated-export.json")
    import_parser.add_argument("--db", required=True, help="Path to the runtime SQLite database to build")

    serve_parser = subparsers.add_parser("serve", help="Serve the runtime API from a runtime SQLite database.")
    serve_parser.add_argument("--db", required=True, help="Path to the runtime SQLite database")
    serve_parser.add_argument("--host", default="127.0.0.1", help="Bind host")
    serve_parser.add_argument("--port", type=int, default=8787, help="Bind port")
    serve_parser.add_argument("--api-key", default="", help="Optional X-API-Key requirement")

    search_parser = subparsers.add_parser("search", help="Run a recommendation query directly against the runtime database.")
    search_parser.add_argument("--db", required=True, help="Path to the runtime SQLite database")
    search_parser.add_argument("--query", default="", help="Freeform room/scope text")
    search_parser.add_argument("--room", default="", help="Room or area filter")
    search_parser.add_argument("--surface", default="", help="Surface filter")
    search_parser.add_argument("--damage-type", default="", help="Damage type filter")
    search_parser.add_argument("--keywords", default="", help="Comma-separated keywords")
    search_parser.add_argument("--limit", type=int, default=5, help="Number of results to return")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "import":
        database_path = build_runtime_database(args.export, args.db)
        print(f"Built runtime database at {database_path}")
        return 0

    if args.command == "serve":
        app = create_app(args.db, api_key=args.api_key or None)
        uvicorn.run(app, host=args.host, port=args.port)
        return 0

    if args.command == "search":
        repo = RuntimeCatalogRepository(args.db)
        results = repo.search(
            RecommendationQuery(
                query=args.query,
                room=args.room,
                surface=args.surface,
                damage_type=args.damage_type,
                keywords=args.keywords,
                limit=args.limit,
            )
        )
        for candidate in results:
            print(f"{candidate.item.code} [{candidate.confidence}] score={candidate.score:.2f}")
            print(f"  {candidate.item.description}")
            for reason in candidate.reasons:
                print(f"  - {reason}")
        return 0

    parser.error(f"Unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
