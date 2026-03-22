from __future__ import annotations

from pathlib import Path
from urllib.parse import quote

import httpx

from .models import CatalogLineItem, EstimateScopeItem, RecommendationCandidate


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
        payload = {
            "query": scope_item.description,
            "room": scope_item.room,
            "surface": scope_item.surface,
            "damage_type": scope_item.damage_type,
            "keywords": scope_item.keywords,
            "limit": limit,
        }
        response = self._request("POST", "/recommend", json=payload)
        body = response.json()
        if not isinstance(body, list):
            raise RuntimeClientError("Runtime API /recommend did not return a list.")
        return [RecommendationCandidate.from_api_payload(item) for item in body if isinstance(item, dict)]

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

