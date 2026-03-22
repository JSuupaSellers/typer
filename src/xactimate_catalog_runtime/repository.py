from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
import os
import sqlite3
import tempfile

from .models import (
    CuratedExportEnvelope,
    RecommendationCandidate,
    RecommendationQuery,
    RuntimeItem,
    RuntimeScenario,
    normalize_code,
)
from .search import RecommendationEngine, RecommendationSourceItem, SearchTokenizer


SCHEMA_STATEMENTS = [
    "PRAGMA foreign_keys=ON;",
    """
    CREATE TABLE metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE items (
        code TEXT PRIMARY KEY,
        category TEXT NOT NULL,
        selector TEXT NOT NULL,
        description TEXT NOT NULL,
        unit TEXT NOT NULL,
        details TEXT NOT NULL,
        searchable_text TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE scenarios (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item_code TEXT NOT NULL REFERENCES items(code) ON DELETE CASCADE,
        title TEXT NOT NULL,
        tags TEXT NOT NULL,
        when_to_use TEXT NOT NULL,
        when_not_to_use TEXT NOT NULL,
        room TEXT NOT NULL,
        surface TEXT NOT NULL,
        damage_type TEXT NOT NULL,
        keywords TEXT NOT NULL,
        synonyms TEXT NOT NULL,
        voice_notes TEXT NOT NULL,
        ai_hint TEXT NOT NULL,
        searchable_text TEXT NOT NULL
    )
    """,
    "CREATE INDEX scenarios_item_code_idx ON scenarios(item_code)",
    "CREATE INDEX scenarios_room_idx ON scenarios(room)",
    "CREATE INDEX scenarios_surface_idx ON scenarios(surface)",
    "CREATE INDEX scenarios_damage_type_idx ON scenarios(damage_type)",
    """
    CREATE VIRTUAL TABLE item_fts USING fts5(
        code UNINDEXED,
        searchable_text,
        tokenize = 'porter unicode61'
    )
    """,
    """
    CREATE VIRTUAL TABLE scenario_fts USING fts5(
        item_code UNINDEXED,
        searchable_text,
        tokenize = 'porter unicode61'
    )
    """,
]


def build_runtime_database(export_path: str | Path, database_path: str | Path) -> Path:
    export = CuratedExportEnvelope.from_json_path(export_path)
    target_path = Path(database_path)
    target_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.NamedTemporaryFile(prefix=target_path.stem, suffix=".sqlite", dir=target_path.parent, delete=False) as handle:
        temp_path = Path(handle.name)

    try:
        connection = sqlite3.connect(temp_path)
        try:
            _initialize_schema(connection)
            _load_export(connection, export)
        finally:
            connection.close()
        os.replace(temp_path, target_path)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise

    return target_path


class RuntimeCatalogRepository:
    def __init__(self, database_path: str | Path):
        self.database_path = Path(database_path)
        if not self.database_path.exists():
            raise FileNotFoundError(f"Runtime catalog database not found: {self.database_path}")

    def health(self) -> dict[str, int | str]:
        with self._connect() as connection:
            item_count = connection.execute("SELECT COUNT(*) FROM items").fetchone()[0]
            scenario_count = connection.execute("SELECT COUNT(*) FROM scenarios").fetchone()[0]
        return {
            "database_path": str(self.database_path),
            "item_count": int(item_count),
            "scenario_count": int(scenario_count),
        }

    def get_item(self, code: str) -> RuntimeItem | None:
        normalized = normalize_code(code)
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT code, category, selector, description, unit, details
                FROM items
                WHERE code = ?
                """,
                (normalized,),
            ).fetchone()
        return self._row_to_item(row) if row else None

    def get_item_with_scenarios(self, code: str) -> dict[str, object] | None:
        item = self.get_item(code)
        if item is None:
            return None
        scenarios = self.get_scenarios(code)
        return {"item": item, "scenarios": scenarios}

    def get_scenarios(self, code: str) -> list[RuntimeScenario]:
        normalized = normalize_code(code)
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT id, item_code, title, tags, when_to_use, when_not_to_use, room, surface,
                       damage_type, keywords, synonyms, voice_notes, ai_hint
                FROM scenarios
                WHERE item_code = ?
                ORDER BY id ASC
                """,
                (normalized,),
            ).fetchall()
        return [self._row_to_scenario(row) for row in rows]

    def search(self, query: RecommendationQuery) -> list[RecommendationCandidate]:
        sources = self._load_sources(query)
        return RecommendationEngine().recommend(query, sources)

    def _load_sources(self, query: RecommendationQuery) -> list[RecommendationSourceItem]:
        candidate_codes = self._candidate_codes(query)
        if not candidate_codes:
            return []

        placeholders = ", ".join("?" for _ in candidate_codes)
        with self._connect() as connection:
            item_rows = connection.execute(
                f"""
                SELECT code, category, selector, description, unit, details
                FROM items
                WHERE code IN ({placeholders})
                """,
                tuple(candidate_codes),
            ).fetchall()

            scenario_rows = connection.execute(
                f"""
                SELECT id, item_code, title, tags, when_to_use, when_not_to_use, room, surface,
                       damage_type, keywords, synonyms, voice_notes, ai_hint
                FROM scenarios
                WHERE item_code IN ({placeholders})
                ORDER BY id ASC
                """,
                tuple(candidate_codes),
            ).fetchall()

        items_by_code = {row["code"]: self._row_to_item(row) for row in item_rows}
        scenarios_by_code: dict[str, list[RuntimeScenario]] = {code: [] for code in candidate_codes}
        for row in scenario_rows:
            scenario = self._row_to_scenario(row)
            scenarios_by_code.setdefault(scenario.item_code, []).append(scenario)

        return [
            RecommendationSourceItem(
                item=items_by_code[code],
                scenarios=tuple(scenarios_by_code.get(code, [])),
            )
            for code in candidate_codes
            if code in items_by_code
        ]

    def _candidate_codes(self, query: RecommendationQuery) -> list[str]:
        tokens = SearchTokenizer.tokenize(query.combined_text)
        with self._connect() as connection:
            if not tokens:
                rows = connection.execute("SELECT code FROM items ORDER BY code ASC").fetchall()
                return [row["code"] for row in rows]

            candidate_codes: list[str] = []
            seen: set[str] = set()

            normalized_query = normalize_code(query.query)
            if "/" in normalized_query:
                exact_row = connection.execute("SELECT code FROM items WHERE code = ?", (normalized_query,)).fetchone()
                if exact_row:
                    candidate_codes.append(exact_row["code"])
                    seen.add(exact_row["code"])

            fts_query = _build_fts_query(tokens)
            if fts_query:
                item_rows = connection.execute(
                    """
                    SELECT code
                    FROM item_fts
                    WHERE item_fts MATCH ?
                    LIMIT 80
                    """,
                    (fts_query,),
                ).fetchall()
                for row in item_rows:
                    if row["code"] not in seen:
                        candidate_codes.append(row["code"])
                        seen.add(row["code"])

                scenario_rows = connection.execute(
                    """
                    SELECT DISTINCT item_code
                    FROM scenario_fts
                    WHERE scenario_fts MATCH ?
                    LIMIT 120
                    """,
                    (fts_query,),
                ).fetchall()
                for row in scenario_rows:
                    if row["item_code"] not in seen:
                        candidate_codes.append(row["item_code"])
                        seen.add(row["item_code"])

            if candidate_codes:
                return candidate_codes

            rows = connection.execute("SELECT code FROM items ORDER BY code ASC LIMIT 120").fetchall()
            return [row["code"] for row in rows]

    @contextmanager
    def _connect(self):
        connection = sqlite3.connect(self.database_path)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
        finally:
            connection.close()

    @staticmethod
    def _row_to_item(row: sqlite3.Row) -> RuntimeItem:
        return RuntimeItem(
            code=row["code"],
            category=row["category"],
            selector=row["selector"],
            description=row["description"],
            unit=row["unit"],
            details=row["details"],
        )

    @staticmethod
    def _row_to_scenario(row: sqlite3.Row) -> RuntimeScenario:
        return RuntimeScenario(
            id=row["id"],
            item_code=row["item_code"],
            title=row["title"],
            tags=row["tags"],
            when_to_use=row["when_to_use"],
            when_not_to_use=row["when_not_to_use"],
            room=row["room"],
            surface=row["surface"],
            damage_type=row["damage_type"],
            keywords=row["keywords"],
            synonyms=row["synonyms"],
            voice_notes=row["voice_notes"],
            ai_hint=row["ai_hint"],
        )


def _initialize_schema(connection: sqlite3.Connection) -> None:
    with connection:
        for statement in SCHEMA_STATEMENTS:
            connection.execute(statement)


def _load_export(connection: sqlite3.Connection, export: CuratedExportEnvelope) -> None:
    with connection:
        connection.executemany(
            "INSERT INTO metadata (key, value) VALUES (?, ?)",
            [
                ("exported_at", export.exported_at),
                ("item_count", str(export.item_count)),
                ("usage_note_count", str(export.usage_note_count)),
            ],
        )

        item_rows = []
        item_fts_rows = []
        scenario_rows = []
        scenario_fts_rows = []

        for item in export.items:
            searchable_item_text = " ".join(
                part for part in [item.code, item.category, item.selector, item.description, item.unit, item.details] if part
            )
            item_rows.append(
                (
                    item.code,
                    item.category,
                    item.selector,
                    item.description,
                    item.unit,
                    item.details,
                    searchable_item_text,
                )
            )
            item_fts_rows.append((item.code, searchable_item_text))

            for note in item.usage_notes:
                searchable_scenario_text = " ".join(
                    part
                    for part in [
                        note.title,
                        note.tags,
                        note.when_to_use,
                        note.when_not_to_use,
                        note.room,
                        note.surface,
                        note.damage_type,
                        note.keywords,
                        note.synonyms,
                        note.voice_notes,
                        note.ai_hint,
                    ]
                    if part
                )
                scenario_rows.append(
                    (
                        item.code,
                        note.title,
                        note.tags,
                        note.when_to_use,
                        note.when_not_to_use,
                        note.room,
                        note.surface,
                        note.damage_type,
                        note.keywords,
                        note.synonyms,
                        note.voice_notes,
                        note.ai_hint,
                        searchable_scenario_text,
                    )
                )
                scenario_fts_rows.append((item.code, searchable_scenario_text))

        connection.executemany(
            """
            INSERT INTO items (code, category, selector, description, unit, details, searchable_text)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            item_rows,
        )
        connection.executemany(
            "INSERT INTO item_fts (code, searchable_text) VALUES (?, ?)",
            item_fts_rows,
        )
        connection.executemany(
            """
            INSERT INTO scenarios (
                item_code, title, tags, when_to_use, when_not_to_use, room, surface,
                damage_type, keywords, synonyms, voice_notes, ai_hint, searchable_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            scenario_rows,
        )
        connection.executemany(
            "INSERT INTO scenario_fts (item_code, searchable_text) VALUES (?, ?)",
            scenario_fts_rows,
        )


def _build_fts_query(tokens: set[str]) -> str:
    cleaned = [token for token in sorted(tokens) if token]
    return " OR ".join(f"{token}*" for token in cleaned)
