from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import UTC, datetime
import json
from pathlib import Path
from typing import Any, Protocol
from uuid import uuid4

from .models import EstimateJob, EstimateScopeItem, format_quantity
from .service import ProducerService
from .transcription import TranscriptionServiceProtocol, default_adjuster_prompt


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _clean(value: str) -> str:
    return value.strip()


def _normalized_room(value: str) -> str:
    cleaned = _clean(value)
    return cleaned or "General"


def _normalized_section(value: str, fallback_surface: str = "") -> str:
    cleaned = _clean(value) or _clean(fallback_surface)
    return cleaned or "Scope"


def _section_rank(section: str) -> tuple[int, str]:
    lowered = section.strip().lower()
    if "ceiling" in lowered:
        return (10, lowered)
    if "wall" in lowered:
        return (20, lowered)
    if "trim" in lowered or "base" in lowered or "crown" in lowered:
        return (30, lowered)
    if "cab" in lowered or "counter" in lowered or "case" in lowered:
        return (40, lowered)
    if "floor" in lowered or "carpet" in lowered or "tile" in lowered:
        return (50, lowered)
    if "plumb" in lowered:
        return (60, lowered)
    if "electric" in lowered:
        return (70, lowered)
    if "hvac" in lowered or "duct" in lowered:
        return (80, lowered)
    if "contents" in lowered or "clean" in lowered:
        return (90, lowered)
    return (100, lowered)


@dataclass(frozen=True)
class DraftMessage:
    id: str
    role: str
    text: str
    created_at: str

    @classmethod
    def create(cls, role: str, text: str) -> "DraftMessage":
        return cls(
            id=f"msg-{uuid4().hex[:12]}",
            role=_clean(role) or "user",
            text=_clean(text),
            created_at=_now_iso(),
        )

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "DraftMessage":
        return cls(
            id=str(raw.get("id", "")).strip() or f"msg-{uuid4().hex[:12]}",
            role=str(raw.get("role", "user")).strip() or "user",
            text=str(raw.get("text", "")).strip(),
            created_at=str(raw.get("created_at", _now_iso())).strip() or _now_iso(),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "role": self.role,
            "text": self.text,
            "created_at": self.created_at,
        }


@dataclass(frozen=True)
class DraftLineItem:
    id: str
    room: str
    section: str
    approved_code: str
    description: str
    quantity: str = ""
    surface: str = ""
    damage_type: str = ""
    keywords: str = ""
    status: str = "accepted"
    source: str = "agent"
    rationale: str = ""
    created_at: str = field(default_factory=_now_iso)

    @classmethod
    def create(
        cls,
        *,
        room: str,
        section: str,
        approved_code: str,
        description: str,
        quantity: str = "",
        surface: str = "",
        damage_type: str = "",
        keywords: str = "",
        status: str = "accepted",
        source: str = "agent",
        rationale: str = "",
    ) -> "DraftLineItem":
        return cls(
            id=f"item-{uuid4().hex[:12]}",
            room=_normalized_room(room),
            section=_normalized_section(section, surface),
            approved_code=_clean(approved_code).upper(),
            description=_clean(description),
            quantity=format_quantity(quantity),
            surface=_clean(surface),
            damage_type=_clean(damage_type),
            keywords=_clean(keywords),
            status=_clean(status) or "accepted",
            source=_clean(source) or "agent",
            rationale=_clean(rationale),
        )

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "DraftLineItem":
        return cls(
            id=str(raw.get("id", "")).strip() or f"item-{uuid4().hex[:12]}",
            room=_normalized_room(str(raw.get("room", ""))),
            section=_normalized_section(str(raw.get("section", "")), str(raw.get("surface", ""))),
            approved_code=str(raw.get("approved_code", "")).strip().upper(),
            description=str(raw.get("description", "")).strip(),
            quantity=format_quantity(raw.get("quantity")),
            surface=str(raw.get("surface", "")).strip(),
            damage_type=str(raw.get("damage_type", "")).strip(),
            keywords=str(raw.get("keywords", "")).strip(),
            status=str(raw.get("status", "accepted")).strip() or "accepted",
            source=str(raw.get("source", "agent")).strip() or "agent",
            rationale=str(raw.get("rationale", "")).strip(),
            created_at=str(raw.get("created_at", _now_iso())).strip() or _now_iso(),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "room": self.room,
            "section": self.section,
            "approved_code": self.approved_code,
            "description": self.description,
            "quantity": self.quantity,
            "surface": self.surface,
            "damage_type": self.damage_type,
            "keywords": self.keywords,
            "status": self.status,
            "source": self.source,
            "rationale": self.rationale,
            "created_at": self.created_at,
        }


@dataclass(frozen=True)
class EstimateDraft:
    job_id: str
    bridge_id: str
    room_order: tuple[str, ...] = ()
    messages: tuple[DraftMessage, ...] = ()
    items: tuple[DraftLineItem, ...] = ()
    updated_at: str = field(default_factory=_now_iso)

    @classmethod
    def create(cls, job_id: str, bridge_id: str = "default") -> "EstimateDraft":
        return cls(
            job_id=_clean(job_id) or f"claim-{uuid4().hex[:8]}",
            bridge_id=_clean(bridge_id) or "default",
        )

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "EstimateDraft":
        return cls(
            job_id=str(raw.get("job_id", "")).strip() or f"claim-{uuid4().hex[:8]}",
            bridge_id=str(raw.get("bridge_id", "default")).strip() or "default",
            room_order=tuple(_normalized_room(str(room)) for room in raw.get("room_order", [])),
            messages=tuple(DraftMessage.from_dict(item) for item in raw.get("messages", []) if isinstance(item, dict)),
            items=tuple(DraftLineItem.from_dict(item) for item in raw.get("items", []) if isinstance(item, dict)),
            updated_at=str(raw.get("updated_at", _now_iso())).strip() or _now_iso(),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "bridge_id": self.bridge_id,
            "room_order": list(self.room_order),
            "messages": [message.to_dict() for message in self.messages],
            "items": [item.to_dict() for item in self.items],
            "updated_at": self.updated_at,
        }

    def ensure_room(self, room: str) -> "EstimateDraft":
        normalized = _normalized_room(room)
        if normalized in self.room_order:
            return self
        return replace(
            self,
            room_order=(*self.room_order, normalized),
            updated_at=_now_iso(),
        )

    def append_message(self, role: str, text: str) -> "EstimateDraft":
        message = DraftMessage.create(role, text)
        return replace(
            self,
            messages=(*self.messages, message),
            updated_at=_now_iso(),
        )

    def add_item(self, item: DraftLineItem) -> "EstimateDraft":
        draft = self.ensure_room(item.room)
        duplicate = next(
            (
                existing
                for existing in draft.items
                if existing.status != "rejected"
                and existing.room == item.room
                and existing.section == item.section
                and existing.approved_code == item.approved_code
                and existing.quantity == item.quantity
            ),
            None,
        )
        if duplicate is not None:
            return draft
        return replace(
            draft,
            items=(*draft.items, item),
            updated_at=_now_iso(),
        )

    def clear_section(self, room: str, section: str) -> "EstimateDraft":
        normalized_room = _normalized_room(room)
        normalized_section = _normalized_section(section)
        remaining = tuple(
            item
            for item in self.items
            if not (item.room == normalized_room and item.section == normalized_section)
        )
        return replace(self, items=remaining, updated_at=_now_iso())

    def remove_line_item(self, room: str, section: str, approved_code: str) -> "EstimateDraft":
        normalized_room = _normalized_room(room)
        normalized_section = _normalized_section(section)
        normalized_code = _clean(approved_code).upper()
        remaining = tuple(
            item
            for item in self.items
            if not (
                item.room == normalized_room
                and item.section == normalized_section
                and item.approved_code == normalized_code
            )
        )
        return replace(self, items=remaining, updated_at=_now_iso())

    def set_item_status(self, item_id: str, status: str) -> "EstimateDraft":
        normalized_status = _clean(status).lower() or "accepted"
        updated = tuple(
            replace(item, status=normalized_status) if item.id == item_id else item
            for item in self.items
        )
        return replace(self, items=updated, updated_at=_now_iso())

    def accept_all(self) -> "EstimateDraft":
        return replace(
            self,
            items=tuple(replace(item, status="accepted") for item in self.items),
            updated_at=_now_iso(),
        )

    def ordered_items(self, *, only_accepted: bool = False) -> tuple[DraftLineItem, ...]:
        room_positions = {room: index for index, room in enumerate(self.room_order)}
        first_seen_positions: dict[str, int] = {}
        for index, item in enumerate(self.items):
            first_seen_positions.setdefault(item.room, index)

        def sort_key(entry: DraftLineItem) -> tuple[int, tuple[int, str], str]:
            room_position = room_positions.get(entry.room, len(room_positions) + first_seen_positions.get(entry.room, 0))
            return (room_position, _section_rank(entry.section), entry.created_at)

        candidates = self.items
        if only_accepted:
            candidates = tuple(item for item in candidates if item.status == "accepted")
        return tuple(sorted(candidates, key=sort_key))

    def grouped_sections(self, *, only_accepted: bool = False) -> list[dict[str, Any]]:
        groups: list[dict[str, Any]] = []
        current_room = ""
        current_section = ""
        bucket: dict[str, Any] | None = None
        for item in self.ordered_items(only_accepted=only_accepted):
            if item.room != current_room or item.section != current_section:
                bucket = {
                    "room": item.room,
                    "section": item.section,
                    "note": item.section,
                    "items": [],
                }
                groups.append(bucket)
                current_room = item.room
                current_section = item.section
            assert bucket is not None
            bucket["items"].append(item.to_dict())
        return groups

    def to_estimate_job(self) -> EstimateJob:
        scope_items: list[EstimateScopeItem] = []
        current_room = ""
        current_section = ""
        counter = 1
        for item in self.ordered_items(only_accepted=True):
            if item.room != current_room or item.section != current_section:
                note_text = item.section
                scope_items.append(
                    EstimateScopeItem(
                        item_id=f"note-{counter}",
                        description=note_text,
                        item_type="note",
                        room=item.room,
                        section=item.section,
                        surface=item.surface,
                        note=note_text,
                    )
                )
                counter += 1
                current_room = item.room
                current_section = item.section

            scope_items.append(
                EstimateScopeItem(
                    item_id=item.id,
                    description=item.description,
                    item_type="line_item",
                    room=item.room,
                    section=item.section,
                    surface=item.surface,
                    damage_type=item.damage_type,
                    keywords=item.keywords,
                    quantity=item.quantity,
                    approved_code=item.approved_code,
                )
            )
            counter += 1

        return EstimateJob(job_id=self.job_id, bridge_id=self.bridge_id, items=tuple(scope_items))

    def summary_for_prompt(self) -> str:
        sections: list[str] = []
        for group in self.grouped_sections():
            item_lines = "\n".join(
                f"- {item['approved_code']}: {item['description']} qty={item['quantity'] or '-'} status={item['status']}"
                for item in group["items"]
            )
            sections.append(f"{group['room']} / {group['section']}\n{item_lines}")
        if not sections:
            return "No line items have been drafted yet."
        return "\n\n".join(sections)


class DraftStore:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def path_for(self, job_id: str) -> Path:
        safe_job_id = "".join(char if char.isalnum() or char in {"-", "_"} else "-" for char in job_id.strip()) or "job"
        return self.root / f"{safe_job_id}.json"

    def load(self, job_id: str) -> EstimateDraft | None:
        path = self.path_for(job_id)
        if not path.exists():
            return None
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"Draft at {path} is not a JSON object.")
        return EstimateDraft.from_dict(payload)

    def save(self, draft: EstimateDraft) -> EstimateDraft:
        path = self.path_for(draft.job_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(draft.to_dict(), indent=2) + "\n", encoding="utf-8")
        return draft

    def load_or_create(self, job_id: str, bridge_id: str = "default") -> EstimateDraft:
        existing = self.load(job_id)
        if existing is not None:
            return existing
        draft = EstimateDraft.create(job_id, bridge_id)
        return self.save(draft)


@dataclass(frozen=True)
class DraftTurnResult:
    draft: EstimateDraft
    assistant_reply: str
    transcript: str = ""
    warnings: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "draft": self.draft.to_dict(),
            "assistant_reply": self.assistant_reply,
            "transcript": self.transcript,
            "warnings": list(self.warnings),
            "grouped_sections": self.draft.grouped_sections(),
        }


class DraftAgentProtocol(Protocol):
    async def apply_turn(self, draft: EstimateDraft, user_text: str) -> DraftTurnResult:
        ...


class DraftCoordinator:
    def __init__(
        self,
        store: DraftStore,
        producer_service: ProducerService,
        *,
        transcription_service: TranscriptionServiceProtocol | None = None,
        agent: DraftAgentProtocol | None = None,
    ) -> None:
        self._store = store
        self._producer_service = producer_service
        self._transcription_service = transcription_service
        self._agent = agent

    def open_draft(self, job_id: str, bridge_id: str = "default") -> EstimateDraft:
        return self._store.load_or_create(job_id, bridge_id)

    def get_draft(self, job_id: str) -> EstimateDraft:
        draft = self._store.load(job_id)
        if draft is None:
            raise KeyError(job_id)
        return draft

    async def transcribe_audio(self, filename: str, content: bytes) -> str:
        if self._transcription_service is None:
            raise RuntimeError("Backend transcription is not configured.")
        return await self._transcription_service.transcribe_audio(
            filename,
            content,
            prompt=default_adjuster_prompt(),
        )

    async def apply_text_turn(self, job_id: str, bridge_id: str, text: str) -> DraftTurnResult:
        draft = self._store.load_or_create(job_id, bridge_id)
        cleaned_text = _clean(text)
        if not cleaned_text:
            return DraftTurnResult(draft=draft, assistant_reply="No text was provided.")

        draft = draft.append_message("user", cleaned_text)
        self._store.save(draft)

        if self._agent is None:
            updated = draft.append_message("assistant", "Saved your note. Connect the OpenAI draft agent to turn this into room items.")
            self._store.save(updated)
            return DraftTurnResult(
                draft=updated,
                assistant_reply="Saved your note. Connect the OpenAI draft agent to turn this into room items.",
            )

        result = await self._agent.apply_turn(draft, cleaned_text)
        persisted = result.draft.append_message("assistant", result.assistant_reply)
        self._store.save(persisted)
        return DraftTurnResult(
            draft=persisted,
            assistant_reply=result.assistant_reply,
            transcript=result.transcript,
            warnings=result.warnings,
        )

    async def apply_voice_turn(self, job_id: str, bridge_id: str, filename: str, content: bytes, prefix_text: str = "") -> DraftTurnResult:
        transcript = await self.transcribe_audio(filename, content)
        combined = "\n\n".join(part for part in (_clean(prefix_text), transcript) if part)
        result = await self.apply_text_turn(job_id, bridge_id, combined)
        return DraftTurnResult(
            draft=result.draft,
            assistant_reply=result.assistant_reply,
            transcript=transcript,
            warnings=result.warnings,
        )

    def set_item_status(self, job_id: str, item_id: str, status: str) -> EstimateDraft:
        draft = self.get_draft(job_id).set_item_status(item_id, status)
        return self._store.save(draft)

    def accept_all(self, job_id: str) -> EstimateDraft:
        draft = self.get_draft(job_id).accept_all()
        return self._store.save(draft)

    def plan_draft(self, job_id: str) -> dict[str, Any]:
        draft = self.get_draft(job_id)
        plan = self._producer_service.plan_job(draft.to_estimate_job())
        return {
            "draft": draft.to_dict(),
            "grouped_sections": draft.grouped_sections(),
            "plan": plan.to_dict(),
        }

    def publish_draft(self, job_id: str) -> dict[str, Any]:
        draft = self.get_draft(job_id)
        result = self._producer_service.publish_job(draft.to_estimate_job())
        return {
            "draft": draft.to_dict(),
            "grouped_sections": draft.grouped_sections(only_accepted=True),
            "publish": result.to_dict(),
        }
