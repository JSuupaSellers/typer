from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import re
from typing import Any

from .models import CatalogLineItem, RecommendationCandidate


def _normalized(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.strip().lower()).strip()


def _tokenize(text: str) -> set[str]:
    return {token for token in _normalized(text).split() if token}


def _normalized_component(value: str) -> str:
    cleaned = _normalized(value)
    aliases = {
        "walls": "wall",
        "wall": "wall",
        "ceiling": "ceiling",
        "ceilings": "ceiling",
        "baseboards": "baseboard",
        "baseboard": "baseboard",
        "trim": "trim",
        "crown": "crown",
        "crown molding": "crown",
        "chair rail": "chair_rail",
        "chairrail": "chair_rail",
        "door": "door",
        "doors": "door",
        "casing": "casing",
        "window": "window",
        "windows": "window",
        "floor": "floor",
        "floors": "floor",
        "carpet": "carpet",
        "cabinet": "cabinet",
        "cabinetry": "cabinet",
        "fixture": "fixture",
        "fixtures": "fixture",
    }
    return aliases.get(cleaned, cleaned.replace(" ", "_"))


def _normalized_intent(value: str) -> str:
    cleaned = _normalized(value)
    aliases = {
        "clean": "clean",
        "cleaning": "clean",
        "wash": "clean",
        "paint": "paint",
        "painting": "paint",
        "seal": "seal",
        "prime": "prime",
        "patch": "patch",
        "repair": "patch",
        "detach reset": "detach_reset",
        "detach and reset": "detach_reset",
        "reset": "reset",
        "replace": "replace",
        "remove": "remove",
    }
    return aliases.get(cleaned, cleaned.replace(" ", "_"))


@dataclass(frozen=True)
class PolicyDefault:
    component: str
    intent: str
    surface: str
    room_scope: bool
    preferred_codes: tuple[str, ...]
    quantity: str
    section: str
    notes: str

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "PolicyDefault":
        return cls(
            component=_normalized_component(str(raw.get("component", ""))),
            intent=_normalized_intent(str(raw.get("intent", ""))),
            surface=_normalized_component(str(raw.get("surface", raw.get("component", "")))),
            room_scope=bool(raw.get("room_scope", False)),
            preferred_codes=tuple(str(code).strip().upper() for code in raw.get("preferred_codes", []) if str(code).strip()),
            quantity=str(raw.get("quantity", "")).strip(),
            section=str(raw.get("section", "")).strip(),
            notes=str(raw.get("notes", "")).strip(),
        )


@dataclass(frozen=True)
class PolicyFallbackRule:
    component: str
    intent: str
    surface: str
    preferred_codes: tuple[str, ...]
    blocked_codes: tuple[str, ...]
    blocked_terms: tuple[str, ...]
    notes: str

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "PolicyFallbackRule":
        return cls(
            component=_normalized_component(str(raw.get("component", ""))),
            intent=_normalized_intent(str(raw.get("intent", ""))),
            surface=_normalized_component(str(raw.get("surface", raw.get("component", "")))),
            preferred_codes=tuple(str(code).strip().upper() for code in raw.get("preferred_codes", []) if str(code).strip()),
            blocked_codes=tuple(str(code).strip().upper() for code in raw.get("blocked_codes", []) if str(code).strip()),
            blocked_terms=tuple(_normalized(str(term)) for term in raw.get("blocked_terms", []) if str(term).strip()),
            notes=str(raw.get("notes", "")).strip(),
        )


@dataclass(frozen=True)
class RoomTemplate:
    loss_type: str
    room_type: str
    sections: tuple[str, ...]
    notes: str

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "RoomTemplate":
        return cls(
            loss_type=_normalized(str(raw.get("loss_type", "generic"))),
            room_type=_normalized(str(raw.get("room_type", "generic"))),
            sections=tuple(str(section).strip() for section in raw.get("sections", []) if str(section).strip()),
            notes=str(raw.get("notes", "")).strip(),
        )


@dataclass(frozen=True)
class PolicyVerification:
    missing_intents: tuple[str, ...]
    policy_violations: tuple[str, ...]
    warnings: tuple[str, ...]

    @property
    def passed(self) -> bool:
        return not self.missing_intents and not self.policy_violations

    def to_dict(self) -> dict[str, Any]:
        return {
            "passed": self.passed,
            "missing_intents": list(self.missing_intents),
            "policy_violations": list(self.policy_violations),
            "warnings": list(self.warnings),
        }


class PolicyEngine:
    def __init__(self, policy_path: str | Path):
        self._path = Path(policy_path)
        payload = json.loads(self._path.read_text(encoding="utf-8"))
        self.version = str(payload.get("version", "unknown")).strip() or "unknown"
        self.section_order = tuple(str(section).strip() for section in payload.get("section_order", []) if str(section).strip())
        self.section_aliases = {
            _normalized_component(str(key)): str(value).strip()
            for key, value in payload.get("section_aliases", {}).items()
            if str(key).strip() and str(value).strip()
        }
        self.defaults = tuple(
            PolicyDefault.from_dict(entry)
            for entry in payload.get("component_defaults", [])
            if isinstance(entry, dict)
        )
        self.fallbacks = tuple(
            PolicyFallbackRule.from_dict(entry)
            for entry in payload.get("fallback_rules", [])
            if isinstance(entry, dict)
        )
        self.room_templates = tuple(
            RoomTemplate.from_dict(entry)
            for entry in payload.get("room_templates", [])
            if isinstance(entry, dict)
        )

    @property
    def path(self) -> Path:
        return self._path

    def to_rule_rows(self) -> list[tuple[str, dict[str, Any]]]:
        payload = json.loads(self._path.read_text(encoding="utf-8"))
        rows: list[tuple[str, dict[str, Any]]] = [("policy_document", payload)]
        for index, entry in enumerate(payload.get("component_defaults", []), start=1):
            rows.append((f"default:{index}", entry))
        for index, entry in enumerate(payload.get("fallback_rules", []), start=1):
            rows.append((f"fallback:{index}", entry))
        for index, entry in enumerate(payload.get("room_templates", []), start=1):
            rows.append((f"room_template:{index}", entry))
        return rows

    def canonical_component(self, component: str, surface: str = "") -> str:
        return _normalized_component(component or surface)

    def canonical_intent(self, intent: str) -> str:
        return _normalized_intent(intent)

    def default_for(self, component: str, intent: str, surface: str = "", room_scope: bool = False) -> PolicyDefault | None:
        normalized_component = self.canonical_component(component, surface)
        normalized_intent = self.canonical_intent(intent)
        normalized_surface = self.canonical_component(surface or component)
        for entry in self.defaults:
            if entry.component != normalized_component:
                continue
            if entry.intent != normalized_intent:
                continue
            if entry.surface and entry.surface != normalized_surface:
                continue
            if entry.room_scope and not room_scope:
                continue
            return entry
        return None

    def fallback_for(self, component: str, intent: str, surface: str = "") -> PolicyFallbackRule | None:
        normalized_component = self.canonical_component(component, surface)
        normalized_intent = self.canonical_intent(intent)
        normalized_surface = self.canonical_component(surface or component)
        for entry in self.fallbacks:
            if entry.component != normalized_component:
                continue
            if entry.intent != normalized_intent:
                continue
            if entry.surface and entry.surface != normalized_surface:
                continue
            return entry
        return None

    def room_template_for(self, loss_type: str, room_type: str) -> RoomTemplate | None:
        normalized_loss = _normalized(loss_type or "generic")
        normalized_room = _normalized(room_type or "generic")
        for entry in self.room_templates:
            if entry.loss_type == normalized_loss and entry.room_type == normalized_room:
                return entry
        for entry in self.room_templates:
            if entry.loss_type == normalized_loss and entry.room_type == "generic":
                return entry
        for entry in self.room_templates:
            if entry.loss_type == "generic" and entry.room_type == normalized_room:
                return entry
        for entry in self.room_templates:
            if entry.loss_type == "generic" and entry.room_type == "generic":
                return entry
        return None

    def recommended_section(self, component: str, surface: str = "") -> str:
        normalized_component = self.canonical_component(component, surface)
        if normalized_component in self.section_aliases:
            return self.section_aliases[normalized_component]
        return normalized_component.replace("_", " ").title() or "Scope"

    def rerank_candidates(
        self,
        *,
        component: str,
        intent: str,
        surface: str,
        room_scope: bool,
        candidates: list[RecommendationCandidate],
        load_item: callable | None = None,
    ) -> list[RecommendationCandidate]:
        default_rule = self.default_for(component, intent, surface, room_scope)
        fallback_rule = self.fallback_for(component, intent, surface)

        by_code: dict[str, RecommendationCandidate] = {candidate.item.code: candidate for candidate in candidates}

        preferred_codes: list[str] = []
        if default_rule is not None:
            preferred_codes.extend(default_rule.preferred_codes)
        if fallback_rule is not None:
            preferred_codes.extend(code for code in fallback_rule.preferred_codes if code not in preferred_codes)

        if load_item is not None:
            for code in preferred_codes:
                if code in by_code:
                    continue
                try:
                    item = load_item(code)
                except Exception:
                    continue
                by_code[code] = RecommendationCandidate(
                    item=item,
                    score=0.0,
                    confidence="medium",
                    matched_terms=(code,),
                    reasons=("Injected from policy defaults.",),
                    highlights=(),
                )

        blocked_codes = set(fallback_rule.blocked_codes if fallback_rule is not None else ())
        blocked_terms = set(fallback_rule.blocked_terms if fallback_rule is not None else ())

        rescored: list[RecommendationCandidate] = []
        for candidate in by_code.values():
            if candidate.item.code in blocked_codes:
                continue
            item_text = _normalized(" ".join([candidate.item.description, candidate.item.details, candidate.item.selector]))
            if blocked_terms and any(term and term in item_text for term in blocked_terms):
                continue

            score = float(candidate.score)
            reasons = list(candidate.reasons)
            confidence = candidate.confidence

            if candidate.item.code in preferred_codes:
                score += 75.0
                reasons.append("Policy-preferred code for this component and intent.")
                confidence = "high"

            rescored.append(
                RecommendationCandidate(
                    item=candidate.item,
                    score=round(score, 2),
                    confidence=confidence,
                    matched_terms=candidate.matched_terms,
                    reasons=tuple(dict.fromkeys(reasons)),
                    highlights=candidate.highlights,
                )
            )

        rescored.sort(key=lambda candidate: (-candidate.score, candidate.item.code))
        return rescored

    def policy_defaults_payload(self, component: str, intent: str, surface: str = "", room_scope: bool = False) -> dict[str, Any]:
        default_rule = self.default_for(component, intent, surface, room_scope)
        fallback_rule = self.fallback_for(component, intent, surface)
        return {
            "component": self.canonical_component(component, surface),
            "intent": self.canonical_intent(intent),
            "surface": self.canonical_component(surface or component),
            "room_scope": room_scope,
            "default_rule": None if default_rule is None else {
                "preferred_codes": list(default_rule.preferred_codes),
                "quantity": default_rule.quantity,
                "section": default_rule.section or self.recommended_section(component, surface),
                "notes": default_rule.notes,
            },
            "fallback_rule": None if fallback_rule is None else {
                "preferred_codes": list(fallback_rule.preferred_codes),
                "blocked_codes": list(fallback_rule.blocked_codes),
                "blocked_terms": list(fallback_rule.blocked_terms),
                "notes": fallback_rule.notes,
            },
        }

    def allowed_fallbacks_payload(self, component: str, intent: str, surface: str = "") -> dict[str, Any]:
        fallback_rule = self.fallback_for(component, intent, surface)
        return {
            "component": self.canonical_component(component, surface),
            "intent": self.canonical_intent(intent),
            "surface": self.canonical_component(surface or component),
            "preferred_codes": list(fallback_rule.preferred_codes) if fallback_rule is not None else [],
            "blocked_codes": list(fallback_rule.blocked_codes) if fallback_rule is not None else [],
            "blocked_terms": list(fallback_rule.blocked_terms) if fallback_rule is not None else [],
            "notes": fallback_rule.notes if fallback_rule is not None else "",
        }

    def room_template_payload(self, loss_type: str, room_type: str) -> dict[str, Any]:
        template = self.room_template_for(loss_type, room_type)
        return {
            "loss_type": _normalized(loss_type or "generic"),
            "room_type": _normalized(room_type or "generic"),
            "sections": list(template.sections) if template is not None else list(self.section_order),
            "notes": "" if template is None else template.notes,
        }

    def verify_room(
        self,
        *,
        room_summary: str,
        items: list[Any],
    ) -> PolicyVerification:
        normalized_summary = _normalized(room_summary)
        missing: list[str] = []
        violations: list[str] = []
        warnings: list[str] = []

        expected_pairs = self._expected_component_intents(normalized_summary)
        if expected_pairs:
            for component, intent in expected_pairs:
                if not self._room_has_match(items, component, intent):
                    missing.append(f"Missing {intent} for {component}.")

        for item in items:
            fallback_rule = self.fallback_for(item.surface or item.section, item.damage_type, item.surface or item.section)
            if fallback_rule is None:
                continue
            if item.approved_code in fallback_rule.blocked_codes:
                violations.append(f"{item.approved_code} is blocked by policy for {item.surface or item.section} {item.damage_type}.")

        if "clean" in normalized_summary and "paint" in normalized_summary:
            by_component: dict[str, set[str]] = {}
            for item in items:
                component = self.canonical_component(item.surface or item.section)
                by_component.setdefault(component, set()).add(self.canonical_intent(item.damage_type))
            for component, intents in by_component.items():
                if "paint" in intents and "clean" not in intents and component in {"wall", "ceiling", "baseboard", "trim"}:
                    warnings.append(f"{component.title()} has paint without a separate clean item.")

        return PolicyVerification(
            missing_intents=tuple(dict.fromkeys(missing)),
            policy_violations=tuple(dict.fromkeys(violations)),
            warnings=tuple(dict.fromkeys(warnings)),
        )

    def _expected_component_intents(self, summary: str) -> list[tuple[str, str]]:
        intents_present = {
            intent
            for intent in ("clean", "paint", "seal", "patch", "detach_reset", "reset", "replace", "remove")
            if intent.replace("_", " ") in summary or intent.split("_")[0] in summary
        }
        component_tokens = {
            component
            for component in ("wall", "ceiling", "baseboard", "trim", "crown", "chair_rail", "door", "casing", "floor", "carpet", "cabinet")
            if component.replace("_", " ") in summary or component.split("_")[0] in summary
        }
        pairs: list[tuple[str, str]] = []
        for component in sorted(component_tokens):
            for intent in sorted(intents_present):
                if component in {"baseboard", "trim", "crown", "chair_rail"} and intent in {"clean", "paint", "detach_reset", "reset", "replace"}:
                    pairs.append((component, intent))
                elif component in {"wall", "ceiling"} and intent in {"clean", "paint", "seal", "patch"}:
                    pairs.append((component, intent))
                elif component in {"floor", "carpet"} and intent in {"clean", "replace", "reset"}:
                    pairs.append((component, intent))
                elif component in {"door", "casing", "cabinet"} and intent in {"clean", "paint", "remove", "reset"}:
                    pairs.append((component, intent))
        return pairs

    def _room_has_match(self, items: list[Any], component: str, intent: str) -> bool:
        for item in items:
            item_component = self.canonical_component(item.surface or item.section)
            item_intent = self.canonical_intent(item.damage_type or item.activity)
            if component == "trim" and item_component in {"baseboard", "crown", "chair_rail", "trim", "casing"} and item_intent == intent:
                return True
            if item_component == component and item_intent == intent:
                return True
        return False

