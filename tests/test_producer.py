from __future__ import annotations

import asyncio
import tempfile
import unittest

from fastapi.testclient import TestClient

from xactimate_producer.api import create_app
from xactimate_producer.config import ProducerConfig
from xactimate_producer.drafts import DraftCoordinator, DraftLineItem, DraftStore, EstimateDraft
from xactimate_producer.direct_output import DirectComposeResult, DirectOutputService
from xactimate_producer.models import (
    CatalogLineItem,
    EstimateJob,
    PublishResult,
    QueueSnapshot,
    RecommendationCandidate,
)
from xactimate_producer.openai_agent import OpenAIDraftAgent
from xactimate_producer.policy import PolicyEngine
from xactimate_producer.service import ProducerReviewRequiredError, ProducerService


def _candidate(item: CatalogLineItem, confidence: str, score: float, reason: str) -> RecommendationCandidate:
    return RecommendationCandidate(
        item=item,
        score=score,
        confidence=confidence,
        matched_terms=(item.code,),
        reasons=(reason,),
        highlights=(),
    )


class FakeRuntimeClient:
    def __init__(self, *, low_confidence_patch: bool = False) -> None:
        self.patch_item = CatalogLineItem(
            code="DRY/PCH",
            category="DRY",
            selector="PCH",
            description="Drywall patch 2x2",
            unit="EA",
            details="Patch a small ceiling opening before finish work.",
        )
        self.paint_item = CatalogLineItem(
            code="PNT/SP",
            category="PNT",
            selector="SP",
            description="Paint ceiling",
            unit="SF",
            details="Paint and blend the ceiling after repair.",
        )
        patch_confidence = "medium" if low_confidence_patch else "high"
        patch_score = 31.0 if low_confidence_patch else 54.0
        self.recommendations = {
            "scope-1": [
                _candidate(self.patch_item, patch_confidence, patch_score, "Patch playbook matched the ceiling repair scope."),
                _candidate(self.paint_item, "medium", 25.0, "Ceiling paint is often paired with a patch."),
            ],
            "scope-2": [
                _candidate(self.paint_item, "high", 47.0, "Paint playbook matched the ceiling repaint scope."),
            ],
        }
        self.recommendations_by_query = {
            "drywall patch 2x2": [
                _candidate(self.patch_item, patch_confidence, patch_score, "Patch playbook matched the ceiling repair scope."),
                _candidate(self.paint_item, "medium", 25.0, "Ceiling paint is often paired with a patch."),
            ],
            "paint ceiling": [
                _candidate(self.paint_item, "high", 47.0, "Paint playbook matched the ceiling repaint scope."),
            ],
            "ceiling paint": [
                _candidate(self.paint_item, "high", 46.0, "Generic ceiling paint search surfaced the right workflow."),
            ],
            "drywall repair": [
                _candidate(self.patch_item, "medium", 40.0, "Broader drywall repair phrasing still found the patch item."),
            ],
        }
        self.items_by_code = {
            self.patch_item.code: self.patch_item,
            self.paint_item.code: self.paint_item,
        }

    def recommend_for_item(self, scope_item, limit: int):
        candidates = self.recommendations.get(scope_item.item_id)
        if candidates is None:
            candidates = self.recommendations_by_query.get(scope_item.description.strip().lower(), [])
        return list(candidates)[:limit]

    def explore_strategies(self, scope_item, strategies, default_limit: int):
        strategy_results = []
        combined: dict[str, RecommendationCandidate] = {}

        for index, strategy in enumerate(strategies, start=1):
            query = (strategy.get("query") or scope_item.description).strip()
            strategy_scope = type(scope_item)(
                item_id=f"{scope_item.item_id}-strategy-{index}",
                description=query,
                room=(strategy.get("room") or scope_item.room).strip(),
                section=(strategy.get("section") or scope_item.section).strip(),
                surface=(strategy.get("surface") or scope_item.surface).strip(),
                damage_type=(strategy.get("damage_type") or scope_item.damage_type).strip(),
                keywords=(strategy.get("keywords") or scope_item.keywords).strip(),
            )
            limit = int(strategy.get("limit") or default_limit)
            candidates = self.recommend_for_item(strategy_scope, limit)
            strategy_results.append(
                {
                    "name": strategy.get("name", f"strategy_{index}"),
                    "search_request": {
                        "query": strategy_scope.description,
                        "room": strategy_scope.room,
                        "section": strategy_scope.section,
                        "surface": strategy_scope.surface,
                        "damage_type": strategy_scope.damage_type,
                        "keywords": strategy_scope.keywords,
                        "limit": limit,
                    },
                    "candidates": [candidate.to_dict() for candidate in candidates],
                }
            )
            for candidate in candidates:
                combined.setdefault(candidate.item.code, candidate)

        return {
            "base_search_request": {
                "query": scope_item.description,
                "room": scope_item.room,
                "section": scope_item.section,
                "surface": scope_item.surface,
                "damage_type": scope_item.damage_type,
                "keywords": scope_item.keywords,
                "limit": default_limit,
            },
            "strategy_results": strategy_results,
            "combined_candidates": [candidate.to_dict() for candidate in combined.values()],
            "overlap_codes": [],
        }

    def get_item(self, code: str) -> CatalogLineItem:
        normalized = code.strip().upper()
        if normalized not in self.items_by_code:
            raise KeyError(normalized)
        return self.items_by_code[normalized]


class FakePublisher:
    def __init__(
        self,
        *,
        last_applied_seq: int = 0,
        max_published_seq: int = 0,
        last_reserved_seq: int = 0,
        pending_command_count: int | None = None,
        bridge_online: bool = True,
        bridge_ready: bool | None = None,
    ) -> None:
        derived_pending = max((max_published_seq if pending_command_count is None else last_applied_seq + pending_command_count) - last_applied_seq, 0)
        self.snapshot_value = QueueSnapshot(
            bridge_id="default",
            last_applied_seq=last_applied_seq,
            max_published_seq=max_published_seq,
            last_reserved_seq=last_reserved_seq,
            pending_command_count=derived_pending,
            bridge_online=bridge_online,
            bridge_ready=bridge_online if bridge_ready is None else bridge_ready,
            bridge_last_seen_unix_s=1.0,
            next_seq=max(last_applied_seq, max_published_seq, last_reserved_seq) + 1,
            commands_path="/bridges/default/commands",
            state_path="/bridges/default/state",
        )
        self.last_reserved_start = 0
        self.published_job = None

    def snapshot(self, bridge_id: str) -> QueueSnapshot:
        return QueueSnapshot(
            bridge_id=bridge_id,
            last_applied_seq=self.snapshot_value.last_applied_seq,
            max_published_seq=self.snapshot_value.max_published_seq,
            last_reserved_seq=self.snapshot_value.last_reserved_seq,
            pending_command_count=self.snapshot_value.pending_command_count,
            bridge_online=self.snapshot_value.bridge_online,
            bridge_ready=self.snapshot_value.bridge_ready,
            bridge_last_seen_unix_s=self.snapshot_value.bridge_last_seen_unix_s,
            next_seq=max(
                self.snapshot_value.last_applied_seq,
                self.snapshot_value.max_published_seq,
                self.snapshot_value.last_reserved_seq,
            )
            + 1,
            commands_path=f"/bridges/{bridge_id}/commands",
            state_path=f"/bridges/{bridge_id}/state",
        )

    def reserve_sequence_range(self, bridge_id: str, job_id: str, command_count: int, floor_seq: int) -> int:
        self.last_reserved_start = max(self.snapshot_value.last_reserved_seq + 1, floor_seq + 1)
        self.snapshot_value = QueueSnapshot(
            bridge_id=bridge_id,
            last_applied_seq=self.snapshot_value.last_applied_seq,
            max_published_seq=max(self.snapshot_value.max_published_seq, self.last_reserved_start + command_count - 1),
            last_reserved_seq=self.last_reserved_start + command_count - 1,
            pending_command_count=max(
                self.snapshot_value.pending_command_count,
                (self.last_reserved_start + command_count - 1) - self.snapshot_value.last_applied_seq,
            ),
            bridge_online=self.snapshot_value.bridge_online,
            bridge_ready=False,
            bridge_last_seen_unix_s=self.snapshot_value.bridge_last_seen_unix_s,
            next_seq=self.last_reserved_start + command_count,
            commands_path=f"/bridges/{bridge_id}/commands",
            state_path=f"/bridges/{bridge_id}/state",
        )
        return self.last_reserved_start

    def publish(self, compiled_job) -> PublishResult:
        self.published_job = compiled_job
        return PublishResult(
            job_id=compiled_job.job_id,
            bridge_id=compiled_job.bridge_id,
            command_count=compiled_job.command_count,
            starting_seq=compiled_job.starting_seq,
            ending_seq=compiled_job.ending_seq,
            commands_path=f"/bridges/{compiled_job.bridge_id}/commands",
            state_path=f"/bridges/{compiled_job.bridge_id}/state",
            approved_codes=tuple(
                item.approved_candidate.item.code
                for item in compiled_job.plan.items
                if item.approved_candidate is not None
            ),
        )

    def publish_commands(self, *, bridge_id: str, job_id: str, commands, approved_codes=()) -> PublishResult:
        rebased = tuple(command.rebased(self.snapshot(bridge_id).next_seq + index) for index, command in enumerate(commands))
        self.published_job = rebased
        return PublishResult(
            job_id=job_id,
            bridge_id=bridge_id,
            command_count=len(rebased),
            starting_seq=rebased[0].seq,
            ending_seq=rebased[-1].seq,
            commands_path=f"/bridges/{bridge_id}/commands",
            state_path=f"/bridges/{bridge_id}/state",
            approved_codes=tuple(approved_codes),
        )


class FakeTranscriptionService:
    async def transcribe_audio(self, filename: str, content: bytes, prompt: str = "") -> str:
        return f"Transcript for {filename} ({len(content)} bytes)"


class FailingAgent:
    async def apply_turn(self, draft: EstimateDraft, user_text: str):
        raise RuntimeError("Draft agent failed upstream.")


class FakeDirectOutputService:
    async def compose(self, *, prompt: str, bridge_id: str = "default", transcript: str = "") -> DirectComposeResult:
        source = transcript.strip() or prompt.strip()
        return DirectComposeResult(
            bridge_id=bridge_id,
            title="Direct Draft",
            assistant_reply="Ready to type on the Pi.",
            prompt=prompt.strip(),
            transcript=transcript.strip(),
            text=f"Typed: {source}",
            send_enter=False,
            command_count_preview=2,
            character_count=len(f"Typed: {source}"),
            line_count=1,
            warnings=(),
        )

    def publish_text(self, *, bridge_id: str, text: str, title: str = "", append_enter: bool = False):
        publisher = FakePublisher()
        publish = publisher.publish_commands(
            bridge_id=bridge_id,
            job_id="direct-test",
            commands=(
                type("FakeCommand", (), {"rebased": lambda self, seq: type("Rebased", (), {"seq": seq})()})(),
            ),
        )
        return type(
            "Envelope",
            (),
            {
                "to_dict": lambda self: {
                    "publish": publish.to_dict(),
                    "title": title or "Direct Draft",
                    "text": text,
                    "send_enter": append_enter,
                    "character_count": len(text),
                    "line_count": max(text.count("\n") + 1, 1),
                }
            },
        )()


class UnstructuredResponseAgent(OpenAIDraftAgent):
    async def _create_response(self, payload):  # type: ignore[override]
        return {
            "id": "resp_fake",
            "output": [
                {
                    "type": "message",
                    "content": [
                        {
                            "type": "output_text",
                            "text": "Updated the draft.",
                        }
                    ],
                }
            ],
        }


class ProducerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.config = ProducerConfig.from_dict(
            {
                "runtime_api_base_url": "http://runtime.test",
                "producer_api_key": "producer-secret",
                "draft_storage_dir": self.tempdir.name,
            }
        )

    def _job_payload(self) -> dict:
        return {
            "job_id": "claim-1024",
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
        }

    def test_system_prompt_splits_clean_and_paint_intents(self) -> None:
        agent = OpenAIDraftAgent(self.config, FakeRuntimeClient())
        prompt = agent._system_prompt()

        self.assertIn("treat that as separate workflow intents", prompt)
        self.assertIn("Do not let a paint or seal item satisfy a requested clean step", prompt)
        self.assertIn("generic component cleaning terms", prompt)

    def test_plan_and_compile_generate_deterministic_commands(self) -> None:
        service = ProducerService(self.config, FakeRuntimeClient())
        job = EstimateJob.from_dict(self._job_payload())

        plan = service.plan_job(job)
        self.assertEqual(plan.approved_count, 2)
        self.assertEqual(plan.needs_review_count, 0)

        compiled = service.compile_job(job, starting_seq=25)
        self.assertEqual(compiled.starting_seq, 25)
        self.assertEqual(compiled.ending_seq, 38)
        self.assertEqual(compiled.command_count, 14)
        self.assertEqual(compiled.commands[0].key, "F6")
        self.assertEqual(compiled.commands[1].text, "DRY/PCH")
        self.assertEqual(compiled.commands[4].text, "1")
        self.assertEqual(compiled.commands[11].text, "120")
        self.assertEqual(compiled.commands[1].metadata["line_code"], "DRY/PCH")
        self.assertEqual(compiled.commands[1].metadata["job_id"], "claim-1024")

    def test_compile_requires_review_when_confidence_is_too_low(self) -> None:
        service = ProducerService(self.config, FakeRuntimeClient(low_confidence_patch=True))
        job = EstimateJob.from_dict(self._job_payload())

        with self.assertRaises(ProducerReviewRequiredError) as caught:
            service.compile_job(job, starting_seq=1)

        self.assertEqual(caught.exception.plan.needs_review_count, 1)
        self.assertEqual(caught.exception.plan.items[0].status, "needs_review")

    def test_publish_reserves_after_existing_queue(self) -> None:
        publisher = FakePublisher(last_applied_seq=10, max_published_seq=12, last_reserved_seq=12)
        service = ProducerService(self.config, FakeRuntimeClient(), publisher)
        job = EstimateJob.from_dict(
            {
                "job_id": "claim-1024",
                "bridge_id": "default",
                "items": [self._job_payload()["items"][0]],
            }
        )

        result = service.publish_job(job)
        self.assertEqual(result.starting_seq, 13)
        self.assertEqual(result.ending_seq, 19)
        self.assertEqual(result.command_count, 7)
        self.assertIsNotNone(publisher.published_job)
        self.assertEqual(publisher.published_job.commands[0].seq, 13)
        self.assertEqual(publisher.published_job.commands[-1].seq, 19)

    def test_draft_to_job_inserts_section_note_items(self) -> None:
        draft = EstimateDraft.create("claim-room-order", "default")
        draft = draft.add_item(
            DraftLineItem.create(
                room="Kitchen",
                section="Ceiling",
                approved_code="DRY/PCH",
                description="2x2 ceiling patch",
                quantity="1",
                surface="Ceiling",
                damage_type="Patch",
                keywords="2x2 patch",
            )
        )
        draft = draft.add_item(
            DraftLineItem.create(
                room="Kitchen",
                section="Walls",
                approved_code="PNT/SP",
                description="Paint walls",
                quantity="120",
                surface="Walls",
                damage_type="Paint",
                keywords="paint walls",
            )
        )

        job = draft.to_estimate_job()
        self.assertEqual([item.item_type for item in job.items], ["note", "line_item", "note", "line_item"])
        self.assertEqual(job.items[0].note, "Ceiling")
        self.assertEqual(job.items[1].approved_code, "DRY/PCH")
        self.assertEqual(job.items[2].note, "Walls")
        self.assertEqual(job.items[3].approved_code, "PNT/SP")

        service = ProducerService(self.config, FakeRuntimeClient())
        compiled = service.compile_job(job, starting_seq=5)
        self.assertEqual(compiled.commands[0].key, "F9")
        self.assertEqual(compiled.commands[1].text, "Ceiling")
        self.assertEqual(compiled.commands[3].key, "F6")

    def test_activity_round_trips_from_draft_to_compiler_metadata(self) -> None:
        draft = EstimateDraft.create("claim-activity", "default")
        draft = draft.add_item(
            DraftLineItem.create(
                room="Bedroom",
                section="Trim",
                approved_code="DRY/PCH",
                description="Drywall patch item carrying explicit activity",
                quantity="PF",
                activity="R",
                surface="Trim",
                damage_type="Detach and reset",
                keywords="activity roundtrip",
            )
        )

        job = draft.to_estimate_job()
        self.assertEqual(job.items[1].activity, "R")

        service = ProducerService(self.config, FakeRuntimeClient())
        compiled = service.compile_job(job, starting_seq=10)
        line_command = next(command for command in compiled.commands if command.kind == "text" and command.text == "DRY/PCH")
        self.assertEqual(line_command.metadata["line_activity"], "R")

    def test_api_endpoints(self) -> None:
        service = ProducerService(self.config, FakeRuntimeClient(), FakePublisher())
        drafts = DraftCoordinator(
            DraftStore(self.config.draft_storage_dir),
            service,
            transcription_service=FakeTranscriptionService(),
            agent=None,
        )
        client = TestClient(
            create_app(
                self.config,
                service,
                transcription_service=FakeTranscriptionService(),
                draft_coordinator=drafts,
            )
        )

        unauthorized = client.get("/health")
        self.assertEqual(unauthorized.status_code, 401)

        headers = {"X-API-Key": "producer-secret"}
        health = client.get("/health", headers=headers)
        self.assertEqual(health.status_code, 200)
        self.assertEqual(health.json()["status"], "ok")

        plan = client.post("/plan", headers=headers, json=self._job_payload())
        self.assertEqual(plan.status_code, 200)
        self.assertEqual(plan.json()["approved_count"], 2)

        compiled = client.post(
            "/compile",
            headers=headers,
            json={"job": self._job_payload(), "starting_seq": 40},
        )
        self.assertEqual(compiled.status_code, 200)
        self.assertEqual(compiled.json()["starting_seq"], 40)
        self.assertEqual(compiled.json()["commands"][1]["text"], "DRY/PCH")

        published = client.post("/publish", headers=headers, json=self._job_payload())
        self.assertEqual(published.status_code, 200)
        self.assertEqual(published.json()["starting_seq"], 1)
        self.assertEqual(published.json()["approved_codes"], ["DRY/PCH", "PNT/SP"])

        intake = client.post(
            "/capture/intake",
            headers=headers,
            data={
                "job_id": "claim-2048",
                "bridge_id": "field",
                "item_id": "scope-9",
                "room": "Kitchen",
                "surface": "Ceiling",
                "damage_type": "Patch",
                "keywords": "water spot",
                "quantity": "2",
                "description": "Visible water damage around the opening.",
            },
            files=[
                ("audio", ("note.m4a", b"audio-bytes", "audio/mp4")),
                ("photos", ("photo1.jpg", b"fake-jpeg-1", "image/jpeg")),
                ("photos", ("photo2.jpg", b"fake-jpeg-2", "image/jpeg")),
            ],
        )
        self.assertEqual(intake.status_code, 200)
        intake_payload = intake.json()
        self.assertEqual(intake_payload["transcript"], "Transcript for note.m4a (11 bytes)")
        self.assertEqual(intake_payload["photo_count"], 2)
        self.assertEqual(intake_payload["job"]["job_id"], "claim-2048")
        self.assertIn("Transcript for note.m4a", intake_payload["job"]["items"][0]["description"])

        opened = client.post(
            "/drafts/open",
            headers=headers,
            json={"job_id": "claim-chat", "bridge_id": "default"},
        )
        self.assertEqual(opened.status_code, 200)
        self.assertEqual(opened.json()["draft"]["job_id"], "claim-chat")
        self.assertEqual(opened.json()["claim_status"], "new")
        self.assertEqual(opened.json()["operations"], [])

        opened_second = client.post(
            "/drafts/open",
            headers=headers,
            json={"job_id": "claim-second", "bridge_id": "field"},
        )
        self.assertEqual(opened_second.status_code, 200)

        chat = client.post(
            "/drafts/claim-chat/chat",
            headers=headers,
            json={"text": "Living room ceiling needs patch and paint", "bridge_id": "default"},
        )
        self.assertEqual(chat.status_code, 200)
        chat_payload = chat.json()
        self.assertEqual(chat_payload["draft"]["messages"][-1]["role"], "assistant")
        self.assertEqual(chat_payload["grouped_sections"], [])

        voice_turn = client.post(
            "/drafts/claim-chat/voice-turn",
            headers=headers,
            data={"bridge_id": "default", "text": "Bedroom scope"},
            files={"audio": ("bedroom.m4a", b"voice-bytes", "audio/mp4")},
        )
        self.assertEqual(voice_turn.status_code, 200)
        self.assertIn("Transcript for bedroom.m4a", voice_turn.json()["transcript"])

        message_operation = client.post(
            "/drafts/claim-chat/messages",
            headers=headers,
            json={"text": "Add hall bathroom note", "bridge_id": "default"},
        )
        self.assertEqual(message_operation.status_code, 200)
        operation_id = message_operation.json()["operation"]["id"]
        self.assertTrue(operation_id.startswith("op-"))
        self.assertIn(message_operation.json()["operation"]["status"], {"queued", "running", "completed"})

        waited_operation = asyncio.run(drafts.wait_for_operation(operation_id, timeout_s=1.0))
        self.assertEqual(waited_operation["operation"]["status"], "completed")

        fetched_operation = client.get(f"/operations/{operation_id}", headers=headers)
        self.assertEqual(fetched_operation.status_code, 200)
        self.assertEqual(fetched_operation.json()["operation"]["status"], "completed")
        self.assertTrue(
            any(message["role"] == "assistant" for message in fetched_operation.json()["draft"]["messages"])
        )

        drafts_list = client.get("/drafts", headers=headers)
        self.assertEqual(drafts_list.status_code, 200)
        listed = drafts_list.json()["drafts"]
        self.assertEqual([entry["job_id"] for entry in listed], ["claim-chat", "claim-second"])
        self.assertEqual(listed[0]["message_count"], 6)
        self.assertEqual(listed[1]["bridge_id"], "field")

    def test_openai_strict_tool_schema_marks_optional_fields_nullable(self) -> None:
        agent = OpenAIDraftAgent(self.config, FakeRuntimeClient())

        search_tool = next(tool for tool in agent._tool_definitions() if tool["name"] == "search_line_items")
        parameters = search_tool["parameters"]
        self.assertIn("one atomic scope item", search_tool["description"])
        self.assertIn("short estimator-style search phrase", search_tool["description"])
        self.assertEqual(
            parameters["required"],
            ["query", "room", "section", "surface", "damage_type", "keywords", "limit"],
        )
        self.assertEqual(parameters["properties"]["room"]["type"], ["string", "null"])
        self.assertEqual(parameters["properties"]["limit"]["type"], ["integer", "null"])
        self.assertIn("compact 2-8 word search phrase", parameters["properties"]["query"]["description"])

        explore_tool = next(tool for tool in agent._tool_definitions() if tool["name"] == "explore_line_item_search")
        strategy_items = explore_tool["parameters"]["properties"]["strategies"]["items"]
        self.assertEqual(explore_tool["parameters"]["properties"]["strategies"]["minItems"], 2)
        self.assertEqual(explore_tool["parameters"]["properties"]["strategies"]["maxItems"], 4)
        self.assertEqual(strategy_items["properties"]["query"]["type"], ["string", "null"])
        self.assertEqual(strategy_items["properties"]["limit"]["type"], ["integer", "null"])

        defaults_tool = next(tool for tool in agent._tool_definitions() if tool["name"] == "get_estimating_defaults")
        self.assertEqual(defaults_tool["parameters"]["properties"]["topic"]["type"], ["string", "null"])
        self.assertEqual(defaults_tool["parameters"]["properties"]["room_scope"]["type"], ["boolean", "null"])
        self.assertIn("room-variable", defaults_tool["description"])
        self.assertIn("activity field", agent._system_prompt())

        response_format = agent._response_text_format()
        self.assertEqual(response_format["format"]["type"], "json_schema")
        self.assertTrue(response_format["format"]["strict"])
        self.assertEqual(response_format["format"]["schema"]["required"], ["assistant_reply", "operations"])

    def test_openai_agent_uses_stored_responses_for_tool_loops(self) -> None:
        agent = OpenAIDraftAgent(self.config, FakeRuntimeClient())

        initial_payload = {
            "model": self.config.agent_model,
            "reasoning": {"effort": self.config.agent_reasoning_effort},
            "input": [],
            "tools": agent._tool_definitions(),
            "tool_choice": "auto",
            "store": True,
            "max_output_tokens": agent._response_max_output_tokens(),
        }
        self.assertTrue(initial_payload["store"])
        self.assertEqual(initial_payload["max_output_tokens"], 60_000)

    def test_search_tool_returns_search_request_context(self) -> None:
        agent = OpenAIDraftAgent(self.config, FakeRuntimeClient())

        result = agent._run_tool(
            "search_line_items",
            {
                "query": "drywall patch 2x2",
                "room": "Living room",
                "section": "Ceiling",
                "surface": "Ceiling",
                "damage_type": "Patch",
                "keywords": "picture frame",
                "limit": 5,
            },
        )

        self.assertEqual(result["search_request"]["query"], "drywall patch 2x2")
        self.assertEqual(result["search_request"]["section"], "Ceiling")
        self.assertIn("candidates", result)

    def test_exploration_tool_returns_grouped_strategy_results(self) -> None:
        agent = OpenAIDraftAgent(self.config, FakeRuntimeClient())

        result = agent._run_tool(
            "explore_line_item_search",
            {
                "query": "ceiling repair and paint",
                "room": "Living room",
                "section": "Ceiling",
                "surface": "Ceiling",
                "damage_type": "Patch",
                "keywords": "picture frame ceiling patch",
                "limit": 4,
                "strategies": [
                    {
                        "name": "specific_patch",
                        "query": "drywall patch 2x2",
                        "room": None,
                        "section": None,
                        "surface": None,
                        "damage_type": None,
                        "keywords": None,
                        "limit": 4,
                    },
                    {
                        "name": "generic_paint",
                        "query": "paint ceiling",
                        "room": None,
                        "section": None,
                        "surface": None,
                        "damage_type": "Paint",
                        "keywords": "ceiling paint",
                        "limit": 3,
                    },
                ],
            },
        )

        self.assertEqual(result["base_search_request"]["section"], "Ceiling")
        self.assertEqual(len(result["strategy_results"]), 2)
        self.assertEqual(result["strategy_results"][0]["name"], "specific_patch")
        self.assertEqual(result["strategy_results"][0]["search_request"]["query"], "drywall patch 2x2")
        combined_codes = {candidate["item"]["code"] for candidate in result["combined_candidates"]}
        self.assertIn("DRY/PCH", combined_codes)
        self.assertIn("PNT/SP", combined_codes)

    def test_estimating_defaults_tool_returns_baseboard_room_scope_guidance(self) -> None:
        agent = OpenAIDraftAgent(self.config, FakeRuntimeClient())

        result = agent._run_tool(
            "get_estimating_defaults",
            {
                "topic": "baseboard reset",
                "component": "baseboard",
                "action": "detach and reset",
                "room_scope": True,
            },
        )

        self.assertEqual(result["variables"]["PF"], "Perimeter of Floor")
        suggested_codes = {entry.get("approved_code") for entry in result["suggestions"]}
        self.assertIn("FNC/BRS", suggested_codes)
        self.assertIn("FNC/BRS>", suggested_codes)
        self.assertIn("FNC/BR", suggested_codes)
        self.assertTrue(any(entry.get("quantity") == "PF" for entry in result["suggestions"]))

    def test_policy_engine_returns_expected_defaults_and_fallbacks(self) -> None:
        policy = PolicyEngine(self.config.policy_path)

        wall_clean = policy.default_for(component="walls", intent="clean", surface="wall", room_scope=True)
        self.assertIsNotNone(wall_clean)
        assert wall_clean is not None
        self.assertEqual(wall_clean.preferred_codes[0], "CLN/AV")
        self.assertEqual(wall_clean.quantity, "W")

        baseboard_paint = policy.default_for(component="baseboard", intent="paint", surface="baseboard", room_scope=True)
        self.assertIsNotNone(baseboard_paint)
        assert baseboard_paint is not None
        self.assertEqual(baseboard_paint.preferred_codes[0], "PNT/B2")
        self.assertEqual(baseboard_paint.quantity, "PF")

        wall_fallback = policy.fallback_for(component="wall", intent="clean", surface="wall")
        self.assertIsNotNone(wall_fallback)
        assert wall_fallback is not None
        self.assertIn("CLN/STD", wall_fallback.blocked_codes)
        self.assertIn("through wall", wall_fallback.blocked_terms)

    def test_chat_endpoint_surfaces_agent_failures(self) -> None:
        service = ProducerService(self.config, FakeRuntimeClient(), FakePublisher())
        drafts = DraftCoordinator(
            DraftStore(self.config.draft_storage_dir),
            service,
            transcription_service=FakeTranscriptionService(),
            agent=FailingAgent(),
        )
        client = TestClient(
            create_app(
                self.config,
                service,
                transcription_service=FakeTranscriptionService(),
                draft_coordinator=drafts,
            )
        )

        headers = {"X-API-Key": "producer-secret"}
        response = client.post(
            "/drafts/claim-chat/chat",
            headers=headers,
            json={"text": "Kitchen ceiling stain", "bridge_id": "default"},
        )

        self.assertEqual(response.status_code, 502)
        self.assertEqual(response.json()["detail"], "Draft agent failed upstream.")

    def test_openai_agent_rejects_unstructured_final_output(self) -> None:
        agent = UnstructuredResponseAgent(self.config, FakeRuntimeClient())
        draft = EstimateDraft.create("claim-unstructured", "default")

        with self.assertRaises(RuntimeError) as caught:
            asyncio.run(agent.apply_turn(draft, "Kitchen ceiling needs smoke cleanup and paint"))

        self.assertIn("returned unstructured output", str(caught.exception))

    def test_incomplete_reason_detects_incomplete_responses(self) -> None:
        agent = OpenAIDraftAgent(self.config, FakeRuntimeClient())

        self.assertEqual(agent._incomplete_reason({"status": "incomplete"}), "incomplete")
        self.assertEqual(
            agent._incomplete_reason({"incomplete_details": {"reason": "max_output_tokens"}}),
            "max_output_tokens",
        )

    def test_direct_output_compile_turns_multiline_text_into_individual_keystrokes(self) -> None:
        service = DirectOutputService(self.config, FakePublisher())

        commands = service.compile_text_commands(
            text="Hello there\n\nSecond paragraph",
            append_enter=True,
        )

        self.assertEqual(commands[0].kind, "upall")
        self.assertEqual(commands[1].kind, "key")
        self.assertEqual(commands[1].key, "H")
        self.assertEqual(commands[2].kind, "key")
        self.assertEqual(commands[2].key, "e")
        self.assertTrue(any(command.key == "ENTER" for command in commands if command.kind == "key"))
        self.assertEqual(commands[-1].kind, "key")
        self.assertEqual(commands[-1].key, "ENTER")

    def test_direct_output_compile_slows_long_text_with_individual_keystrokes(self) -> None:
        service = DirectOutputService(self.config, FakePublisher())

        commands = service.compile_text_commands(text="A" * 600)
        key_commands = [command for command in commands if command.kind == "key"]

        self.assertEqual(len(key_commands), 600)
        self.assertTrue(all(command.key == "A" for command in key_commands))
        self.assertTrue(all(command.delay_after_ms >= self.config.direct_output_long_key_delay_ms for command in key_commands))

    def test_direct_output_publish_rejects_busy_or_offline_bridge(self) -> None:
        busy_service = DirectOutputService(
            self.config,
            FakePublisher(last_applied_seq=10, max_published_seq=14, pending_command_count=4, bridge_ready=False),
        )
        offline_service = DirectOutputService(
            self.config,
            FakePublisher(bridge_online=False, bridge_ready=False),
        )

        with self.assertRaisesRegex(RuntimeError, "still busy"):
            busy_service.publish_text(bridge_id="default", text="busy")

        with self.assertRaisesRegex(RuntimeError, "offline or stale"):
            offline_service.publish_text(bridge_id="default", text="offline")

    def test_direct_output_api_compose_and_publish(self) -> None:
        service = ProducerService(self.config, FakeRuntimeClient(), FakePublisher())
        client = TestClient(
            create_app(
                self.config,
                service,
                transcription_service=FakeTranscriptionService(),
                direct_output_service=FakeDirectOutputService(),
            )
        )

        headers = {"X-API-Key": "producer-secret"}

        compose = client.post(
            "/direct/compose",
            headers=headers,
            json={"bridge_id": "field", "prompt": "Draft me an email that says thanks for the update."},
        )
        self.assertEqual(compose.status_code, 200)
        self.assertEqual(compose.json()["bridge_id"], "field")
        self.assertIn("Typed:", compose.json()["text"])

        voice = client.post(
            "/direct/voice-compose",
            headers=headers,
            data={"bridge_id": "field", "prompt": "make it polite"},
            files={"audio": ("note.m4a", b"audio-bytes", "audio/mp4")},
        )
        self.assertEqual(voice.status_code, 200)
        self.assertIn("Transcript for note.m4a", voice.json()["transcript"])

        publish = client.post(
            "/direct/publish",
            headers=headers,
            json={"bridge_id": "field", "title": "Email", "text": "Hello there", "send_enter": False},
        )
        self.assertEqual(publish.status_code, 200)
        self.assertEqual(publish.json()["publish"]["bridge_id"], "field")
        self.assertEqual(publish.json()["text"], "Hello there")


if __name__ == "__main__":
    unittest.main()
