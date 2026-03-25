from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import httpx


class TranscriptionServiceProtocol(Protocol):
    async def transcribe_audio(self, filename: str, content: bytes, prompt: str = "") -> str:
        ...


@dataclass(slots=True, frozen=True)
class TranscriptionConfig:
    base_url: str
    api_key: str
    model: str
    timeout_s: float


class OpenAITranscriptionError(RuntimeError):
    pass


class OpenAITranscriptionService:
    def __init__(self, config: TranscriptionConfig, client: httpx.AsyncClient | None = None) -> None:
        self._config = config
        self._client = client

    async def transcribe_audio(self, filename: str, content: bytes, prompt: str = "") -> str:
        endpoint = self._config.base_url.rstrip("/") + "/audio/transcriptions"
        headers = {"Authorization": f"Bearer {self._config.api_key.strip()}"}
        data = {
            "model": self._config.model.strip(),
            "response_format": "json",
        }
        if prompt.strip():
            data["prompt"] = prompt.strip()

        files = {
            "file": (
                Path(filename).name or "recording.m4a",
                content,
                _guess_mime_type(filename),
            )
        }

        if self._client is not None:
            response = await self._client.post(endpoint, headers=headers, data=data, files=files)
        else:
            async with httpx.AsyncClient(timeout=self._config.timeout_s) as client:
                response = await client.post(endpoint, headers=headers, data=data, files=files)

        if response.status_code < 200 or response.status_code >= 300:
            raise OpenAITranscriptionError(
                f"Transcription request failed with status {response.status_code}: {response.text}"
            )

        payload = response.json()
        if not isinstance(payload, dict) or not isinstance(payload.get("text"), str):
            raise OpenAITranscriptionError("Transcription response did not include a text field.")
        return payload["text"].strip()


def default_adjuster_prompt() -> str:
    return (
        "This audio is an insurance adjuster describing room damage and repair scope for Xactimate. "
        "Keep room names, dimensions, CAT/SEL shorthand, and restoration vocabulary accurate."
    )


def default_direct_output_prompt() -> str:
    return (
        "This audio is a spoken prompt that will be turned into polished plain text for typing on another computer. "
        "Preserve punctuation, names, quoted wording, and paragraph intent accurately."
    )


def _guess_mime_type(filename: str) -> str:
    lowered = filename.lower()
    if lowered.endswith(".wav"):
        return "audio/wav"
    if lowered.endswith(".mp3"):
        return "audio/mpeg"
    if lowered.endswith(".m4a") or lowered.endswith(".mp4"):
        return "audio/mp4"
    return "application/octet-stream"
