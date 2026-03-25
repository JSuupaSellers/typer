from __future__ import annotations

import asyncio
from contextlib import contextmanager
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime
import json
from pathlib import Path
import sqlite3
from typing import Any, Protocol
from uuid import uuid4

from .models import EstimateJob, EstimateScopeItem, format_quantity, normalize_cat_sel
from .policy import PolicyEngine
from .service import ProducerService
from .transcription import TranscriptionServiceProtocol, default_adjuster_prompt
from .workflow_agents import (
    ClaimOrchestratorAgent,
    ClaimTurnPlan,
    RoomPlannerAgent,
    RoomTask,
    RoomVerifier,
)


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _clean(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


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


def _display_code(*, category: str, selector: str, approved_code: str) -> str:
    normalized_category, normalized_selector, normalized_code = normalize_cat_sel(
        category=category,
        selector=selector,
        approved_code=approved_code,
    )
    if normalized_category and normalized_selector:
        return f"{normalized_category} / {normalized_selector}"
    return normalized_code or normalized_category or normalized_selector


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
    category: str = ""
    selector: str = ""
    quantity: str = ""
    activity: str = ""
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
        description: str,
        approved_code: str = "",
        category: str = "",
        selector: str = "",
        quantity: str = "",
        activity: str = "",
        surface: str = "",
        damage_type: str = "",
        keywords: str = "",
        status: str = "accepted",
        source: str = "agent",
        rationale: str = "",
    ) -> "DraftLineItem":
        normalized_category, normalized_selector, normalized_code = normalize_cat_sel(
            category=category,
            selector=selector,
            approved_code=approved_code,
        )
        return cls(
            id=f"item-{uuid4().hex[:12]}",
            room=_normalized_room(room),
            section=_normalized_section(section, surface),
            approved_code=normalized_code,
            description=_clean(description),
            category=normalized_category,
            selector=normalized_selector,
            quantity=format_quantity(quantity),
            activity=_clean(activity).upper(),
            surface=_clean(surface),
            damage_type=_clean(damage_type),
            keywords=_clean(keywords),
            status=_clean(status) or "accepted",
            source=_clean(source) or "agent",
            rationale=_clean(rationale),
        )

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "DraftLineItem":
        normalized_category, normalized_selector, normalized_code = normalize_cat_sel(
            category=raw.get("category", ""),
            selector=raw.get("selector", ""),
            approved_code=raw.get("approved_code", ""),
        )
        return cls(
            id=str(raw.get("id", "")).strip() or f"item-{uuid4().hex[:12]}",
            room=_normalized_room(str(raw.get("room", ""))),
            section=_normalized_section(str(raw.get("section", "")), str(raw.get("surface", ""))),
            approved_code=normalized_code,
            description=str(raw.get("description", "")).strip(),
            category=normalized_category,
            selector=normalized_selector,
            quantity=format_quantity(raw.get("quantity")),
            activity=str(raw.get("activity", "")).strip().upper(),
            surface=str(raw.get("surface", "")).strip(),
            damage_type=str(raw.get("damage_type", "")).strip(),
            keywords=str(raw.get("keywords", "")).strip(),
            status=str(raw.get("status", "accepted")).strip() or "accepted",
            source=str(raw.get("source", "agent")).strip() or "agent",
            rationale=str(raw.get("rationale", "")).strip(),
            created_at=str(raw.get("created_at", _now_iso())).strip() or _now_iso(),
        )

    def to_dict(self) -> dict[str, Any]:
        normalized_category, normalized_selector, normalized_code = normalize_cat_sel(
            category=self.category,
            selector=self.selector,
            approved_code=self.approved_code,
        )
        return {
            "id": self.id,
            "room": self.room,
            "section": self.section,
            "category": normalized_category,
            "selector": normalized_selector,
            "approved_code": normalized_code,
            "description": self.description,
            "quantity": self.quantity,
            "activity": self.activity,
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
        return cls(job_id=_clean(job_id) or f"claim-{uuid4().hex[:8]}", bridge_id=_clean(bridge_id) or "default")

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
        return replace(self, room_order=(*self.room_order, normalized), updated_at=_now_iso())

    def append_message(self, role: str, text: str) -> "EstimateDraft":
        message = DraftMessage.create(role, text)
        return replace(self, messages=(*self.messages, message), updated_at=_now_iso())

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
                and existing.activity == item.activity
            ),
            None,
        )
        if duplicate is not None:
            return draft
        return replace(draft, items=(*draft.items, item), updated_at=_now_iso())

    def clear_section(self, room: str, section: str) -> "EstimateDraft":
        normalized_room = _normalized_room(room)
        normalized_section = _normalized_section(section)
        remaining = tuple(item for item in self.items if not (item.room == normalized_room and item.section == normalized_section))
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
        updated = tuple(replace(item, status=normalized_status) if item.id == item_id else item for item in self.items)
        return replace(self, items=updated, updated_at=_now_iso())

    def resolve_item(
        self,
        item_id: str,
        *,
        category: str,
        selector: str,
        quantity: str = "",
        description: str = "",
        status: str = "accepted",
    ) -> "EstimateDraft":
        normalized_category, normalized_selector, normalized_code = normalize_cat_sel(
            category=category,
            selector=selector,
        )
        if not normalized_code:
            raise ValueError("Both category and selector are required to resolve an item.")

        replacement_found = False
        updated_items: list[DraftLineItem] = []
        for item in self.items:
            if item.id != item_id:
                updated_items.append(item)
                continue
            replacement_found = True
            updated_items.append(
                replace(
                    item,
                    category=normalized_category,
                    selector=normalized_selector,
                    approved_code=normalized_code,
                    quantity=format_quantity(quantity) if _clean(quantity) else item.quantity,
                    description=_clean(description) or item.description,
                    status=_clean(status).lower() or "accepted",
                )
            )
        if not replacement_found:
            raise KeyError(item_id)
        return replace(self, items=tuple(updated_items), updated_at=_now_iso())

    def accept_all(self) -> "EstimateDraft":
        return replace(self, items=tuple(replace(item, status="accepted") for item in self.items), updated_at=_now_iso())

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
                bucket = {"room": item.room, "section": item.section, "note": item.section, "items": []}
                groups.append(bucket)
                current_room = item.room
                current_section = item.section
            assert bucket is not None
            bucket["items"].append(item.to_dict())
        return groups

    def to_estimate_job(self) -> EstimateJob:
        scope_items: list[EstimateScopeItem] = []
        for item in self.ordered_items(only_accepted=True):
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
                    activity=item.activity,
                    category=item.category,
                    selector=item.selector,
                    approved_code=item.approved_code,
                )
            )

        return EstimateJob(job_id=self.job_id, bridge_id=self.bridge_id, items=tuple(scope_items))

    def summary_for_prompt(self) -> str:
        sections: list[str] = []
        for group in self.grouped_sections():
            item_lines = "\n".join(
                f"- {_display_code(category=str(item.get('category', '')), selector=str(item.get('selector', '')), approved_code=str(item.get('approved_code', '')))}"
                f"{(' activity=' + item['activity']) if item.get('activity') else ''}: "
                f"{item['description']} qty={item['quantity'] or '-'} status={item['status']}"
                for item in group["items"]
            )
            sections.append(f"{group['room']} / {group['section']}\n{item_lines}")
        if not sections:
            return "No line items have been drafted yet."
        return "\n\n".join(sections)


@dataclass(frozen=True)
class DraftSummary:
    job_id: str
    bridge_id: str
    updated_at: str
    room_count: int
    item_count: int
    accepted_count: int
    message_count: int
    latest_message_preview: str

    @classmethod
    def from_draft(cls, draft: EstimateDraft) -> "DraftSummary":
        latest_message = draft.messages[-1].text if draft.messages else ""
        return cls(
            job_id=draft.job_id,
            bridge_id=draft.bridge_id,
            updated_at=draft.updated_at,
            room_count=len(tuple(dict.fromkeys(draft.room_order))),
            item_count=len(draft.items),
            accepted_count=sum(1 for item in draft.items if item.status == "accepted"),
            message_count=len(draft.messages),
            latest_message_preview=latest_message[:140],
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "bridge_id": self.bridge_id,
            "updated_at": self.updated_at,
            "room_count": self.room_count,
            "item_count": self.item_count,
            "accepted_count": self.accepted_count,
            "message_count": self.message_count,
            "latest_message_preview": self.latest_message_preview,
        }


@dataclass(frozen=True)
class ClaimOperation:
    id: str
    job_id: str
    bridge_id: str
    kind: str
    status: str
    progress: int
    current_room: str
    status_message: str
    submitted_text: str
    transcript: str
    assistant_reply: str
    error_message: str
    created_at: str
    updated_at: str

    @classmethod
    def create(
        cls,
        *,
        job_id: str,
        bridge_id: str,
        kind: str,
        submitted_text: str = "",
        transcript: str = "",
    ) -> "ClaimOperation":
        now = _now_iso()
        return cls(
            id=f"op-{uuid4().hex[:12]}",
            job_id=_clean(job_id) or "job",
            bridge_id=_clean(bridge_id) or "default",
            kind=_clean(kind) or "message",
            status="queued",
            progress=0,
            current_room="",
            status_message="Queued",
            submitted_text=_clean(submitted_text),
            transcript=_clean(transcript),
            assistant_reply="",
            error_message="",
            created_at=now,
            updated_at=now,
        )

    @classmethod
    def from_row(cls, row: sqlite3.Row) -> "ClaimOperation":
        return cls(
            id=row["id"],
            job_id=row["job_id"],
            bridge_id=row["bridge_id"],
            kind=row["kind"],
            status=row["status"],
            progress=int(row["progress"] or 0),
            current_room=row["current_room"] or "",
            status_message=row["status_message"] or "",
            submitted_text=row["submitted_text"] or "",
            transcript=row["transcript"] or "",
            assistant_reply=row["assistant_reply"] or "",
            error_message=row["error_message"] or "",
            created_at=row["created_at"] or _now_iso(),
            updated_at=row["updated_at"] or _now_iso(),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "job_id": self.job_id,
            "bridge_id": self.bridge_id,
            "kind": self.kind,
            "status": self.status,
            "progress": self.progress,
            "current_room": self.current_room,
            "status_message": self.status_message,
            "submitted_text": self.submitted_text,
            "transcript": self.transcript,
            "assistant_reply": self.assistant_reply,
            "error_message": self.error_message,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


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
    async def apply_turn(self, draft: EstimateDraft, user_text: str) -> DraftTurnResult: ...


class DraftStore:
    def __init__(self, root: str | Path) -> None:
        root_path = Path(root)
        if root_path.suffix in {".sqlite", ".db"}:
            self.root = root_path.parent
            self.db_path = root_path
        else:
            self.root = root_path
            self.db_path = root_path / "drafts.sqlite"
        self.root.mkdir(parents=True, exist_ok=True)
        self.upload_root = self.root / "uploads"
        self.upload_root.mkdir(parents=True, exist_ok=True)
        self._initialize_schema()
        self._migrate_legacy_json_drafts()

    def load(self, job_id: str) -> EstimateDraft | None:
        with self._connect() as connection:
            row = connection.execute("SELECT draft_json FROM claims WHERE job_id = ?", (job_id,)).fetchone()
        if row is None:
            return None
        payload = json.loads(row["draft_json"])
        return EstimateDraft.from_dict(payload) if isinstance(payload, dict) else None

    def save(self, draft: EstimateDraft) -> EstimateDraft:
        with self._connect() as connection:
            existing = connection.execute(
                "SELECT created_at, status FROM claims WHERE job_id = ?",
                (draft.job_id,),
            ).fetchone()
            created_at = existing["created_at"] if existing is not None and existing["created_at"] else draft.updated_at
            status = existing["status"] if existing is not None and existing["status"] else self._claim_status_for_draft(draft)
            connection.execute(
                """
                INSERT INTO claims (job_id, bridge_id, status, draft_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id) DO UPDATE SET
                    bridge_id = excluded.bridge_id,
                    draft_json = excluded.draft_json,
                    updated_at = excluded.updated_at
                """,
                (draft.job_id, draft.bridge_id, status, json.dumps(draft.to_dict()), created_at, draft.updated_at),
            )
            self._refresh_claim_projection(connection, draft)
        return draft

    def load_or_create(self, job_id: str, bridge_id: str = "default") -> EstimateDraft:
        existing = self.load(job_id)
        if existing is not None:
            return existing
        return self.save(EstimateDraft.create(job_id, bridge_id))

    def list_summaries(self) -> tuple[DraftSummary, ...]:
        summaries: list[DraftSummary] = []
        with self._connect() as connection:
            rows = connection.execute("SELECT draft_json FROM claims ORDER BY updated_at DESC").fetchall()
        for row in rows:
            try:
                payload = json.loads(row["draft_json"])
            except Exception:
                continue
            if isinstance(payload, dict):
                summaries.append(DraftSummary.from_draft(EstimateDraft.from_dict(payload)))
        summaries.sort(key=lambda entry: entry.updated_at, reverse=True)
        return tuple(summaries)

    def claim_status(self, job_id: str) -> str:
        with self._connect() as connection:
            row = connection.execute("SELECT status FROM claims WHERE job_id = ?", (job_id,)).fetchone()
        return str(row["status"]).strip() if row is not None else "new"

    def set_claim_status(self, job_id: str, status: str) -> None:
        with self._connect() as connection:
            connection.execute(
                "UPDATE claims SET status = ?, updated_at = ? WHERE job_id = ?",
                (_clean(status) or "new", _now_iso(), job_id),
            )

    def list_room_states(self, job_id: str) -> list[dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT room_name, room_type, loss_type, status, summary, verification_json, sort_index, updated_at
                FROM claim_rooms
                WHERE job_id = ?
                ORDER BY sort_index ASC, room_name ASC
                """,
                (job_id,),
            ).fetchall()
        results: list[dict[str, Any]] = []
        for row in rows:
            verification = {}
            if row["verification_json"]:
                try:
                    verification = json.loads(row["verification_json"])
                except json.JSONDecodeError:
                    verification = {}
            results.append(
                {
                    "room": row["room_name"],
                    "room_type": row["room_type"] or "generic",
                    "loss_type": row["loss_type"] or "generic",
                    "status": row["status"] or "new",
                    "summary": row["summary"] or "",
                    "verification": verification,
                    "updated_at": row["updated_at"] or "",
                }
            )
        return results

    def upsert_room_state(
        self,
        *,
        job_id: str,
        room: str,
        room_type: str = "generic",
        loss_type: str = "generic",
        status: str = "queued",
        summary: str = "",
        verification: dict[str, Any] | None = None,
    ) -> None:
        normalized_room = _normalized_room(room)
        now = _now_iso()
        with self._connect() as connection:
            existing = connection.execute(
                "SELECT sort_index, created_at FROM claim_rooms WHERE job_id = ? AND room_name = ?",
                (job_id, normalized_room),
            ).fetchone()
            if existing is not None:
                sort_index = int(existing["sort_index"] or 0)
                created_at = existing["created_at"] or now
            else:
                row = connection.execute(
                    "SELECT COALESCE(MAX(sort_index), -1) AS max_sort FROM claim_rooms WHERE job_id = ?",
                    (job_id,),
                ).fetchone()
                sort_index = int((row["max_sort"] if row is not None else -1) or -1) + 1
                created_at = now
            connection.execute(
                """
                INSERT INTO claim_rooms (
                    job_id, room_name, room_type, loss_type, status, summary, verification_json, sort_index, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id, room_name) DO UPDATE SET
                    room_type = excluded.room_type,
                    loss_type = excluded.loss_type,
                    status = excluded.status,
                    summary = excluded.summary,
                    verification_json = excluded.verification_json,
                    updated_at = excluded.updated_at
                """,
                (
                    job_id,
                    normalized_room,
                    _clean(room_type) or "generic",
                    _clean(loss_type) or "generic",
                    _clean(status) or "queued",
                    _clean(summary),
                    json.dumps(verification or {}),
                    sort_index,
                    created_at,
                    now,
                ),
            )

    def refresh_review_statuses(self, draft: EstimateDraft) -> None:
        room_items: dict[str, list[DraftLineItem]] = {}
        for item in draft.items:
            room_items.setdefault(item.room, []).append(item)
        with self._connect() as connection:
            for room in draft.room_order:
                items = room_items.get(room, [])
                if not items:
                    status = "new"
                elif any(item.status == "pending_review" for item in items):
                    status = "review_pending"
                elif any(item.status == "accepted" for item in items):
                    status = "accepted"
                else:
                    status = "rejected"
                connection.execute(
                    "UPDATE claim_rooms SET status = ?, updated_at = ? WHERE job_id = ? AND room_name = ?",
                    (status, _now_iso(), draft.job_id, room),
                )
            connection.execute(
                "UPDATE claims SET status = ?, updated_at = ? WHERE job_id = ?",
                (self._claim_status_for_draft(draft), _now_iso(), draft.job_id),
            )

    def create_operation(
        self,
        *,
        job_id: str,
        bridge_id: str,
        kind: str,
        submitted_text: str = "",
        transcript: str = "",
        payload: dict[str, Any] | None = None,
    ) -> ClaimOperation:
        operation = ClaimOperation.create(
            job_id=job_id,
            bridge_id=bridge_id,
            kind=kind,
            submitted_text=submitted_text,
            transcript=transcript,
        )
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO claim_operations (
                    id, job_id, bridge_id, kind, status, progress, current_room, status_message,
                    submitted_text, transcript, assistant_reply, error_message, payload_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    operation.id,
                    operation.job_id,
                    operation.bridge_id,
                    operation.kind,
                    operation.status,
                    operation.progress,
                    operation.current_room,
                    operation.status_message,
                    operation.submitted_text,
                    operation.transcript,
                    operation.assistant_reply,
                    operation.error_message,
                    json.dumps(payload or {}),
                    operation.created_at,
                    operation.updated_at,
                ),
            )
        return operation

    def get_operation(self, operation_id: str) -> ClaimOperation:
        with self._connect() as connection:
            row = connection.execute("SELECT * FROM claim_operations WHERE id = ?", (operation_id,)).fetchone()
        if row is None:
            raise KeyError(operation_id)
        return ClaimOperation.from_row(row)

    def update_operation(
        self,
        operation_id: str,
        *,
        status: str | None = None,
        progress: int | None = None,
        current_room: str | None = None,
        status_message: str | None = None,
        transcript: str | None = None,
        assistant_reply: str | None = None,
        error_message: str | None = None,
        payload: dict[str, Any] | None = None,
    ) -> ClaimOperation:
        existing = self.get_operation(operation_id)
        now = _now_iso()
        with self._connect() as connection:
            current_payload_row = connection.execute(
                "SELECT payload_json FROM claim_operations WHERE id = ?",
                (operation_id,),
            ).fetchone()
            current_payload = {}
            if current_payload_row is not None and current_payload_row["payload_json"]:
                try:
                    current_payload = json.loads(current_payload_row["payload_json"])
                except json.JSONDecodeError:
                    current_payload = {}
            if payload:
                current_payload.update(payload)
            connection.execute(
                """
                UPDATE claim_operations
                SET status = ?, progress = ?, current_room = ?, status_message = ?, transcript = ?,
                    assistant_reply = ?, error_message = ?, payload_json = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    _clean(status) or existing.status,
                    existing.progress if progress is None else max(min(progress, 100), 0),
                    existing.current_room if current_room is None else _clean(current_room),
                    existing.status_message if status_message is None else _clean(status_message),
                    existing.transcript if transcript is None else _clean(transcript),
                    existing.assistant_reply if assistant_reply is None else _clean(assistant_reply),
                    existing.error_message if error_message is None else _clean(error_message),
                    json.dumps(current_payload),
                    now,
                    operation_id,
                ),
            )
        return self.get_operation(operation_id)

    def list_incomplete_operations(self) -> tuple[ClaimOperation, ...]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM claim_operations
                WHERE status IN ('queued', 'running')
                ORDER BY created_at ASC
                """
            ).fetchall()
        return tuple(ClaimOperation.from_row(row) for row in rows)

    def list_operations(self, job_id: str, *, include_completed: bool = True, limit: int = 20) -> tuple[ClaimOperation, ...]:
        query = """
            SELECT * FROM claim_operations
            WHERE job_id = ?
        """
        parameters: list[Any] = [job_id]
        if not include_completed:
            query += " AND status IN ('queued', 'running')"
        query += " ORDER BY created_at DESC LIMIT ?"
        parameters.append(max(limit, 1))
        with self._connect() as connection:
            rows = connection.execute(query, tuple(parameters)).fetchall()
        return tuple(ClaimOperation.from_row(row) for row in rows)

    def operation_payload(self, operation_id: str) -> dict[str, Any]:
        with self._connect() as connection:
            row = connection.execute("SELECT payload_json FROM claim_operations WHERE id = ?", (operation_id,)).fetchone()
        if row is None or not row["payload_json"]:
            return {}
        try:
            payload = json.loads(row["payload_json"])
        except json.JSONDecodeError:
            return {}
        return payload if isinstance(payload, dict) else {}

    def record_event(self, operation_id: str, event_type: str, payload: dict[str, Any] | None = None) -> None:
        with self._connect() as connection:
            connection.execute(
                "INSERT INTO claim_operation_events (operation_id, event_type, payload_json, created_at) VALUES (?, ?, ?, ?)",
                (operation_id, _clean(event_type), json.dumps(payload or {}), _now_iso()),
            )

    def list_events(self, operation_id: str) -> list[dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT id, event_type, payload_json, created_at FROM claim_operation_events WHERE operation_id = ? ORDER BY id ASC",
                (operation_id,),
            ).fetchall()
        results: list[dict[str, Any]] = []
        for row in rows:
            try:
                payload = json.loads(row["payload_json"] or "{}")
            except json.JSONDecodeError:
                payload = {}
            results.append(
                {
                    "id": int(row["id"]),
                    "event_type": row["event_type"],
                    "payload": payload,
                    "created_at": row["created_at"],
                }
            )
        return results

    def record_tool_trace(self, operation_id: str, room_name: str, tool_name: str, request: dict[str, Any], response: dict[str, Any]) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO tool_traces (operation_id, room_name, tool_name, request_json, response_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (operation_id, _normalized_room(room_name), _clean(tool_name), json.dumps(request), json.dumps(response), _now_iso()),
            )

    def list_tool_traces(self, operation_id: str) -> list[dict[str, Any]]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT id, room_name, tool_name, request_json, response_json, created_at
                FROM tool_traces
                WHERE operation_id = ?
                ORDER BY id ASC
                """,
                (operation_id,),
            ).fetchall()
        traces: list[dict[str, Any]] = []
        for row in rows:
            traces.append(
                {
                    "id": int(row["id"]),
                    "room": row["room_name"],
                    "tool_name": row["tool_name"],
                    "request": json.loads(row["request_json"] or "{}"),
                    "response": json.loads(row["response_json"] or "{}"),
                    "created_at": row["created_at"],
                }
            )
        return traces

    def sync_policy_rules(self, rows: list[tuple[str, dict[str, Any]]]) -> None:
        with self._connect() as connection:
            for key, payload in rows:
                connection.execute(
                    """
                    INSERT INTO policy_rules (rule_key, payload_json, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(rule_key) DO UPDATE SET payload_json = excluded.payload_json, updated_at = excluded.updated_at
                    """,
                    (key, json.dumps(payload), _now_iso()),
                )

    def path_for_upload(self, operation_id: str, filename: str) -> Path:
        extension = Path(filename).suffix or ".bin"
        return self.upload_root / f"{operation_id}{extension}"

    @contextmanager
    def _connect(self):
        connection = sqlite3.connect(self.db_path)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    def _initialize_schema(self) -> None:
        with self._connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS claims (
                    job_id TEXT PRIMARY KEY,
                    bridge_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    draft_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS claim_messages (
                    id TEXT PRIMARY KEY,
                    job_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    text TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS claim_rooms (
                    job_id TEXT NOT NULL,
                    room_name TEXT NOT NULL,
                    room_type TEXT NOT NULL,
                    loss_type TEXT NOT NULL,
                    status TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    verification_json TEXT NOT NULL,
                    sort_index INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (job_id, room_name)
                );
                CREATE TABLE IF NOT EXISTS claim_room_items (
                    id TEXT PRIMARY KEY,
                    job_id TEXT NOT NULL,
                    room_name TEXT NOT NULL,
                    section TEXT NOT NULL,
                    approved_code TEXT NOT NULL,
                    description TEXT NOT NULL,
                    quantity TEXT NOT NULL,
                    activity TEXT NOT NULL,
                    surface TEXT NOT NULL,
                    damage_type TEXT NOT NULL,
                    keywords TEXT NOT NULL,
                    status TEXT NOT NULL,
                    source TEXT NOT NULL,
                    rationale TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS claim_operations (
                    id TEXT PRIMARY KEY,
                    job_id TEXT NOT NULL,
                    bridge_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    progress INTEGER NOT NULL,
                    current_room TEXT NOT NULL,
                    status_message TEXT NOT NULL,
                    submitted_text TEXT NOT NULL,
                    transcript TEXT NOT NULL,
                    assistant_reply TEXT NOT NULL,
                    error_message TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS claim_operation_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation_id TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS tool_traces (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation_id TEXT NOT NULL,
                    room_name TEXT NOT NULL,
                    tool_name TEXT NOT NULL,
                    request_json TEXT NOT NULL,
                    response_json TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS policy_rules (
                    rule_key TEXT PRIMARY KEY,
                    payload_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS eval_cases (
                    case_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS eval_runs (
                    run_id TEXT PRIMARY KEY,
                    case_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    score REAL NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_claim_messages_job ON claim_messages(job_id, created_at);
                CREATE INDEX IF NOT EXISTS idx_claim_room_items_job ON claim_room_items(job_id, room_name, created_at);
                CREATE INDEX IF NOT EXISTS idx_claim_operations_job ON claim_operations(job_id, created_at);
                CREATE INDEX IF NOT EXISTS idx_operation_events_operation ON claim_operation_events(operation_id, id);
                CREATE INDEX IF NOT EXISTS idx_tool_traces_operation ON tool_traces(operation_id, id);
                """
            )

    def _migrate_legacy_json_drafts(self) -> None:
        for path in sorted(self.root.glob("*.json")):
            if path.name == self.db_path.name:
                continue
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(payload, dict) or "job_id" not in payload:
                continue
            draft = EstimateDraft.from_dict(payload)
            if self.load(draft.job_id) is None:
                self.save(draft)

    def _refresh_claim_projection(self, connection: sqlite3.Connection, draft: EstimateDraft) -> None:
        connection.execute("DELETE FROM claim_messages WHERE job_id = ?", (draft.job_id,))
        connection.execute("DELETE FROM claim_room_items WHERE job_id = ?", (draft.job_id,))
        existing_rooms = {
            row["room_name"]: row
            for row in connection.execute(
                "SELECT * FROM claim_rooms WHERE job_id = ?",
                (draft.job_id,),
            ).fetchall()
        }

        for message in draft.messages:
            connection.execute(
                "INSERT INTO claim_messages (id, job_id, role, text, created_at) VALUES (?, ?, ?, ?, ?)",
                (message.id, draft.job_id, message.role, message.text, message.created_at),
            )

        for item in draft.items:
            connection.execute(
                """
                INSERT INTO claim_room_items (
                    id, job_id, room_name, section, approved_code, description, quantity,
                    activity, surface, damage_type, keywords, status, source, rationale, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    item.id,
                    draft.job_id,
                    item.room,
                    item.section,
                    item.approved_code,
                    item.description,
                    item.quantity,
                    item.activity,
                    item.surface,
                    item.damage_type,
                    item.keywords,
                    item.status,
                    item.source,
                    item.rationale,
                    item.created_at,
                ),
            )

        for index, room in enumerate(draft.room_order):
            existing = existing_rooms.get(room)
            connection.execute(
                """
                INSERT INTO claim_rooms (
                    job_id, room_name, room_type, loss_type, status, summary, verification_json, sort_index, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id, room_name) DO UPDATE SET
                    sort_index = excluded.sort_index,
                    updated_at = excluded.updated_at
                """,
                (
                    draft.job_id,
                    room,
                    existing["room_type"] if existing is not None else "generic",
                    existing["loss_type"] if existing is not None else "generic",
                    existing["status"] if existing is not None else "new",
                    existing["summary"] if existing is not None else "",
                    existing["verification_json"] if existing is not None else "{}",
                    index,
                    existing["created_at"] if existing is not None else draft.updated_at,
                    draft.updated_at,
                ),
            )

    @staticmethod
    def _claim_status_for_draft(draft: EstimateDraft) -> str:
        if not draft.items:
            return "new"
        if any(item.status == "pending_review" for item in draft.items):
            return "review_pending"
        if any(item.status == "accepted" for item in draft.items):
            return "approved_for_publish"
        return "review_pending"


class DraftCoordinator:
    def __init__(
        self,
        store: DraftStore,
        producer_service: ProducerService,
        *,
        transcription_service: TranscriptionServiceProtocol | None = None,
        agent: DraftAgentProtocol | None = None,
        orchestrator: ClaimOrchestratorAgent | None = None,
        room_planner: RoomPlannerAgent | None = None,
        room_verifier: RoomVerifier | None = None,
        policy_engine: PolicyEngine | None = None,
    ) -> None:
        self._store = store
        self._producer_service = producer_service
        self._transcription_service = transcription_service
        self._legacy_agent = agent
        self._orchestrator = orchestrator
        self._room_planner = room_planner
        self._room_verifier = room_verifier
        self._policy_engine = policy_engine
        self._claim_locks: dict[str, asyncio.Lock] = {}
        self._operation_tasks: dict[str, asyncio.Task[None]] = {}
        self._operation_events: dict[str, asyncio.Event] = {}

    def open_draft(self, job_id: str, bridge_id: str = "default") -> EstimateDraft:
        return self._store.load_or_create(job_id, bridge_id)

    def get_draft(self, job_id: str) -> EstimateDraft:
        draft = self._store.load(job_id)
        if draft is None:
            raise KeyError(job_id)
        return draft

    def list_drafts(self) -> tuple[DraftSummary, ...]:
        return self._store.list_summaries()

    def list_room_states(self, job_id: str) -> list[dict[str, Any]]:
        return self._store.list_room_states(job_id)

    def claim_status(self, job_id: str) -> str:
        return self._store.claim_status(job_id)

    def list_operations(self, job_id: str, *, include_completed: bool = True, limit: int = 20) -> list[dict[str, Any]]:
        return [
            operation.to_dict()
            for operation in self._store.list_operations(job_id, include_completed=include_completed, limit=limit)
        ]

    def get_operation(self, operation_id: str) -> dict[str, Any]:
        operation = self._store.get_operation(operation_id)
        draft = self._store.load(operation.job_id)
        return {
            "operation": operation.to_dict(),
            "events": self._store.list_events(operation_id),
            "tool_traces": self._store.list_tool_traces(operation_id),
            "draft": None if draft is None else draft.to_dict(),
            "grouped_sections": [] if draft is None else draft.grouped_sections(),
            "room_states": [] if draft is None else self._store.list_room_states(draft.job_id),
            "claim_status": self._store.claim_status(operation.job_id),
        }

    async def resume_pending_operations(self) -> None:
        for operation in self._store.list_incomplete_operations():
            self._schedule_operation(operation.id)

    async def transcribe_audio(self, filename: str, content: bytes) -> str:
        if self._transcription_service is None:
            raise RuntimeError("Backend transcription is not configured.")
        return await self._transcription_service.transcribe_audio(
            filename,
            content,
            prompt=default_adjuster_prompt(),
        )

    async def submit_text_operation(self, job_id: str, bridge_id: str, text: str) -> dict[str, Any]:
        draft = self._store.load_or_create(job_id, bridge_id)
        cleaned_text = _clean(text)
        if not cleaned_text:
            raise RuntimeError("No text was provided.")
        draft = draft.append_message("user", cleaned_text)
        self._store.save(draft)
        operation = self._store.create_operation(
            job_id=draft.job_id,
            bridge_id=draft.bridge_id,
            kind="message",
            submitted_text=cleaned_text,
        )
        self._store.record_event(operation.id, "submitted", {"kind": "message"})
        self._schedule_operation(operation.id)
        return self.get_operation(operation.id)

    async def submit_voice_operation(
        self,
        job_id: str,
        bridge_id: str,
        filename: str,
        content: bytes,
        prefix_text: str = "",
    ) -> dict[str, Any]:
        draft = self._store.load_or_create(job_id, bridge_id)
        operation = self._store.create_operation(
            job_id=draft.job_id,
            bridge_id=draft.bridge_id,
            kind="voice_turn",
            submitted_text=_clean(prefix_text),
        )
        audio_path = self._store.path_for_upload(operation.id, filename)
        audio_path.write_bytes(content)
        self._store.update_operation(operation.id, payload={"audio_path": str(audio_path), "audio_filename": filename, "prefix_text": _clean(prefix_text)})
        self._store.record_event(operation.id, "submitted", {"kind": "voice_turn", "filename": filename})
        self._schedule_operation(operation.id)
        return self.get_operation(operation.id)

    async def wait_for_operation(self, operation_id: str, timeout_s: float | None = None) -> dict[str, Any]:
        operation = self._store.get_operation(operation_id)
        if operation.status in {"completed", "failed"}:
            return self.get_operation(operation_id)
        event = self._operation_events.setdefault(operation_id, asyncio.Event())
        await asyncio.wait_for(event.wait(), timeout=timeout_s)
        return self.get_operation(operation_id)

    async def apply_text_turn(self, job_id: str, bridge_id: str, text: str) -> DraftTurnResult:
        result = await self.submit_text_operation(job_id, bridge_id, text)
        waited = await self.wait_for_operation(result["operation"]["id"], timeout_s=None)
        operation = waited["operation"]
        if operation["status"] == "failed":
            raise RuntimeError(operation["error_message"] or "Draft workflow failed.")
        draft = self.get_draft(job_id)
        return DraftTurnResult(
            draft=draft,
            assistant_reply=str(operation.get("assistant_reply", "")).strip() or "Updated the draft.",
            transcript=str(operation.get("transcript", "")).strip(),
        )

    async def apply_voice_turn(self, job_id: str, bridge_id: str, filename: str, content: bytes, prefix_text: str = "") -> DraftTurnResult:
        result = await self.submit_voice_operation(job_id, bridge_id, filename, content, prefix_text)
        waited = await self.wait_for_operation(result["operation"]["id"], timeout_s=None)
        operation = waited["operation"]
        if operation["status"] == "failed":
            raise RuntimeError(operation["error_message"] or "Draft workflow failed.")
        draft = self.get_draft(job_id)
        return DraftTurnResult(
            draft=draft,
            assistant_reply=str(operation.get("assistant_reply", "")).strip() or "Updated the draft.",
            transcript=str(operation.get("transcript", "")).strip(),
        )

    def set_item_status(self, job_id: str, item_id: str, status: str) -> EstimateDraft:
        draft = self.get_draft(job_id).set_item_status(item_id, status)
        saved = self._store.save(draft)
        self._store.refresh_review_statuses(saved)
        return saved

    def accept_all(self, job_id: str) -> EstimateDraft:
        draft = self.get_draft(job_id).accept_all()
        saved = self._store.save(draft)
        self._store.refresh_review_statuses(saved)
        return saved

    def resolve_item(
        self,
        job_id: str,
        item_id: str,
        *,
        category: str,
        selector: str,
        quantity: str = "",
        description: str = "",
        status: str = "accepted",
    ) -> EstimateDraft:
        draft = self.get_draft(job_id).resolve_item(
            item_id,
            category=category,
            selector=selector,
            quantity=quantity,
            description=description,
            status=status,
        )
        saved = self._store.save(draft)
        self._store.refresh_review_statuses(saved)
        return saved

    def plan_draft(self, job_id: str) -> dict[str, Any]:
        draft = self.get_draft(job_id)
        plan = self._producer_service.plan_job(draft.to_estimate_job())
        return {
            "draft": draft.to_dict(),
            "grouped_sections": draft.grouped_sections(),
            "plan": plan.to_dict(),
            "room_states": self._store.list_room_states(job_id),
            "claim_status": self._store.claim_status(job_id),
        }

    def publish_draft(self, job_id: str) -> dict[str, Any]:
        draft = self.get_draft(job_id)
        self._store.set_claim_status(job_id, "publishing")
        result = self._producer_service.publish_job(draft.to_estimate_job())
        self._store.set_claim_status(job_id, "published")
        return {
            "draft": draft.to_dict(),
            "grouped_sections": draft.grouped_sections(only_accepted=True),
            "publish": result.to_dict(),
            "room_states": self._store.list_room_states(job_id),
            "claim_status": self._store.claim_status(job_id),
        }

    def _schedule_operation(self, operation_id: str) -> None:
        if operation_id in self._operation_tasks and not self._operation_tasks[operation_id].done():
            return
        loop = asyncio.get_running_loop()
        event = self._operation_events.setdefault(operation_id, asyncio.Event())
        event.clear()
        task = loop.create_task(self._run_operation(operation_id))
        self._operation_tasks[operation_id] = task

    async def _run_operation(self, operation_id: str) -> None:
        operation = self._store.get_operation(operation_id)
        lock = self._claim_locks.setdefault(operation.job_id, asyncio.Lock())
        try:
            async with lock:
                self._store.update_operation(operation_id, status="running", progress=5, status_message="Starting workflow")
                if operation.kind == "voice_turn":
                    await self._process_voice_turn(operation_id)
                else:
                    await self._process_message_turn(operation_id)
        except Exception as exc:
            self._store.update_operation(
                operation_id,
                status="failed",
                progress=100,
                status_message="Workflow failed",
                error_message=str(exc),
            )
            self._store.record_event(operation_id, "failed", {"error": str(exc)})
        finally:
            self._operation_events.setdefault(operation_id, asyncio.Event()).set()

    async def _process_voice_turn(self, operation_id: str) -> None:
        payload = self._store.operation_payload(operation_id)
        audio_path = Path(str(payload.get("audio_path", "")).strip())
        audio_filename = str(payload.get("audio_filename", audio_path.name)).strip() or audio_path.name
        prefix_text = str(payload.get("prefix_text", "")).strip()
        if not audio_path.exists():
            raise RuntimeError(f"Voice upload missing for operation {operation_id}.")
        self._store.update_operation(operation_id, progress=10, status_message="Transcribing voice note")
        transcript = await self.transcribe_audio(audio_filename, audio_path.read_bytes())
        operation = self._store.update_operation(operation_id, transcript=transcript, progress=20, status_message="Queued transcript for drafting")
        combined_text = "\n\n".join(part for part in (prefix_text, transcript) if part)
        draft = self._store.load_or_create(operation.job_id, operation.bridge_id)
        if combined_text:
            draft = draft.append_message("user", combined_text)
            self._store.save(draft)
        try:
            audio_path.unlink(missing_ok=True)
        except Exception:
            pass
        await self._process_message_turn(operation_id, message_override=combined_text)

    async def _process_message_turn(self, operation_id: str, message_override: str | None = None) -> None:
        operation = self._store.get_operation(operation_id)
        draft = self._store.load_or_create(operation.job_id, operation.bridge_id)
        user_text = message_override if message_override is not None else operation.submitted_text
        cleaned_text = _clean(user_text)
        if not cleaned_text:
            raise RuntimeError("No text was available to process.")

        if self._orchestrator is None or self._room_planner is None or self._room_verifier is None or self._policy_engine is None:
            if self._legacy_agent is None:
                updated = draft.append_message("assistant", "Saved your note. The durable claim workflow is not configured.")
                self._store.save(updated)
                self._store.update_operation(
                    operation_id,
                    status="completed",
                    progress=100,
                    status_message="Saved note",
                    assistant_reply="Saved your note. The durable claim workflow is not configured.",
                )
                return
            result = await self._legacy_agent.apply_turn(draft, cleaned_text)
            persisted = result.draft.append_message("assistant", result.assistant_reply)
            self._store.save(persisted)
            self._store.update_operation(
                operation_id,
                status="completed",
                progress=100,
                status_message="Completed",
                transcript=result.transcript,
                assistant_reply=result.assistant_reply,
            )
            return

        self._store.set_claim_status(operation.job_id, "ingesting")
        self._store.record_event(operation_id, "claim_status", {"status": "ingesting"})
        self._store.update_operation(operation_id, progress=15, status_message="Planning affected rooms")

        turn_plan = await self._orchestrator.orchestrate(
            draft_summary=draft.summary_for_prompt(),
            existing_rooms=list(draft.room_order),
            recent_messages=[f"{message.role}: {message.text}" for message in draft.messages[-8:]],
            user_text=cleaned_text,
        )
        self._store.record_event(operation_id, "turn_plan", turn_plan.to_dict())
        self._store.set_claim_status(operation.job_id, "planning_rooms")

        latest_draft = draft
        room_count = max(len(turn_plan.rooms), 1)
        for index, room_task in enumerate(turn_plan.rooms, start=1):
            progress_floor = 20 + int(((index - 1) / room_count) * 55)
            self._store.update_operation(
                operation_id,
                progress=progress_floor,
                current_room=room_task.room,
                status_message=f"Drafting {room_task.room}",
            )
            self._store.upsert_room_state(
                job_id=operation.job_id,
                room=room_task.room,
                room_type=room_task.room_type,
                loss_type=room_task.loss_type,
                status="drafting",
                summary=room_task.summary,
            )
            existing_room_summary = self._room_summary(latest_draft, room_task.room)
            planned_room = await self._room_planner.plan_room(
                claim_summary=turn_plan.claim_summary,
                room_task=room_task,
                existing_room_summary=existing_room_summary,
            )
            self._store.record_event(operation_id, "room_planned", planned_room.to_dict())
            for trace in planned_room.traces:
                self._store.record_tool_trace(operation_id, room_task.room, trace.tool_name, trace.request, trace.response)
            latest_draft = self._apply_planner_operations(latest_draft, planned_room.operations, room_task.room)
            self._store.save(latest_draft)

            room_items = [item for item in latest_draft.items if item.room == room_task.room and item.status != "rejected"]
            verification = self._room_verifier.verify(room=room_task.room, room_summary=room_task.summary, room_items=room_items)
            self._store.record_event(operation_id, "room_verified", verification.to_dict())
            self._store.upsert_room_state(
                job_id=operation.job_id,
                room=room_task.room,
                room_type=room_task.room_type,
                loss_type=room_task.loss_type,
                status="review_pending",
                summary=planned_room.summary,
                verification=verification.to_dict(),
            )

        final_reply = turn_plan.assistant_reply
        if not latest_draft.messages or latest_draft.messages[-1].text != final_reply:
            latest_draft = latest_draft.append_message("assistant", final_reply)
        self._store.save(latest_draft)
        self._store.refresh_review_statuses(latest_draft)
        self._store.update_operation(
            operation_id,
            status="completed",
            progress=100,
            current_room="",
            status_message="Completed",
            assistant_reply=final_reply,
            transcript=operation.transcript,
        )
        self._store.record_event(operation_id, "completed", {"assistant_reply": final_reply})

    @staticmethod
    def _room_summary(draft: EstimateDraft, room: str) -> str:
        sections = [group for group in draft.grouped_sections() if group["room"] == room]
        if not sections:
            return "No existing room items."
        return "\n\n".join(
            f"{group['section']}\n" + "\n".join(
                f"- {_display_code(category=str(item.get('category', '')), selector=str(item.get('selector', '')), approved_code=str(item.get('approved_code', '')))}: "
                f"{item['description']} qty={item['quantity'] or '-'} status={item['status']}"
                for item in group["items"]
            )
            for group in sections
        )

    @staticmethod
    def _apply_planner_operations(draft: EstimateDraft, operations: tuple[dict[str, Any], ...], default_room: str) -> EstimateDraft:
        updated = draft
        for raw in operations:
            op = str(raw.get("op", "")).strip().lower()
            room = str(raw.get("room", "")).strip() or default_room
            section = str(raw.get("section", "")).strip()
            if op == "clear_section":
                updated = updated.clear_section(room, section)
                continue
            if op == "remove_line_item":
                _, _, approved_code = normalize_cat_sel(
                    category=raw.get("category", ""),
                    selector=raw.get("selector", ""),
                    approved_code=raw.get("approved_code", ""),
                )
                updated = updated.remove_line_item(room, section, approved_code)
                continue
            if op != "add_line_item":
                continue
            category, selector, approved_code = normalize_cat_sel(
                category=raw.get("category", ""),
                selector=raw.get("selector", ""),
                approved_code=raw.get("approved_code", ""),
            )
            if not approved_code:
                continue
            updated = updated.add_item(
                DraftLineItem.create(
                    room=room,
                    section=section,
                    approved_code=approved_code,
                    description=str(raw.get("description", "")).strip(),
                    category=category,
                    selector=selector,
                    quantity=str(raw.get("quantity", "")).strip(),
                    activity=str(raw.get("activity", "")).strip(),
                    surface=str(raw.get("surface", "")).strip(),
                    damage_type=str(raw.get("damage_type", "")).strip(),
                    keywords=str(raw.get("keywords", "")).strip(),
                    rationale=str(raw.get("rationale", "")).strip(),
                    status="pending_review",
                    source="planner",
                )
            )
        return updated
