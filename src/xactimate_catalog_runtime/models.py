from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
from typing import Any


@dataclass(frozen=True)
class CuratedUsageNote:
    title: str
    tags: str
    when_to_use: str
    when_not_to_use: str
    room: str
    surface: str
    damage_type: str
    keywords: str
    synonyms: str
    voice_notes: str
    ai_hint: str

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "CuratedUsageNote":
        return cls(
            title=str(raw.get("title", "")).strip(),
            tags=str(raw.get("tags", "")).strip(),
            when_to_use=str(raw.get("whenToUse", "")).strip(),
            when_not_to_use=str(raw.get("whenNotToUse", "")).strip(),
            room=str(raw.get("room", "")).strip(),
            surface=str(raw.get("surface", "")).strip(),
            damage_type=str(raw.get("damageType", "")).strip(),
            keywords=str(raw.get("keywords", "")).strip(),
            synonyms=str(raw.get("synonyms", "")).strip(),
            voice_notes=str(raw.get("voiceNotes", "")).strip(),
            ai_hint=str(raw.get("aiHint", "")).strip(),
        )


@dataclass(frozen=True)
class CuratedExportItem:
    code: str
    category: str
    selector: str
    description: str
    unit: str
    details: str
    usage_notes: tuple[CuratedUsageNote, ...]

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "CuratedExportItem":
        usage_notes = tuple(
            CuratedUsageNote.from_dict(note)
            for note in raw.get("usageNotes", [])
            if isinstance(note, dict)
        )
        return cls(
            code=str(raw.get("code", "")).strip().upper(),
            category=str(raw.get("category", "")).strip().upper(),
            selector=str(raw.get("selector", "")).strip().upper(),
            description=str(raw.get("description", "")).strip(),
            unit=str(raw.get("unit", "")).strip(),
            details=str(raw.get("details", "")).strip(),
            usage_notes=usage_notes,
        )


@dataclass(frozen=True)
class CuratedExportEnvelope:
    exported_at: str
    item_count: int
    usage_note_count: int
    items: tuple[CuratedExportItem, ...]

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "CuratedExportEnvelope":
        items = tuple(
            CuratedExportItem.from_dict(item)
            for item in raw.get("items", [])
            if isinstance(item, dict)
        )
        return cls(
            exported_at=str(raw.get("exportedAt", "")).strip(),
            item_count=int(raw.get("itemCount", len(items)) or 0),
            usage_note_count=int(raw.get("usageNoteCount", sum(len(item.usage_notes) for item in items)) or 0),
            items=items,
        )

    @classmethod
    def from_json_path(cls, path: str | Path) -> "CuratedExportEnvelope":
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("The curated export root must be a JSON object.")
        return cls.from_dict(payload)


@dataclass(frozen=True)
class RecommendationQuery:
    query: str = ""
    room: str = ""
    surface: str = ""
    damage_type: str = ""
    keywords: str = ""
    limit: int = 5

    @property
    def combined_text(self) -> str:
        return " ".join(
            value.strip()
            for value in (self.query, self.room, self.surface, self.damage_type, self.keywords)
            if value.strip()
        )


@dataclass(frozen=True)
class RuntimeScenario:
    id: int
    item_code: str
    title: str
    tags: str
    when_to_use: str
    when_not_to_use: str
    room: str
    surface: str
    damage_type: str
    keywords: str
    synonyms: str
    voice_notes: str
    ai_hint: str


@dataclass(frozen=True)
class RuntimeItem:
    code: str
    category: str
    selector: str
    description: str
    unit: str
    details: str


@dataclass(frozen=True)
class RecommendationScenarioHighlight:
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


@dataclass(frozen=True)
class RecommendationCandidate:
    item: RuntimeItem
    score: float
    confidence: str
    matched_terms: tuple[str, ...]
    reasons: tuple[str, ...]
    highlights: tuple[RecommendationScenarioHighlight, ...]


def normalize_code(code: str) -> str:
    return code.strip().upper()

