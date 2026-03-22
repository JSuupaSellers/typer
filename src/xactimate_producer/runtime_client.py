from __future__ import annotations

from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx

from .models import CatalogLineItem, EstimateScopeItem, RecommendationCandidate, confidence_rank


class RuntimeClientError(RuntimeError):
    pass


class RuntimeCatalogClient:
    def __init__(
        self,
        base_url: str,
        api_key: str = "",
        timeout_s: float = 20.0,
        client: httpx.Client | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key.strip()
        self._client = client or httpx.Client(base_url=self._base_url, timeout=timeout_s)
        self._owns_client = client is None

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> "RuntimeCatalogClient":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def recommend_for_item(self, scope_item: EstimateScopeItem, limit: int) -> list[RecommendationCandidate]:
        payload = self._recommend_payload(scope_item, limit)
        response = self._request("POST", "/recommend", json=payload)
        body = response.json()
        if not isinstance(body, list):
            raise RuntimeClientError("Runtime API /recommend did not return a list.")
        return [RecommendationCandidate.from_api_payload(item) for item in body if isinstance(item, dict)]

    def explore_strategies(
        self,
        scope_item: EstimateScopeItem,
        strategies: list[dict[str, Any]],
        default_limit: int,
    ) -> dict[str, Any]:
        strategy_results: list[dict[str, Any]] = []
        best_by_code: dict[str, RecommendationCandidate] = {}
        appearances: dict[str, int] = {}

        for index, strategy in enumerate(strategies, start=1):
            strategy_name = str(strategy.get("name", "")).strip() or f"strategy_{index}"
            strategy_scope = EstimateScopeItem(
                item_id=f"{scope_item.item_id}-strategy-{index}",
                description=str(strategy.get("query", "")).strip() or scope_item.description,
                room=str(strategy.get("room", "")).strip() or scope_item.room,
                section=str(strategy.get("section", "")).strip() or scope_item.section,
                surface=str(strategy.get("surface", "")).strip() or scope_item.surface,
                damage_type=str(strategy.get("damage_type", "")).strip() or scope_item.damage_type,
                keywords=str(strategy.get("keywords", "")).strip() or scope_item.keywords,
            )
            strategy_limit = max(int(strategy.get("limit", default_limit) or default_limit), 1)
            candidates = self.recommend_for_item(strategy_scope, strategy_limit)

            strategy_results.append(
                {
                    "name": strategy_name,
                    "search_request": self._recommend_payload(strategy_scope, strategy_limit) | {"section": strategy_scope.section},
                    "candidates": [candidate.to_dict() for candidate in candidates],
                }
            )

            seen_codes_for_strategy: set[str] = set()
            for candidate in candidates:
                code = candidate.item.code
                if code not in seen_codes_for_strategy:
                    appearances[code] = appearances.get(code, 0) + 1
                    seen_codes_for_strategy.add(code)

                existing = best_by_code.get(code)
                if existing is None or self._candidate_sort_key(candidate) > self._candidate_sort_key(existing):
                    best_by_code[code] = candidate

        combined_candidates = sorted(
            best_by_code.values(),
            key=self._candidate_sort_key,
            reverse=True,
        )[: max(5, min(default_limit * 2, 12))]

        overlap_codes = sorted(code for code, count in appearances.items() if count > 1)
        return {
            "base_search_request": self._recommend_payload(scope_item, default_limit) | {"section": scope_item.section},
            "strategy_results": strategy_results,
            "combined_candidates": [candidate.to_dict() for candidate in combined_candidates],
            "overlap_codes": overlap_codes,
        }

    def get_item(self, code: str) -> CatalogLineItem:
        normalized_code = code.strip().upper()
        encoded_code = quote(normalized_code, safe="")
        response = self._request("GET", f"/items/{encoded_code}")
        body = response.json()
        if not isinstance(body, dict) or not isinstance(body.get("item"), dict):
            raise RuntimeClientError(f"Runtime API /items/{normalized_code} returned an invalid payload.")
        return CatalogLineItem.from_api_payload(body["item"])

    def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        headers = dict(kwargs.pop("headers", {}))
        if self._api_key:
            headers["X-API-Key"] = self._api_key
        try:
            response = self._client.request(method, path, headers=headers, **kwargs)
            response.raise_for_status()
            return response
        except httpx.HTTPStatusError as exc:
            response_path = Path(exc.request.url.path).as_posix()
            raise RuntimeClientError(f"Runtime API request failed for {response_path}: {exc.response.status_code}") from exc
        except httpx.HTTPError as exc:
            raise RuntimeClientError(f"Runtime API request failed: {exc}") from exc

    @staticmethod
    def _recommend_payload(scope_item: EstimateScopeItem, limit: int) -> dict[str, Any]:
        return {
            "query": scope_item.description,
            "room": scope_item.room,
            "surface": scope_item.surface,
            "damage_type": scope_item.damage_type,
            "keywords": scope_item.keywords,
            "limit": limit,
        }

    @staticmethod
    def _candidate_sort_key(candidate: RecommendationCandidate) -> tuple[float, int, str]:
        return (candidate.score, confidence_rank(candidate.confidence), candidate.item.code)
