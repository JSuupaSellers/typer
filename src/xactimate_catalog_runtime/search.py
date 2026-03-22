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
            tokens=frozenset(SearchTokenizer.tokenize(query.combined_text)),
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

        item_text_matches = query.tokens.intersection(
            SearchTokenizer.tokenize(
                " ".join(
                    [
                        source.item.code,
                        source.item.description,
                        source.item.details,
                        source.item.unit,
                    ]
                )
            )
        )
        if item_text_matches:
            total_score += len(item_text_matches) * 5.0
            matched_terms.update(item_text_matches)
            reasons.append(f"Item text matches: {', '.join(sorted(item_text_matches))}")

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
            return _StructuredReason(
                text=f"{label} partial match: {display}",
                terms=terms,
                weight=weight * 0.65,
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


class SearchTokenizer:
    _TOKEN_PATTERN = re.compile(r"[A-Za-z0-9]+")
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
        if len(token) >= 5 and token.endswith("ing"):
            return token[:-3]
        if len(token) >= 4 and token.endswith("ed"):
            return token[:-2]
        if len(token) >= 4 and token.endswith("es"):
            return token[:-2]
        if len(token) >= 3 and token.endswith("s"):
            return token[:-1]
        return token

