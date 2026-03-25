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
    "itemCount": 5,
    "usageNoteCount": 2,
    "items": [
        {
            "code": "DRY/PCH",
            "category": "DRY",
            "selector": "PCH",
            "description": "Drywall patch 2x2",
            "unit": "EA",
            "details": "Patch small ceiling opening and prep for finish.",
            "usageStatus": "used_before",
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
            "usageStatus": "used_before",
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
            "usageStatus": "unreviewed",
            "usageNotes": [],
        },
        {
            "code": "CLN/WAL",
            "category": "CLN",
            "selector": "WAL",
            "description": "Clean finished wall surface",
            "unit": "SF",
            "details": "Clean interior painted wall surface with general cleaning chemistry.",
            "usageStatus": "unreviewed",
            "usageNotes": [],
        },
        {
            "code": "CLN/ACW",
            "category": "CLN",
            "selector": "ACW",
            "description": "Clean window-mount/through-wall AC unit",
            "unit": "EA",
            "details": "Clean through-wall AC unit including cover and accessible components.",
            "usageStatus": "unreviewed",
            "usageNotes": [],
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
        self.assertEqual(health["item_count"], 5)
        self.assertEqual(health["scenario_count"], 2)

        item_detail = repo.get_item_with_scenarios("dry/pch")
        self.assertIsNotNone(item_detail)
        self.assertEqual(item_detail["item"].code, "DRY/PCH")
        self.assertEqual(item_detail["item"].usage_status, "used_before")
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

        wall_results = repo.search(
            RecommendationQuery(
                query="bedroom wall repaint",
                room="Bedroom",
                surface="Wall",
                damage_type="Paint",
                keywords="paint wall",
                limit=5,
            )
        )
        self.assertGreaterEqual(len(wall_results), 1)
        self.assertIn("PNT/WL", [candidate.item.code for candidate in wall_results])

        clean_wall_results = repo.search(
            RecommendationQuery(
                query="clean walls",
                room="Bedroom",
                surface="Wall",
                damage_type="Clean",
                keywords="wall clean",
                limit=5,
            )
        )
        self.assertGreaterEqual(len(clean_wall_results), 1)
        self.assertEqual(clean_wall_results[0].item.code, "CLN/WAL")
        ranked_codes = [candidate.item.code for candidate in clean_wall_results]
        self.assertLess(ranked_codes.index("CLN/WAL"), ranked_codes.index("CLN/ACW"))

    def test_api_endpoints(self) -> None:
        client = TestClient(create_app(self.db_path, api_key="secret-key"))

        unauthorized = client.get("/health")
        self.assertEqual(unauthorized.status_code, 401)

        health = client.get("/health", headers={"X-API-Key": "secret-key"})
        self.assertEqual(health.status_code, 200)
        self.assertEqual(health.json()["item_count"], 5)

        item = client.get("/items/DRY/PCH", headers={"X-API-Key": "secret-key"})
        self.assertEqual(item.status_code, 200)
        self.assertEqual(item.json()["item"]["code"], "DRY/PCH")
        self.assertEqual(item.json()["item"]["usage_status"], "used_before")

        scenarios = client.get("/items/DRY/PCH/scenarios", headers={"X-API-Key": "secret-key"})
        self.assertEqual(scenarios.status_code, 200)
        self.assertEqual(len(scenarios.json()), 1)
        self.assertEqual(scenarios.json()[0]["item_code"], "DRY/PCH")
        self.assertNotIn("voice_notes", scenarios.json()[0])

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
