from __future__ import annotations

import asyncio
import json
from pathlib import Path
import tempfile
import unittest

from xactimate_catalog_runtime.repository import build_runtime_database
from xactimate_openai_mcp.server import create_server


SAMPLE_EXPORT = {
    "exportedAt": "2026-03-22T12:00:00Z",
    "itemCount": 2,
    "usageNoteCount": 2,
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
    ],
}


class OpenAIMCPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.export_path = Path(self.temp_dir.name) / "xactimate-curated-export.json"
        self.runtime_db = Path(self.temp_dir.name) / "runtime.sqlite"
        self.producer_config = Path(self.temp_dir.name) / "producer.local.json"

        self.export_path.write_text(json.dumps(SAMPLE_EXPORT), encoding="utf-8")
        build_runtime_database(self.export_path, self.runtime_db)
        self.producer_config.write_text(
            json.dumps(
                {
                    "runtime_api_base_url": "http://unused.local",
                    "firebase_commands_path_template": "/bridges/{bridge_id}/commands",
                    "firebase_state_path_template": "/bridges/{bridge_id}/state",
                }
            ),
            encoding="utf-8",
        )
        self.server = create_server(self.runtime_db, self.producer_config)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_server_exposes_expected_tool_names(self) -> None:
        tool_names = {tool.name for tool in asyncio.run(self.server.list_tools())}
        self.assertEqual(
            tool_names,
            {
                "search_line_items",
                "get_line_item",
                "plan_estimate_job",
                "compile_estimate_job",
                "publish_estimate_job",
            },
        )

    def test_search_and_compile_tools_return_structured_payloads(self) -> None:
        async def run() -> None:
            search_result = await self.server.call_tool(
                "search_line_items",
                {
                    "query": "2x2 ceiling patch that needs picture frame and then ceiling painted",
                    "room": "Living room",
                    "surface": "Ceiling",
                    "damage_type": "Patch",
                    "keywords": "picture frame",
                },
            )
            self.assertEqual(search_result[1]["status"], "ok")
            self.assertEqual(search_result[1]["payload"]["candidates"][0]["item"]["code"], "DRY/PCH")

            compile_result = await self.server.call_tool(
                "compile_estimate_job",
                {
                    "job": {
                        "job_id": "claim-123",
                        "bridge_id": "default",
                        "items": [
                            {
                                "item_id": "scope-1",
                                "description": "2x2 ceiling patch that needs picture frame and then ceiling painted",
                                "room": "Living room",
                                "surface": "Ceiling",
                                "damage_type": "Patch",
                                "keywords": "picture frame",
                                "quantity": 1,
                            },
                            {
                                "item_id": "scope-2",
                                "description": "Paint the ceiling after the patch is complete",
                                "room": "Living room",
                                "surface": "Ceiling",
                                "damage_type": "Paint after patch",
                                "keywords": "ceiling paint",
                                "quantity": 120,
                            },
                        ],
                    },
                    "starting_seq": 50,
                },
            )
            self.assertEqual(compile_result[1]["status"], "ok")
            self.assertEqual(compile_result[1]["payload"]["starting_seq"], 50)
            self.assertEqual(compile_result[1]["payload"]["commands"][1]["text"], "DRY/PCH")

            publish_result = await self.server.call_tool(
                "publish_estimate_job",
                {
                    "job": {
                        "job_id": "claim-123",
                        "bridge_id": "default",
                        "items": [
                            {
                                "item_id": "scope-1",
                                "description": "2x2 ceiling patch that needs picture frame and then ceiling painted",
                                "room": "Living room",
                                "surface": "Ceiling",
                                "damage_type": "Patch",
                                "keywords": "picture frame",
                                "quantity": 1,
                            }
                        ],
                    },
                    "confirm_publish": False,
                },
            )
            self.assertEqual(publish_result[1]["status"], "confirmation_required")

        asyncio.run(run())
