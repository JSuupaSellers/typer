from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import json
from typing import Any


def _first_present(raw: dict[str, Any], *keys: str, default: str = "") -> str:
    for key in keys:
        if key in raw and raw[key] is not None:
            return str(raw[key]).strip()
    return default


def _as_bool(value: Any, default: bool = True) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        cleaned = value.strip().lower()
        if cleaned in {"true", "1", "yes", "y"}:
            return True
        if cleaned in {"false", "0", "no", "n"}:
            return False
    return default


def normalize_confidence(value: str) -> str:
    cleaned = value.strip().lower()
    return cleaned if cleaned in {"low", "medium", "high"} else "high"


def confidence_rank(value: str) -> int:
    return {"low": 1, "medium": 2, "high": 3}.get(normalize_confidence(value), 0)


def format_quantity(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "1" if value else ""
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        text = f"{value:.4f}".rstrip("0").rstrip(".")
        return text or "0"
    return str(value).strip()


@dataclass(frozen=True)
class CatalogLineItem:
    code: str
    category: str
    selector: str
    description: str
    unit: str
    details: str

    @classmethod
    def from_api_payload(cls, raw: dict[str, Any]) -> "CatalogLineItem":
        return cls(
            code=str(raw.get("code", "")).strip().upper(),
            category=str(raw.get("category", "")).strip().upper(),
            selector=str(raw.get("selector", "")).strip().upper(),
            description=str(raw.get("description", "")).strip(),
            unit=str(raw.get("unit", "")).strip(),
            details=str(raw.get("details", "")).strip(),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "category": self.category,
            "selector": self.selector,
            "description": self.description,
            "unit": self.unit,
            "details": self.details,
        }


@dataclass(frozen=True)
class ScenarioHighlight:
    id: int
    title: str
    when_to_use: str
    when_not_to_use: str
    room: str
    surface: str
    damage_type: str
    keywords: str
    synonyms: str
    ai_hint: str
    matched_terms: tuple[str, ...]
    score: float

    @classmethod
    def from_api_payload(cls, raw: dict[str, Any]) -> "ScenarioHighlight":
        return cls(
            id=int(raw.get("id", 0) or 0),
            title=str(raw.get("title", "")).strip(),
            when_to_use=str(raw.get("when_to_use", "")).strip(),
            when_not_to_use=str(raw.get("when_not_to_use", "")).strip(),
            room=str(raw.get("room", "")).strip(),
            surface=str(raw.get("surface", "")).strip(),
            damage_type=str(raw.get("damage_type", "")).strip(),
            keywords=str(raw.get("keywords", "")).strip(),
            synonyms=str(raw.get("synonyms", "")).strip(),
            ai_hint=str(raw.get("ai_hint", "")).strip(),
            matched_terms=tuple(str(term).strip() for term in raw.get("matched_terms", []) if str(term).strip()),
            score=float(raw.get("score", 0.0) or 0.0),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "when_to_use": self.when_to_use,
            "when_not_to_use": self.when_not_to_use,
            "room": self.room,
            "surface": self.surface,
            "damage_type": self.damage_type,
            "keywords": self.keywords,
            "synonyms": self.synonyms,
            "ai_hint": self.ai_hint,
            "matched_terms": list(self.matched_terms),
            "score": self.score,
        }


@dataclass(frozen=True)
class RecommendationCandidate:
    item: CatalogLineItem
    score: float
    confidence: str
    matched_terms: tuple[str, ...]
    reasons: tuple[str, ...]
    highlights: tuple[ScenarioHighlight, ...]

    @classmethod
    def from_api_payload(cls, raw: dict[str, Any]) -> "RecommendationCandidate":
        return cls(
            item=CatalogLineItem.from_api_payload(raw.get("item", {})),
            score=float(raw.get("score", 0.0) or 0.0),
            confidence=normalize_confidence(str(raw.get("confidence", "low"))),
            matched_terms=tuple(str(term).strip() for term in raw.get("matched_terms", []) if str(term).strip()),
            reasons=tuple(str(reason).strip() for reason in raw.get("reasons", []) if str(reason).strip()),
            highlights=tuple(
                ScenarioHighlight.from_api_payload(highlight)
                for highlight in raw.get("highlights", [])
                if isinstance(highlight, dict)
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "item": self.item.to_dict(),
            "score": self.score,
            "confidence": self.confidence,
            "matched_terms": list(self.matched_terms),
            "reasons": list(self.reasons),
            "highlights": [highlight.to_dict() for highlight in self.highlights],
        }


@dataclass(frozen=True)
class EstimateScopeItem:
    item_id: str
    description: str
    item_type: str = "line_item"
    room: str = ""
    section: str = ""
    surface: str = ""
    damage_type: str = ""
    keywords: str = ""
    quantity: str = ""
    activity: str = ""
    note: str = ""
    approved_code: str = ""
    allow_auto_approve: bool = True
    min_confidence: str = "high"

    @classmethod
    def from_dict(cls, raw: dict[str, Any], index: int) -> "EstimateScopeItem":
        item_id = _first_present(raw, "item_id", "itemId", "id", default=f"item-{index}")
        item_type = _first_present(raw, "item_type", "itemType", default="line_item").lower() or "line_item"
        if item_type not in {"line_item", "note"}:
            item_type = "line_item"
        return cls(
            item_id=item_id or f"item-{index}",
            description=_first_present(raw, "description"),
            item_type=item_type,
            room=_first_present(raw, "room"),
            section=_first_present(raw, "section"),
            surface=_first_present(raw, "surface"),
            damage_type=_first_present(raw, "damage_type", "damageType"),
            keywords=_first_present(raw, "keywords"),
            quantity=format_quantity(raw.get("quantity")),
            activity=_first_present(raw, "activity").upper(),
            note=_first_present(raw, "note"),
            approved_code=_first_present(raw, "approved_code", "approvedCode").upper(),
            allow_auto_approve=_as_bool(raw.get("allow_auto_approve", raw.get("allowAutoApprove", True)), True),
            min_confidence=normalize_confidence(_first_present(raw, "min_confidence", "minConfidence", default="high")),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "item_id": self.item_id,
            "description": self.description,
            "item_type": self.item_type,
            "room": self.room,
            "section": self.section,
            "surface": self.surface,
            "damage_type": self.damage_type,
            "keywords": self.keywords,
            "quantity": self.quantity,
            "activity": self.activity,
            "note": self.note,
            "approved_code": self.approved_code,
            "allow_auto_approve": self.allow_auto_approve,
            "min_confidence": self.min_confidence,
        }


@dataclass(frozen=True)
class EstimateJob:
    job_id: str
    bridge_id: str
    items: tuple[EstimateScopeItem, ...]

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "EstimateJob":
        items = tuple(
            EstimateScopeItem.from_dict(item, index + 1)
            for index, item in enumerate(raw.get("items", []))
            if isinstance(item, dict)
        )
        return cls(
            job_id=_first_present(raw, "job_id", "jobId", default="job").strip() or "job",
            bridge_id=_first_present(raw, "bridge_id", "bridgeId", default="default").strip() or "default",
            items=items,
        )

    @classmethod
    def from_json_path(cls, path: str | Path) -> "EstimateJob":
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("Estimate job JSON must be an object.")
        return cls.from_dict(payload)

    def to_dict(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "bridge_id": self.bridge_id,
            "items": [item.to_dict() for item in self.items],
        }


@dataclass(frozen=True)
class PlannedEstimateItem:
    source: EstimateScopeItem
    candidates: tuple[RecommendationCandidate, ...]
    approved_candidate: RecommendationCandidate | None
    status: str
    review_reason: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source.to_dict(),
            "candidates": [candidate.to_dict() for candidate in self.candidates],
            "approved_candidate": self.approved_candidate.to_dict() if self.approved_candidate else None,
            "status": self.status,
            "review_reason": self.review_reason,
        }


@dataclass(frozen=True)
class ExecutionPlan:
    job: EstimateJob
    items: tuple[PlannedEstimateItem, ...]

    @property
    def approved_count(self) -> int:
        return sum(1 for item in self.items if item.status == "approved")

    @property
    def needs_review_count(self) -> int:
        return sum(1 for item in self.items if item.status == "needs_review")

    @property
    def unresolved_count(self) -> int:
        return sum(1 for item in self.items if item.status == "unresolved")

    def to_dict(self) -> dict[str, Any]:
        return {
            "job": self.job.to_dict(),
            "approved_count": self.approved_count,
            "needs_review_count": self.needs_review_count,
            "unresolved_count": self.unresolved_count,
            "items": [item.to_dict() for item in self.items],
        }


@dataclass(frozen=True)
class CompiledCommand:
    seq: int
    kind: str
    key: str = ""
    text: str = ""
    modifiers: tuple[str, ...] = ()
    duration_ms: int = 0
    delay_after_ms: int = 0
    repeat: int = 1
    metadata: dict[str, Any] = field(default_factory=dict)

    def preview(self) -> str:
        if self.kind == "delay":
            return f"delay {self.duration_ms}ms"
        if self.kind == "text":
            return f'text "{self.text}"'
        if self.kind == "combo":
            combo = "+".join((*self.modifiers, self.key))
            return combo.strip("+")
        return self.key

    def queue_payload(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"seq": self.seq, "kind": self.kind}
        if self.key:
            payload["key"] = self.key
        if self.text:
            payload["text"] = self.text
        if self.modifiers:
            payload["modifiers"] = list(self.modifiers)
        if self.duration_ms > 0:
            payload["duration_ms"] = self.duration_ms
        if self.delay_after_ms > 0:
            payload["delay_after_ms"] = self.delay_after_ms
        if self.repeat != 1:
            payload["repeat"] = self.repeat
        payload.update(self.metadata)
        return payload

    def rebased(self, seq: int) -> "CompiledCommand":
        return CompiledCommand(
            seq=seq,
            kind=self.kind,
            key=self.key,
            text=self.text,
            modifiers=self.modifiers,
            duration_ms=self.duration_ms,
            delay_after_ms=self.delay_after_ms,
            repeat=self.repeat,
            metadata=dict(self.metadata),
        )

    def to_dict(self) -> dict[str, Any]:
        payload = self.queue_payload()
        payload["preview"] = self.preview()
        return payload


@dataclass(frozen=True)
class CompiledJob:
    plan: ExecutionPlan
    commands: tuple[CompiledCommand, ...]

    @property
    def job_id(self) -> str:
        return self.plan.job.job_id

    @property
    def bridge_id(self) -> str:
        return self.plan.job.bridge_id

    @property
    def command_count(self) -> int:
        return len(self.commands)

    @property
    def starting_seq(self) -> int:
        return self.commands[0].seq if self.commands else 0

    @property
    def ending_seq(self) -> int:
        return self.commands[-1].seq if self.commands else 0

    def rebased(self, starting_seq: int) -> "CompiledJob":
        if not self.commands:
            return self
        return CompiledJob(
            plan=self.plan,
            commands=tuple(command.rebased(starting_seq + index) for index, command in enumerate(self.commands)),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "plan": self.plan.to_dict(),
            "command_count": self.command_count,
            "starting_seq": self.starting_seq,
            "ending_seq": self.ending_seq,
            "commands": [command.to_dict() for command in self.commands],
        }


@dataclass(frozen=True)
class QueueSnapshot:
    bridge_id: str
    last_applied_seq: int
    max_published_seq: int
    last_reserved_seq: int
    next_seq: int
    commands_path: str
    state_path: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "bridge_id": self.bridge_id,
            "last_applied_seq": self.last_applied_seq,
            "max_published_seq": self.max_published_seq,
            "last_reserved_seq": self.last_reserved_seq,
            "next_seq": self.next_seq,
            "commands_path": self.commands_path,
            "state_path": self.state_path,
        }


@dataclass(frozen=True)
class PublishResult:
    job_id: str
    bridge_id: str
    command_count: int
    starting_seq: int
    ending_seq: int
    commands_path: str
    state_path: str
    approved_codes: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "bridge_id": self.bridge_id,
            "command_count": self.command_count,
            "starting_seq": self.starting_seq,
            "ending_seq": self.ending_seq,
            "commands_path": self.commands_path,
            "state_path": self.state_path,
            "approved_codes": list(self.approved_codes),
        }
