from __future__ import annotations

from dataclasses import dataclass
import re
import unicodedata

from .models import RecommendationCandidate, RecommendationQuery, RecommendationScenarioHighlight, RuntimeItem, RuntimeScenario


@dataclass(frozen=True)
class RecommendationSourceItem:
    item: RuntimeItem
    scenarios: tuple[RuntimeScenario, ...]


@dataclass(frozen=True)
class _NormalizedRecommendationQuery:
    room: str
    surface: str
    damage_type: str
    tokens: frozenset[str]

    @classmethod
    def from_query(cls, query: RecommendationQuery) -> "_NormalizedRecommendationQuery":
        return cls(
            room=query.room.strip(),
            surface=query.surface.strip(),
            damage_type=query.damage_type.strip(),
            tokens=frozenset(
                SearchTokenizer.query_tokens(
                    query.query,
                    query.room,
                    query.surface,
                    query.damage_type,
                    query.keywords,
                )
            ),
        )

    @property
    def is_empty(self) -> bool:
        return not self.room and not self.surface and not self.damage_type and not self.tokens


@dataclass(frozen=True)
class _ScoredScenario:
    highlight: RecommendationScenarioHighlight
    reasons: tuple[str, ...]


@dataclass(frozen=True)
class _StructuredReason:
    text: str
    terms: frozenset[str]
    weight: float


class RecommendationEngine:
    _PAINT_SPECIALTY_HINTS = frozenset(
        {
            "acoustic",
            "popcorn",
            "tile",
            "grid",
            "medallion",
            "handrail",
            "niche",
            "epoxy",
            "elastomeric",
            "wallpaper",
            "joist",
        }
    )
    _CLEAN_SPECIALTY_HINTS = frozenset(
        {
            "acoustic",
            "popcorn",
            "texture",
            "textur",
            "suspended",
            "grid",
            "tile",
            "handrail",
            "baseboard",
            "crown",
            "chair",
            "trim",
            "door",
            "blind",
            "cabinet",
            "fixture",
        }
    )
    _ACTION_FAMILIES = {
        "clean": frozenset({"clean", "wash", "wipe", "scrub", "soot", "deodor"}),
        "paint": frozenset({"paint", "prime", "seal", "shellac", "coat", "repaint"}),
        "patch": frozenset({"patch", "repair", "drywall", "texture", "tape", "mud", "float"}),
        "reset": frozenset({"detach", "reset", "remove", "reinstall", "replace"}),
    }
    _SURFACE_PROFILES = {
        "ceiling": {
            "preferred": frozenset({"ceil", "acoustic", "popcorn", "texture", "textur", "grid", "tile", "suspended"}),
            "blocked": frozenset({"fan", "light", "fixture", "medallion"}),
        },
        "wall": {
            "preferred": frozenset({"wall", "wallpaper", "stud", "foundation", "drywall", "plaster"}),
            "blocked": frozenset({"ac", "unit", "heater", "hanging", "shelf", "handrail", "cover", "blind", "window", "door", "opening", "cove"}),
        },
        "baseboard": {
            "preferred": frozenset({"baseboard"}),
            "blocked": frozenset({"heater"}),
        },
        "trim": {
            "preferred": frozenset({"trim", "crown", "chair", "corner", "casing", "baseboard", "molding"}),
            "blocked": frozenset({"heater", "blind", "window", "door", "fan"}),
        },
        "door": {
            "preferred": frozenset({"door", "jamb", "casing", "open"}),
            "blocked": frozenset({"window", "blind", "heater", "fan"}),
        },
        "floor": {
            "preferred": frozenset({"floor", "carpet", "tile", "wood", "vinyl", "lvp", "laminate"}),
            "blocked": frozenset({"wall", "ceiling", "baseboard"}),
        },
    }

    def recommend(
        self,
        query: RecommendationQuery,
        sources: list[RecommendationSourceItem],
    ) -> list[RecommendationCandidate]:
        normalized = _NormalizedRecommendationQuery.from_query(query)
        if normalized.is_empty:
            return []

        ranked = [
            candidate
            for source in sources
            if (candidate := self._candidate(source, normalized)) is not None
        ]
        ranked.sort(key=lambda candidate: (-candidate.score, candidate.item.code))
        return ranked[: max(1, min(query.limit, 20))]

    def _candidate(
        self,
        source: RecommendationSourceItem,
        query: _NormalizedRecommendationQuery,
    ) -> RecommendationCandidate | None:
        total_score = 0.0
        reasons: list[str] = []
        matched_terms: set[str] = set()

        code_terms = SearchTokenizer.tokenize(" ".join([source.item.code, source.item.category, source.item.selector]))
        description_terms = SearchTokenizer.tokenize(source.item.description)
        detail_terms = SearchTokenizer.tokenize(source.item.details)

        code_matches = query.tokens.intersection(code_terms)
        if code_matches:
            total_score += len(code_matches) * 8.0
            matched_terms.update(code_matches)
            reasons.append(f"Code/category matches: {', '.join(sorted(code_matches))}")

        description_matches = query.tokens.intersection(description_terms)
        if description_matches:
            total_score += len(description_matches) * 7.0
            matched_terms.update(description_matches)
            reasons.append(f"Description matches: {', '.join(sorted(description_matches))}")

        detail_matches = query.tokens.intersection(detail_terms) - description_matches - code_matches
        if detail_matches:
            total_score += len(detail_matches) * 0.5
            matched_terms.update(detail_matches)
            reasons.append(f"Detail matches: {', '.join(sorted(detail_matches))}")

        preferred_categories = SearchTokenizer.preferred_categories(query.tokens)
        if preferred_categories:
            if source.item.category in preferred_categories:
                total_score += 12.0
                reasons.append(f"Category intent matches: {source.item.category}")
            else:
                total_score -= 10.0

        for item_reason in (
            self._field_overlap_reason(query.surface, source.item.description, "Surface", 6.0),
            self._field_overlap_reason(query.damage_type, source.item.description, "Damage", 6.0),
            self._field_overlap_reason(query.damage_type, source.item.details, "Damage context", 1.5),
        ):
            if item_reason is None:
                continue
            total_score += item_reason.weight
            reasons.append(item_reason.text)
            matched_terms.update(item_reason.terms)

        description_phrase_bonus, phrase_terms = self._phrase_bonus(source.item, query.tokens)
        if description_phrase_bonus > 0:
            total_score += description_phrase_bonus
            matched_terms.update(phrase_terms)
            reasons.append("Description strongly matches the requested scope.")

        generic_scope_bonus = self._generic_scope_bonus(source.item, query.tokens, preferred_categories)
        if generic_scope_bonus > 0:
            total_score += generic_scope_bonus
            reasons.append("Generic surface workflow matches the requested scope.")

        for item_reason in self._surface_alignment_reasons(source.item, query):
            total_score += item_reason.weight
            reasons.append(item_reason.text)
            if item_reason.weight > 0:
                matched_terms.update(item_reason.terms)

        action_reason = self._action_coverage_reason(source.item, query.tokens)
        if action_reason is not None:
            total_score += action_reason.weight
            reasons.append(action_reason.text)
            if action_reason.weight > 0:
                matched_terms.update(action_reason.terms)

        scored_scenarios = [
            scored
            for scenario in source.scenarios
            if (scored := self._score_scenario(scenario, query)) is not None
        ]
        scored_scenarios.sort(key=lambda scored: scored.highlight.score, reverse=True)

        if scored_scenarios:
            best = scored_scenarios[0]
            total_score += best.highlight.score
            matched_terms.update(best.highlight.matched_terms)
            reasons.extend(best.reasons)

        if len(source.scenarios) > 1:
            total_score += min((len(source.scenarios) - 1) * 1.5, 6.0)
            reasons.append("Multiple saved scenarios support this line item.")

        if source.item.usage_status == "used_before":
            total_score += 2.0
            reasons.append("Marked as used before in your catalog.")

        if total_score <= 0:
            return None

        highlights = tuple(scored.highlight for scored in scored_scenarios[:3])
        for highlight in highlights:
            matched_terms.update(highlight.matched_terms)

        unique_reasons = tuple(dict.fromkeys(reasons))
        confidence = self._confidence_level(total_score, highlights)
        return RecommendationCandidate(
            item=source.item,
            score=round(total_score, 2),
            confidence=confidence,
            matched_terms=tuple(sorted(matched_terms)),
            reasons=unique_reasons[:4],
            highlights=highlights,
        )

    def _score_scenario(
        self,
        scenario: RuntimeScenario,
        query: _NormalizedRecommendationQuery,
    ) -> _ScoredScenario | None:
        score = 0.0
        reasons: list[str] = []
        matched_terms: set[str] = set()

        for structured_reason in (
            self._structured_field_reason(query.room, scenario.room, "Room", 18.0),
            self._structured_field_reason(query.surface, scenario.surface, "Surface", 16.0),
            self._structured_field_reason(query.damage_type, scenario.damage_type, "Damage", 18.0),
        ):
            if structured_reason is None:
                continue
            score += structured_reason.weight
            reasons.append(structured_reason.text)
            matched_terms.update(structured_reason.terms)

        keyword_matches = query.tokens.intersection(
            SearchTokenizer.tokenize(
                " ".join([scenario.tags, scenario.keywords, scenario.synonyms])
            )
        )
        if keyword_matches:
            score += len(keyword_matches) * 6.0
            reasons.append(f"Matched playbook keywords: {', '.join(sorted(keyword_matches))}")
            matched_terms.update(keyword_matches)

        description_matches = query.tokens.intersection(
            SearchTokenizer.tokenize(
                " ".join([scenario.title, scenario.when_to_use, scenario.ai_hint])
            )
        )
        if description_matches:
            score += len(description_matches) * 3.0
            reasons.append("Scenario text overlaps your scope description.")
            matched_terms.update(description_matches)

        exclusion_matches = query.tokens.intersection(
            SearchTokenizer.tokenize(scenario.when_not_to_use)
        )
        if exclusion_matches:
            score -= len(exclusion_matches) * 4.0
            reasons.append(f"Caution from exclusions: {', '.join(sorted(exclusion_matches))}")

        if score <= 0:
            return None

        highlight = RecommendationScenarioHighlight(
            id=scenario.id,
            title=scenario.title,
            when_to_use=scenario.when_to_use,
            when_not_to_use=scenario.when_not_to_use,
            room=scenario.room,
            surface=scenario.surface,
            damage_type=scenario.damage_type,
            keywords=scenario.keywords,
            synonyms=scenario.synonyms,
            ai_hint=scenario.ai_hint,
            matched_terms=tuple(sorted(matched_terms)),
            score=round(score, 2),
        )
        return _ScoredScenario(highlight=highlight, reasons=tuple(reasons))

    def _structured_field_reason(
        self,
        query_value: str,
        scenario_value: str,
        label: str,
        weight: float,
    ) -> _StructuredReason | None:
        normalized_query = SearchTokenizer.normalize_phrase(query_value)
        normalized_scenario = SearchTokenizer.normalize_phrase(scenario_value)
        if not normalized_query or not normalized_scenario:
            return None

        terms = frozenset(SearchTokenizer.tokenize(scenario_value))
        display = scenario_value.strip()
        if normalized_query == normalized_scenario:
            return _StructuredReason(text=f"{label} match: {display}", terms=terms, weight=weight)
        if normalized_scenario in normalized_query or normalized_query in normalized_scenario:
            partial_factor = 0.65
            if label.lower() == "damage":
                partial_factor = 0.4
            return _StructuredReason(
                text=f"{label} partial match: {display}",
                terms=terms,
                weight=weight * partial_factor,
            )
        return None

    def _confidence_level(
        self,
        score: float,
        highlights: tuple[RecommendationScenarioHighlight, ...],
    ) -> str:
        if score >= 42 or (score >= 34 and highlights):
            return "high"
        if score >= 20:
            return "medium"
        return "low"

    def _field_overlap_reason(
        self,
        query_value: str,
        candidate_value: str,
        label: str,
        weight: float,
    ) -> _StructuredReason | None:
        query_terms = frozenset(SearchTokenizer.tokenize(query_value))
        if not query_terms:
            return None

        candidate_terms = frozenset(SearchTokenizer.tokenize(candidate_value))
        overlap = query_terms.intersection(candidate_terms)
        if not overlap:
            return None

        coverage = len(overlap) / max(1, len(query_terms))
        return _StructuredReason(
            text=f"{label} aligns with: {', '.join(sorted(overlap))}",
            terms=frozenset(overlap),
            weight=round(weight * coverage, 2),
        )

    def _generic_scope_bonus(
        self,
        item: RuntimeItem,
        tokens: frozenset[str],
        preferred_categories: set[str],
    ) -> float:
        if item.category == "PNT" and "PNT" in preferred_categories:
            if not tokens.intersection({"paint", "prime", "seal"}):
                return 0.0
            if not tokens.intersection({"wall", "ceil"}):
                return 0.0
            if item.selector in {"SP", "SP+", "SP2", "SP2+"}:
                if tokens.intersection(self._PAINT_SPECIALTY_HINTS):
                    return 6.0
                return 18.0

        if item.category == "CLN" and "CLN" in preferred_categories:
            if "clean" not in tokens:
                return 0.0
            if not tokens.intersection({"wall", "ceil"}):
                return 0.0
            if item.selector in {"AV", "AV+", "AV-"}:
                if tokens.intersection(self._CLEAN_SPECIALTY_HINTS):
                    return 8.0
                return 24.0

        return 0.0

    def _phrase_bonus(self, item: RuntimeItem, tokens: frozenset[str]) -> tuple[float, set[str]]:
        description_terms = SearchTokenizer.tokenize(" ".join([item.description, item.selector]))
        phrase_groups = [
            ({"paint", "ceil"}, 8.0),
            ({"paint", "wall"}, 8.0),
            ({"clean", "baseboard"}, 9.0),
            ({"clean", "trim"}, 8.0),
            ({"clean", "door"}, 8.0),
            ({"seal", "paint"}, 6.0),
            ({"drywall", "patch"}, 8.0),
            ({"carpet", "protect"}, 8.0),
            ({"protect", "coat", "carpet"}, 10.0),
            ({"acoustic", "ceil"}, 6.0),
        ]

        best_score = 0.0
        best_terms: set[str] = set()
        for group, score in phrase_groups:
            if group.issubset(tokens) and group.issubset(description_terms):
                if score > best_score:
                    best_score = score
                    best_terms = set(group)
        return best_score, best_terms

    def _surface_alignment_reasons(
        self,
        item: RuntimeItem,
        query: _NormalizedRecommendationQuery,
    ) -> tuple[_StructuredReason, ...]:
        surface_profile = self._surface_profile(query.surface, query.tokens)
        if surface_profile is None:
            return ()

        item_terms = SearchTokenizer.tokenize(" ".join([item.description, item.details, item.selector]))
        query_terms = set(query.tokens)
        preferred = item_terms.intersection(surface_profile["preferred"])
        blocked = item_terms.intersection(surface_profile["blocked"]) - query_terms

        reasons: list[_StructuredReason] = []
        if preferred:
            reasons.append(
                _StructuredReason(
                    text=f"Surface-specific fit: {', '.join(sorted(preferred))}",
                    terms=frozenset(preferred),
                    weight=min(10.0, 4.0 + (len(preferred) * 2.0)),
                )
            )

        if blocked:
            reasons.append(
                _StructuredReason(
                    text=f"Looks like a more specific component than the requested {surface_profile['label']} surface: {', '.join(sorted(blocked))}",
                    terms=frozenset(blocked),
                    weight=-min(18.0, 10.0 + (len(blocked) * 3.0)),
                )
            )

        return tuple(reasons)

    def _action_coverage_reason(
        self,
        item: RuntimeItem,
        tokens: frozenset[str],
    ) -> _StructuredReason | None:
        requested_families = {
            family
            for family, family_terms in self._ACTION_FAMILIES.items()
            if tokens.intersection(family_terms)
        }
        if len(requested_families) <= 1:
            return None

        item_terms = SearchTokenizer.tokenize(" ".join([item.description, item.details, item.selector]))
        covered_families = {
            family
            for family, family_terms in self._ACTION_FAMILIES.items()
            if item_terms.intersection(family_terms)
        }
        missing_families = requested_families - covered_families
        if not missing_families:
            return _StructuredReason(
                text="Matches multiple requested workflow intents.",
                terms=frozenset(requested_families),
                weight=4.0,
            )

        return _StructuredReason(
            text=f"Only covers part of the requested workflow: missing {', '.join(sorted(missing_families))}",
            terms=frozenset(missing_families),
            weight=-min(16.0, 8.0 * len(missing_families)),
        )

    def _surface_profile(
        self,
        surface_text: str,
        tokens: frozenset[str],
    ) -> dict[str, object] | None:
        surface_tokens = SearchTokenizer.tokenize(surface_text)
        token_pool = set(surface_tokens).union(tokens)

        if "baseboard" in token_pool:
            return {"label": "baseboard", **self._SURFACE_PROFILES["baseboard"]}
        if token_pool.intersection({"crown", "chair", "trim", "casing", "molding"}):
            return {"label": "trim", **self._SURFACE_PROFILES["trim"]}
        if token_pool.intersection({"door", "jamb", "open"}):
            return {"label": "door", **self._SURFACE_PROFILES["door"]}
        if token_pool.intersection({"ceil", "ceiling"}):
            return {"label": "ceiling", **self._SURFACE_PROFILES["ceiling"]}
        if token_pool.intersection({"floor", "carpet", "tile", "wood", "vinyl", "lvp", "laminate"}):
            return {"label": "floor", **self._SURFACE_PROFILES["floor"]}
        if token_pool.intersection({"wall", "wallpaper", "plaster", "drywall"}):
            return {"label": "wall", **self._SURFACE_PROFILES["wall"]}
        return None


class SearchTokenizer:
    _TOKEN_PATTERN = re.compile(r"[A-Za-z0-9]+")
    _SPECIAL_STEMS = {
        "protection": "protect",
        "protective": "protect",
        "protected": "protect",
        "coating": "coat",
        "coatings": "coat",
        "primer": "prime",
    }
    _STOP_WORDS = {
        "the", "and", "for", "with", "from", "into", "onto", "that", "this", "your", "you",
        "use", "used", "item", "line", "when", "where", "need", "needs", "after", "before",
        "area", "work", "room", "surface", "type", "scope", "small", "large", "full",
    }

    @classmethod
    def tokenize(cls, text: str) -> set[str]:
        normalized = cls.normalize_phrase(text)
        tokens = [cls._stemmed(token) for token in cls._TOKEN_PATTERN.findall(normalized)]
        return {token for token in tokens if len(token) >= 2 and token not in cls._STOP_WORDS}

    @classmethod
    def query_tokens(
        cls,
        query_text: str,
        room: str = "",
        surface: str = "",
        damage_type: str = "",
        keywords: str = "",
    ) -> set[str]:
        primary_tokens = cls.tokenize(" ".join(part for part in (query_text, surface, damage_type, keywords) if part))
        room_tokens = cls.tokenize(room)
        return primary_tokens - room_tokens

    @classmethod
    def preferred_categories(cls, tokens: set[str] | frozenset[str]) -> set[str]:
        preferred: set[str] = set()
        token_set = set(tokens)

        if token_set.intersection({"paint", "prime", "seal", "shellac", "coat", "repaint"}):
            preferred.add("PNT")
        if token_set.intersection({"drywall", "patch", "texture", "popcorn", "float", "tape", "mud"}):
            preferred.add("DRY")
        if token_set.intersection({"carpet", "clean", "deodorize", "protect", "coat"}):
            preferred.add("CLN")

        return preferred

    @staticmethod
    def normalize_phrase(text: str) -> str:
        return (
            unicodedata.normalize("NFKD", text)
            .encode("ascii", "ignore")
            .decode("ascii")
            .strip()
            .lower()
        )

    @staticmethod
    def _stemmed(token: str) -> str:
        special = SearchTokenizer._SPECIAL_STEMS.get(token)
        if special is not None:
            return special
        if len(token) >= 5 and token.endswith("ing"):
            return token[:-3]
        if len(token) >= 4 and token.endswith("ed"):
            return token[:-2]
        if len(token) >= 4 and token.endswith("es"):
            return token[:-2]
        if len(token) >= 3 and token.endswith("s"):
            return token[:-1]
        return token
