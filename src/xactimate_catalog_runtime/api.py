from __future__ import annotations

from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field

from .models import RecommendationQuery, RuntimeScenario, normalize_code
from .repository import RuntimeCatalogRepository


class SearchRequest(BaseModel):
    query: str = ""
    room: str = ""
    surface: str = ""
    damage_type: str = ""
    keywords: str = ""
    limit: int = Field(default=5, ge=1, le=20)


class ScenarioResponse(BaseModel):
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

    @classmethod
    def from_runtime(cls, scenario: RuntimeScenario) -> "ScenarioResponse":
        return cls(
            id=scenario.id,
            item_code=scenario.item_code,
            title=scenario.title,
            tags=scenario.tags,
            when_to_use=scenario.when_to_use,
            when_not_to_use=scenario.when_not_to_use,
            room=scenario.room,
            surface=scenario.surface,
            damage_type=scenario.damage_type,
            keywords=scenario.keywords,
            synonyms=scenario.synonyms,
            voice_notes=scenario.voice_notes,
            ai_hint=scenario.ai_hint,
        )


class ItemResponse(BaseModel):
    code: str
    category: str
    selector: str
    description: str
    unit: str
    details: str


class RecommendationHighlightResponse(BaseModel):
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
    matched_terms: list[str]
    score: float


class RecommendationCandidateResponse(BaseModel):
    item: ItemResponse
    score: float
    confidence: str
    matched_terms: list[str]
    reasons: list[str]
    highlights: list[RecommendationHighlightResponse]


class ItemDetailResponse(BaseModel):
    item: ItemResponse
    scenarios: list[ScenarioResponse]


def create_app(database_path: str | Path, api_key: str | None = None) -> FastAPI:
    repository = RuntimeCatalogRepository(database_path)
    app = FastAPI(title="Xactimate Catalog Runtime", version="0.1.0")
    app.state.repository = repository
    app.state.api_key = api_key

    def get_repository(request: Request) -> RuntimeCatalogRepository:
        return request.app.state.repository

    def authorize(
        request: Request,
        x_api_key: Annotated[str | None, Header()] = None,
    ) -> None:
        configured_key = request.app.state.api_key
        if configured_key and x_api_key != configured_key:
            raise HTTPException(status_code=401, detail="Invalid API key.")

    @app.get("/health")
    def health(
        _auth: None = Depends(authorize),
        repo: RuntimeCatalogRepository = Depends(get_repository),
    ) -> dict[str, int | str]:
        return repo.health()

    @app.get("/items/{code:path}/scenarios", response_model=list[ScenarioResponse])
    def get_item_scenarios(
        code: str,
        _auth: None = Depends(authorize),
        repo: RuntimeCatalogRepository = Depends(get_repository),
    ) -> list[ScenarioResponse]:
        return [ScenarioResponse.from_runtime(scenario) for scenario in repo.get_scenarios(code)]

    @app.get("/items/{code:path}", response_model=ItemDetailResponse)
    def get_item(
        code: str,
        _auth: None = Depends(authorize),
        repo: RuntimeCatalogRepository = Depends(get_repository),
    ) -> ItemDetailResponse:
        result = repo.get_item_with_scenarios(code)
        if result is None:
            raise HTTPException(status_code=404, detail=f"Unknown line item code: {normalize_code(code)}")

        item = result["item"]
        scenarios = result["scenarios"]
        return ItemDetailResponse(
            item=ItemResponse(**item.__dict__),
            scenarios=[ScenarioResponse.from_runtime(scenario) for scenario in scenarios],
        )

    @app.post("/search", response_model=list[RecommendationCandidateResponse])
    def search(
        payload: SearchRequest,
        _auth: None = Depends(authorize),
        repo: RuntimeCatalogRepository = Depends(get_repository),
    ) -> list[RecommendationCandidateResponse]:
        query = RecommendationQuery(
            query=payload.query,
            room=payload.room,
            surface=payload.surface,
            damage_type=payload.damage_type,
            keywords=payload.keywords,
            limit=payload.limit,
        )
        candidates = repo.search(query)
        return [_candidate_response(candidate) for candidate in candidates]

    @app.post("/recommend", response_model=list[RecommendationCandidateResponse])
    def recommend(
        payload: SearchRequest,
        _auth: None = Depends(authorize),
        repo: RuntimeCatalogRepository = Depends(get_repository),
    ) -> list[RecommendationCandidateResponse]:
        query = RecommendationQuery(
            query=payload.query,
            room=payload.room,
            surface=payload.surface,
            damage_type=payload.damage_type,
            keywords=payload.keywords,
            limit=payload.limit,
        )
        candidates = repo.search(query)
        return [_candidate_response(candidate) for candidate in candidates]

    return app


def _candidate_response(candidate) -> RecommendationCandidateResponse:
    return RecommendationCandidateResponse(
        item=ItemResponse(**candidate.item.__dict__),
        score=candidate.score,
        confidence=candidate.confidence,
        matched_terms=list(candidate.matched_terms),
        reasons=list(candidate.reasons),
        highlights=[
            RecommendationHighlightResponse(
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
                matched_terms=list(highlight.matched_terms),
                score=highlight.score,
            )
            for highlight in candidate.highlights
        ],
    )
