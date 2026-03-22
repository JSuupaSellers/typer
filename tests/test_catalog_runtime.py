from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from fastapi.testclient import TestClient

from xactimate_catalog_runtime.api import create_app
from xactimate_catalog_runtime.models import RecommendationQuery
from xactimate_catalog_runtime.repository import RuntimeCatalogRepository, build_runtime_database


SAMPLE_EXPORT = {
    "exportedAt": "2026-03-22T12:00:00Z",
    "itemCount": 3,
    "usageNoteCount": 3,
    "items": [
        {
            "code": "DRY/PCH",
            "category": "DRY",
            "selector": "PCH",
            "description": "Drywall patch 2x2",
            "unit": "EA",
            "details": "Patch small ceiling opening and prep for finish.",
            "usageNotes": [
                {
                    "title": "Ceiling patch before paint",
                    "tags": "ceiling,drywall,patch",
                    "whenToUse": "Use for a 2x2 ceiling opening or picture-framed drywall repair before paint.",
                    "whenNotToUse": "Not for full drywall replacement.",
                    "room": "Living room",
                    "surface": "Ceiling",
                    "damageType": "Patch",
                    "keywords": "2x2 patch,picture frame,small opening",
                    "synonyms": "ceiling patch,picture frame repair",
                    "voiceNotes": "Use for a localized ceiling cutout repair.",
                    "aiHint": "Prefer this when the scope is a localized ceiling patch.",
                }
            ],
        },
        {
            "code": "PNT/SP",
            "category": "PNT",
            "selector": "SP",
            "description": "Paint ceiling",
            "unit": "SF",
            "details": "Paint and blend ceiling after repair.",
            "usageNotes": [
                {
                    "title": "Ceiling repaint after repair",
                    "tags": "ceiling,paint",
                    "whenToUse": "Use after the ceiling patch is complete and the repair needs paint or blend work.",
                    "whenNotToUse": "Not for wall-only paint work.",
                    "room": "Living room",
                    "surface": "Ceiling",
                    "damageType": "Paint after patch",
                    "keywords": "paint ceiling,blend paint",
                    "synonyms": "ceiling repaint,ceiling touch-up",
                    "voiceNotes": "Often follows drywall patch work.",
                    "aiHint": "Pair with a patch item when the scope includes both repair and repaint.",
                }
            ],
        },
        {
            "code": "PNT/WL",
            "category": "PNT",
            "selector": "WL",
            "description": "Paint wall",
            "unit": "SF",
            "details": "Paint an interior wall surface.",
            "usageNotes": [
                {
                    "title": "Wall repaint",
                    "tags": "wall,paint",
                    "whenToUse": "Use for interior wall repaint scope.",
                    "whenNotToUse": "Not for ceiling work.",
                    "room": "Bedroom",
                    "surface": "Wall",
                    "damageType": "Paint",
                    "keywords": "paint wall,wall repaint",
                    "synonyms": "wall touch-up",
                    "voiceNotes": "Wall paint only.",
                    "aiHint": "Use when the damaged surface is a wall, not a ceiling.",
                }
            ],
        },
    ],
}


class CatalogRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.export_path = Path(self.temp_dir.name) / "xactimate-curated-export.json"
        self.db_path = Path(self.temp_dir.name) / "runtime.sqlite"
        self.export_path.write_text(json.dumps(SAMPLE_EXPORT), encoding="utf-8")
        build_runtime_database(self.export_path, self.db_path)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_import_and_recommendation_ranking(self) -> None:
        repo = RuntimeCatalogRepository(self.db_path)
        health = repo.health()
        self.assertEqual(health["item_count"], 3)
        self.assertEqual(health["scenario_count"], 3)

        item_detail = repo.get_item_with_scenarios("dry/pch")
        self.assertIsNotNone(item_detail)
        self.assertEqual(item_detail["item"].code, "DRY/PCH")
        self.assertEqual(len(item_detail["scenarios"]), 1)

        results = repo.search(
            RecommendationQuery(
                query="2x2 ceiling patch that needs picture frame and then ceiling painted",
                room="Living room",
                surface="Ceiling",
                damage_type="Patch",
                keywords="picture frame",
                limit=5,
            )
        )
        self.assertGreaterEqual(len(results), 2)
        self.assertEqual(results[0].item.code, "DRY/PCH")
        self.assertIn("PNT/SP", [candidate.item.code for candidate in results])

    def test_api_endpoints(self) -> None:
        client = TestClient(create_app(self.db_path, api_key="secret-key"))

        unauthorized = client.get("/health")
        self.assertEqual(unauthorized.status_code, 401)

        health = client.get("/health", headers={"X-API-Key": "secret-key"})
        self.assertEqual(health.status_code, 200)
        self.assertEqual(health.json()["item_count"], 3)

        item = client.get("/items/DRY/PCH", headers={"X-API-Key": "secret-key"})
        self.assertEqual(item.status_code, 200)
        self.assertEqual(item.json()["item"]["code"], "DRY/PCH")

        scenarios = client.get("/items/DRY/PCH/scenarios", headers={"X-API-Key": "secret-key"})
        self.assertEqual(scenarios.status_code, 200)
        self.assertEqual(len(scenarios.json()), 1)
        self.assertEqual(scenarios.json()[0]["item_code"], "DRY/PCH")

        recommend = client.post(
            "/recommend",
            headers={"X-API-Key": "secret-key"},
            json={
                "query": "2x2 ceiling patch that needs picture frame and then ceiling painted",
                "room": "Living room",
                "surface": "Ceiling",
                "damage_type": "Patch",
                "keywords": "picture frame",
                "limit": 5,
            },
        )
        self.assertEqual(recommend.status_code, 200)
        payload = recommend.json()
        self.assertEqual(payload[0]["item"]["code"], "DRY/PCH")
        self.assertEqual(payload[0]["confidence"], "high")

    def test_cli_main_search(self) -> None:
        from io import StringIO
        from unittest.mock import patch

        from xactimate_catalog_runtime.cli import main

        with patch("sys.stdout", new_callable=StringIO) as stdout:
            exit_code = main(
                [
                    "search",
                    "--db",
                    str(self.db_path),
                    "--query",
                    "ceiling patch with picture frame",
                    "--room",
                    "Living room",
                    "--surface",
                    "Ceiling",
                    "--damage-type",
                    "Patch",
                ]
            )

        self.assertEqual(exit_code, 0)
        self.assertIn("DRY/PCH", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
