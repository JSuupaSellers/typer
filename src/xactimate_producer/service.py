from __future__ import annotations

from typing import Protocol

from .compiler import WorkflowCompiler
from .config import ProducerConfig
from .models import (
    CatalogLineItem,
    CompiledJob,
    EstimateJob,
    ExecutionPlan,
    PlannedEstimateItem,
    PublishResult,
    QueueSnapshot,
    RecommendationCandidate,
    confidence_rank,
)


class RuntimeClientProtocol(Protocol):
    def recommend_for_item(self, scope_item, limit: int) -> list[RecommendationCandidate]:
        ...

    def get_item(self, code: str) -> CatalogLineItem:
        ...


class QueuePublisherProtocol(Protocol):
    def snapshot(self, bridge_id: str) -> QueueSnapshot:
        ...

    def reserve_sequence_range(self, bridge_id: str, job_id: str, command_count: int, floor_seq: int) -> int:
        ...

    def publish(self, compiled_job: CompiledJob) -> PublishResult:
        ...


class ProducerReviewRequiredError(RuntimeError):
    def __init__(self, message: str, plan: ExecutionPlan) -> None:
        super().__init__(message)
        self.plan = plan


class ProducerService:
    def __init__(
        self,
        config: ProducerConfig,
        runtime_client: RuntimeClientProtocol,
        publisher: QueuePublisherProtocol | None = None,
    ) -> None:
        self._config = config
        self._runtime_client = runtime_client
        self._publisher = publisher
        self._compiler = WorkflowCompiler(config.workflow_profile)

    def plan_job(self, job: EstimateJob) -> ExecutionPlan:
        items: list[PlannedEstimateItem] = []
        for source in job.items:
            if source.approved_code:
                try:
                    approved_item = self._runtime_client.get_item(source.approved_code)
                except Exception as exc:
                    items.append(
                        PlannedEstimateItem(
                            source=source,
                            candidates=(),
                            approved_candidate=None,
                            status="unresolved",
                            review_reason=f"Approved code {source.approved_code} could not be loaded: {exc}",
                        )
                    )
                    continue
                approved_candidate = RecommendationCandidate(
                    item=approved_item,
                    score=100.0,
                    confidence="high",
                    matched_terms=(approved_item.code,),
                    reasons=("Explicit approved_code supplied in the job payload.",),
                    highlights=(),
                )
                items.append(
                    PlannedEstimateItem(
                        source=source,
                        candidates=(approved_candidate,),
                        approved_candidate=approved_candidate,
                        status="approved",
                    )
                )
                continue

            candidates = tuple(self._runtime_client.recommend_for_item(source, self._config.recommendation_limit))
            if not candidates:
                items.append(
                    PlannedEstimateItem(
                        source=source,
                        candidates=(),
                        approved_candidate=None,
                        status="unresolved",
                        review_reason="No runtime candidates matched this scope item.",
                    )
                )
                continue

            minimum_confidence = source.min_confidence or self._config.auto_approve_min_confidence
            top_candidate = candidates[0]
            if source.allow_auto_approve and confidence_rank(top_candidate.confidence) >= confidence_rank(minimum_confidence):
                items.append(
                    PlannedEstimateItem(
                        source=source,
                        candidates=candidates,
                        approved_candidate=top_candidate,
                        status="approved",
                    )
                )
                continue

            items.append(
                PlannedEstimateItem(
                    source=source,
                    candidates=candidates,
                    approved_candidate=None,
                    status="needs_review",
                    review_reason=(
                        f"Top candidate {top_candidate.item.code} is {top_candidate.confidence} confidence; "
                        f"minimum required is {minimum_confidence}."
                    ),
                )
            )

        return ExecutionPlan(job=job, items=tuple(items))

    def compile_job(self, job: EstimateJob, starting_seq: int = 1) -> CompiledJob:
        plan = self.plan_job(job)
        self._ensure_publishable(plan)
        commands = self._compiler.compile(plan, starting_seq=starting_seq)
        return CompiledJob(plan=plan, commands=commands)

    def publish_job(self, job: EstimateJob) -> PublishResult:
        if self._publisher is None:
            raise RuntimeError("A queue publisher is required to publish jobs.")

        draft = self.compile_job(job, starting_seq=1)
        snapshot = self._publisher.snapshot(job.bridge_id)
        floor_seq = max(snapshot.last_applied_seq, snapshot.max_published_seq, snapshot.last_reserved_seq)
        reserved_start = self._publisher.reserve_sequence_range(
            bridge_id=job.bridge_id,
            job_id=job.job_id,
            command_count=draft.command_count,
            floor_seq=floor_seq,
        )
        finalized = draft.rebased(reserved_start)
        return self._publisher.publish(finalized)

    def _ensure_publishable(self, plan: ExecutionPlan) -> None:
        if plan.unresolved_count or plan.needs_review_count:
            raise ProducerReviewRequiredError(
                "The job still contains unresolved or review-required scope items.",
                plan,
            )

