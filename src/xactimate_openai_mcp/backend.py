from __future__ import annotations

from pathlib import Path
from typing import Any

from xactimate_catalog_runtime.models import RecommendationQuery
from xactimate_catalog_runtime.repository import RuntimeCatalogRepository
from xactimate_producer.config import ProducerConfig
from xactimate_producer.models import (
    CatalogLineItem,
    EstimateJob,
    RecommendationCandidate,
    ScenarioHighlight,
)
from xactimate_producer.publisher import FirebaseCommandPublisher
from xactimate_producer.service import ProducerReviewRequiredError, ProducerService


class LocalRuntimeCatalogClient:
    def __init__(self, repository: RuntimeCatalogRepository) -> None:
        self._repository = repository

    def recommend_for_item(self, scope_item, limit: int) -> list[RecommendationCandidate]:
        candidates = self._repository.search(
            RecommendationQuery(
                query=scope_item.description,
                room=scope_item.room,
                surface=scope_item.surface,
                damage_type=scope_item.damage_type,
                keywords=scope_item.keywords,
                limit=limit,
            )
        )
        return [self._convert_candidate(candidate) for candidate in candidates]

    def get_item(self, code: str) -> CatalogLineItem:
        item = self._repository.get_item(code)
        if item is None:
            raise KeyError(code)
        return CatalogLineItem(
            code=item.code,
            category=item.category,
            selector=item.selector,
            description=item.description,
            unit=item.unit,
            details=item.details,
        )

    @staticmethod
    def _convert_candidate(candidate) -> RecommendationCandidate:
        return RecommendationCandidate(
            item=CatalogLineItem(
                code=candidate.item.code,
                category=candidate.item.category,
                selector=candidate.item.selector,
                description=candidate.item.description,
                unit=candidate.item.unit,
                details=candidate.item.details,
            ),
            score=candidate.score,
            confidence=candidate.confidence,
            matched_terms=candidate.matched_terms,
            reasons=candidate.reasons,
            highlights=tuple(
                ScenarioHighlight(
                    id=highlight.id,
                    title=highlight.title,
                    when_to_use=highlight.when_to_use,
                    when_not_to_use=highlight.when_not_to_use,
                    room=highlight.room,
                    surface=highlight.surface,
                    damage_type=highlight.damage_type,
                    keywords=highlight.keywords,
                    synonyms=highlight.synonyms,
                    ai_hint=highlight.ai_hint,
                    matched_terms=highlight.matched_terms,
                    score=highlight.score,
                )
                for highlight in candidate.highlights
            ),
        )


class OpenAIXactimateBackend:
    def __init__(self, runtime_database_path: str | Path, producer_config_path: str | Path) -> None:
        self.runtime_database_path = Path(runtime_database_path)
        self.producer_config_path = Path(producer_config_path)
        self.repository = RuntimeCatalogRepository(self.runtime_database_path)
        self.producer_config = ProducerConfig.load(self.producer_config_path)
        self.runtime_client = LocalRuntimeCatalogClient(self.repository)
        self.plan_service = ProducerService(self.producer_config, self.runtime_client)

    def search_line_items(
        self,
        query: str,
        room: str = "",
        surface: str = "",
        damage_type: str = "",
        keywords: str = "",
        limit: int = 5,
    ) -> dict[str, Any]:
        candidates = self.repository.search(
            RecommendationQuery(
                query=query,
                room=room,
                surface=surface,
                damage_type=damage_type,
                keywords=keywords,
                limit=limit,
            )
        )
        payload = {
            "query": {
                "query": query,
                "room": room,
                "surface": surface,
                "damage_type": damage_type,
                "keywords": keywords,
                "limit": limit,
            },
            "candidates": [
                self.runtime_client._convert_candidate(candidate).to_dict()
                for candidate in candidates
            ],
        }
        return {"status": "ok", "message": "", "payload": payload}

    def get_line_item(self, code: str) -> dict[str, Any]:
        result = self.repository.get_item_with_scenarios(code)
        if result is None:
            return {
                "status": "not_found",
                "message": f"Unknown line item code: {code.strip().upper()}",
                "payload": {},
            }

        item = result["item"]
        scenarios = result["scenarios"]
        return {
            "status": "ok",
            "message": "",
            "payload": {
                "item": {
                    "code": item.code,
                    "category": item.category,
                    "selector": item.selector,
                    "description": item.description,
                    "unit": item.unit,
                    "details": item.details,
                },
                "scenarios": [
                    {
                        "id": scenario.id,
                        "item_code": scenario.item_code,
                        "title": scenario.title,
                        "tags": scenario.tags,
                        "when_to_use": scenario.when_to_use,
                        "when_not_to_use": scenario.when_not_to_use,
                        "room": scenario.room,
                        "surface": scenario.surface,
                        "damage_type": scenario.damage_type,
                        "keywords": scenario.keywords,
                        "synonyms": scenario.synonyms,
                        "voice_notes": scenario.voice_notes,
                        "ai_hint": scenario.ai_hint,
                    }
                    for scenario in scenarios
                ],
            },
        }

    def plan_estimate_job(self, job: dict[str, Any]) -> dict[str, Any]:
        estimate_job = EstimateJob.from_dict(job)
        plan = self.plan_service.plan_job(estimate_job)
        return {"status": "ok", "message": "", "payload": plan.to_dict()}

    def compile_estimate_job(self, job: dict[str, Any], starting_seq: int = 1) -> dict[str, Any]:
        estimate_job = EstimateJob.from_dict(job)
        try:
            compiled = self.plan_service.compile_job(estimate_job, starting_seq=starting_seq)
        except ProducerReviewRequiredError as exc:
            return {
                "status": "review_required",
                "message": str(exc),
                "payload": exc.plan.to_dict(),
            }
        return {"status": "ok", "message": "", "payload": compiled.to_dict()}

    def publish_estimate_job(self, job: dict[str, Any], confirm_publish: bool = False) -> dict[str, Any]:
        if not confirm_publish:
            return {
                "status": "confirmation_required",
                "message": "Set confirm_publish=true before writing commands to Firebase.",
                "payload": {},
            }

        publish_errors = self.producer_config.validate_for_publish()
        if publish_errors:
            return {
                "status": "error",
                "message": "; ".join(publish_errors),
                "payload": {},
            }

        estimate_job = EstimateJob.from_dict(job)
        publish_service = ProducerService(
            self.producer_config,
            self.runtime_client,
            FirebaseCommandPublisher(self.producer_config),
        )
        try:
            result = publish_service.publish_job(estimate_job)
        except ProducerReviewRequiredError as exc:
            return {
                "status": "review_required",
                "message": str(exc),
                "payload": exc.plan.to_dict(),
            }
        return {"status": "ok", "message": "", "payload": result.to_dict()}

