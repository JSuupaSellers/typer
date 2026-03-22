from __future__ import annotations

import tempfile
import unittest

from fastapi.testclient import TestClient

from xactimate_producer.api import create_app
from xactimate_producer.config import ProducerConfig
from xactimate_producer.drafts import DraftCoordinator, DraftLineItem, DraftStore, EstimateDraft
from xactimate_producer.models import (
    CatalogLineItem,
    EstimateJob,
    PublishResult,
    QueueSnapshot,
    RecommendationCandidate,
)
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
        self.items_by_code = {
            self.patch_item.code: self.patch_item,
            self.paint_item.code: self.paint_item,
        }

    def recommend_for_item(self, scope_item, limit: int):
        return list(self.recommendations.get(scope_item.item_id, []))[:limit]

    def get_item(self, code: str) -> CatalogLineItem:
        normalized = code.strip().upper()
        if normalized not in self.items_by_code:
            raise KeyError(normalized)
        return self.items_by_code[normalized]


class FakePublisher:
    def __init__(self, *, last_applied_seq: int = 0, max_published_seq: int = 0, last_reserved_seq: int = 0) -> None:
        self.snapshot_value = QueueSnapshot(
            bridge_id="default",
            last_applied_seq=last_applied_seq,
            max_published_seq=max_published_seq,
            last_reserved_seq=last_reserved_seq,
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
            max_published_seq=self.snapshot_value.max_published_seq,
            last_reserved_seq=self.last_reserved_start + command_count - 1,
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


class FakeTranscriptionService:
    async def transcribe_audio(self, filename: str, content: bytes, prompt: str = "") -> str:
        return f"Transcript for {filename} ({len(content)} bytes)"


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


if __name__ == "__main__":
    unittest.main()
