from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import json
from typing import Any, Protocol
from uuid import uuid4

import httpx

from .config import ProducerConfig
from .models import CompiledCommand, PublishResult, QueueSnapshot


def _now_stamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%d-%H%M%S")


def _json_schema(name: str, schema: dict[str, Any]) -> dict[str, Any]:
    return {"format": {"type": "json_schema", "name": name, "strict": True, "schema": schema}}


def _parse_json(text: str) -> dict[str, Any]:
    cleaned = text.strip()
    if not cleaned:
        return {}
    try:
        payload = json.loads(cleaned)
        return payload if isinstance(payload, dict) else {}
    except json.JSONDecodeError:
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start >= 0 and end > start:
            try:
                payload = json.loads(cleaned[start : end + 1])
                return payload if isinstance(payload, dict) else {}
            except json.JSONDecodeError:
                return {}
    return {}


def _output_text(response: dict[str, Any]) -> str:
    if isinstance(response.get("output_text"), str) and response["output_text"].strip():
        return response["output_text"]
    texts: list[str] = []
    for item in response.get("output", []):
        if not isinstance(item, dict) or item.get("type") != "message":
            continue
        for content in item.get("content", []):
            if not isinstance(content, dict):
                continue
            text = content.get("text")
            if isinstance(text, str) and text.strip():
                texts.append(text)
    return "\n".join(texts).strip()


class DirectOutputPublisherProtocol(Protocol):
    def snapshot(self, bridge_id: str) -> QueueSnapshot:
        ...

    def publish_commands(
        self,
        *,
        bridge_id: str,
        job_id: str,
        commands: tuple[CompiledCommand, ...],
        approved_codes: tuple[str, ...] = (),
    ) -> PublishResult:
        ...


class BridgeNotReadyError(RuntimeError):
    pass


@dataclass(frozen=True)
class DirectComposeResult:
    bridge_id: str
    title: str
    assistant_reply: str
    prompt: str
    transcript: str
    text: str
    send_enter: bool
    command_count_preview: int
    character_count: int
    line_count: int
    warnings: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "bridge_id": self.bridge_id,
            "title": self.title,
            "assistant_reply": self.assistant_reply,
            "prompt": self.prompt,
            "transcript": self.transcript,
            "text": self.text,
            "send_enter": self.send_enter,
            "command_count_preview": self.command_count_preview,
            "character_count": self.character_count,
            "line_count": self.line_count,
            "warnings": list(self.warnings),
        }


@dataclass(frozen=True)
class DirectPublishEnvelope:
    publish: PublishResult
    title: str
    text: str
    send_enter: bool
    character_count: int
    line_count: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "publish": self.publish.to_dict(),
            "title": self.title,
            "text": self.text,
            "send_enter": self.send_enter,
            "character_count": self.character_count,
            "line_count": self.line_count,
        }


class DirectOutputService:
    def __init__(
        self,
        config: ProducerConfig,
        publisher: DirectOutputPublisherProtocol | None = None,
    ) -> None:
        self._config = config
        self._publisher = publisher

    async def compose(self, *, prompt: str, bridge_id: str = "default", transcript: str = "") -> DirectComposeResult:
        cleaned_prompt = prompt.strip()
        cleaned_transcript = transcript.strip()
        if not cleaned_prompt and not cleaned_transcript:
            raise RuntimeError("A prompt or transcript is required.")
        if not self._config.openai_api_key.strip():
            raise RuntimeError("OpenAI is not configured for direct output compose.")

        response = await self._create_response(
            {
                "model": self._config.agent_model,
                "reasoning": {"effort": self._config.agent_reasoning_effort},
                "input": [
                    {
                        "role": "system",
                        "content": [{"type": "input_text", "text": self._system_prompt()}],
                    },
                    {
                        "role": "user",
                        "content": [{"type": "input_text", "text": self._user_prompt(cleaned_prompt, cleaned_transcript)}],
                    },
                ],
                "store": True,
                "text": _json_schema(
                    "direct_output_compose",
                    {
                        "type": "object",
                        "properties": {
                            "title": {"type": "string"},
                            "assistant_reply": {"type": "string"},
                            "text": {"type": "string"},
                            "send_enter": {"type": "boolean"},
                        },
                        "required": ["title", "assistant_reply", "text", "send_enter"],
                        "additionalProperties": False,
                    },
                ),
                "max_output_tokens": 8_000,
            }
        )
        payload = _parse_json(_output_text(response))
        if not payload:
            raise RuntimeError("OpenAI direct output compose returned an invalid response.")

        text = self._normalize_text(str(payload.get("text", "")))
        if not text:
            raise RuntimeError("OpenAI direct output compose returned an empty text payload.")
        send_enter = bool(payload.get("send_enter", False))
        preview_commands = self.compile_text_commands(
            text=text,
            starting_seq=1,
            append_enter=send_enter,
        )
        return DirectComposeResult(
            bridge_id=bridge_id.strip() or "default",
            title=str(payload.get("title", "")).strip() or "Typed Output",
            assistant_reply=str(payload.get("assistant_reply", "")).strip() or "Drafted text ready for review.",
            prompt=cleaned_prompt,
            transcript=cleaned_transcript,
            text=text,
            send_enter=send_enter,
            command_count_preview=len(preview_commands),
            character_count=len(text),
            line_count=max(text.count("\n") + 1, 1),
        )

    def publish_text(
        self,
        *,
        bridge_id: str,
        text: str,
        title: str = "",
        append_enter: bool = False,
    ) -> DirectPublishEnvelope:
        if self._publisher is None:
            raise RuntimeError("Firebase publish is not configured for direct output.")
        normalized_text = self._normalize_text(text)
        if not normalized_text:
            raise RuntimeError("There is no text to send to the Pi.")

        bridge = bridge_id.strip() or "default"
        snapshot = self._publisher.snapshot(bridge)
        if not snapshot.bridge_online:
            raise BridgeNotReadyError(
                f"Bridge {bridge} is offline or stale. Make sure the Pi bridge is running before sending direct output."
            )
        if not snapshot.bridge_ready:
            raise BridgeNotReadyError(
                f"Bridge {bridge} is still busy with {snapshot.pending_command_count} pending command(s). Wait for it to go idle."
            )
        commands = self.compile_text_commands(
            text=normalized_text,
            starting_seq=1,
            append_enter=append_enter,
        )
        job_id = f"direct-{_now_stamp()}-{uuid4().hex[:6]}"
        publish = self._publisher.publish_commands(
            bridge_id=bridge,
            job_id=job_id,
            commands=commands,
        )
        return DirectPublishEnvelope(
            publish=publish,
            title=title.strip() or "Typed Output",
            text=normalized_text,
            send_enter=append_enter,
            character_count=len(normalized_text),
            line_count=max(normalized_text.count("\n") + 1, 1),
        )

    def compile_text_commands(
        self,
        *,
        text: str,
        starting_seq: int = 1,
        append_enter: bool = False,
    ) -> tuple[CompiledCommand, ...]:
        normalized = self._normalize_text(text)
        if not normalized:
            return ()

        commands: list[CompiledCommand] = []
        seq = starting_seq
        key_delay = self._config.direct_output_key_delay_ms
        if len(normalized) >= self._config.direct_output_long_text_threshold_chars:
            key_delay = self._config.direct_output_long_key_delay_ms
        commands.append(
            CompiledCommand(
                seq=seq,
                kind="upall",
                delay_after_ms=self._config.direct_output_initial_delay_ms,
                metadata={"mode": "direct_output", "command_role": "reset_modifiers"},
            )
        )
        seq += 1

        lines = normalized.split("\n")
        for index, line in enumerate(lines):
            for character in line:
                commands.append(
                    CompiledCommand(
                        seq=seq,
                        kind="key",
                        key=self._key_token_for_character(character),
                        delay_after_ms=self._delay_for_character(character, key_delay),
                        metadata={"mode": "direct_output", "command_role": "type_key"},
                    )
                )
                seq += 1
            if index < len(lines) - 1:
                commands.append(
                    CompiledCommand(
                        seq=seq,
                        kind="key",
                        key="ENTER",
                        delay_after_ms=self._config.direct_output_line_break_delay_ms,
                        metadata={"mode": "direct_output", "command_role": "line_break"},
                    )
                )
                seq += 1

        if append_enter:
            commands.append(
                CompiledCommand(
                    seq=seq,
                    kind="key",
                    key="ENTER",
                    delay_after_ms=self._config.direct_output_submit_delay_ms,
                    metadata={"mode": "direct_output", "command_role": "submit"},
                )
            )

        return tuple(commands)

    async def _create_response(self, payload: dict[str, Any]) -> dict[str, Any]:
        endpoint = self._config.openai_base_url.rstrip("/") + "/responses"
        headers = {
            "Authorization": f"Bearer {self._config.openai_api_key.strip()}",
            "Content-Type": "application/json",
        }
        timeout_s = max(float(self._config.request_timeout_s), 90.0)
        try:
            async with httpx.AsyncClient(timeout=timeout_s) as client:
                response = await client.post(endpoint, headers=headers, json=payload)
        except httpx.TimeoutException as exc:
            raise RuntimeError(f"OpenAI direct output compose timed out after {timeout_s:.0f}s.") from exc
        except httpx.HTTPError as exc:
            raise RuntimeError(f"OpenAI direct output compose request failed: {exc}") from exc
        if response.status_code < 200 or response.status_code >= 300:
            raise RuntimeError(
                f"OpenAI direct output compose failed with status {response.status_code}: {response.text}"
            )
        data = response.json()
        if not isinstance(data, dict):
            raise RuntimeError("OpenAI direct output compose response was not a JSON object.")
        return data

    @staticmethod
    def _normalize_text(text: str) -> str:
        normalized = text.replace("\r\n", "\n").replace("\r", "\n")
        replacements = {
            "\u00a0": " ",
            "\u2018": "'",
            "\u2019": "'",
            "\u201c": '"',
            "\u201d": '"',
            "\u2013": "-",
            "\u2014": "-",
        }
        for original, replacement in replacements.items():
            normalized = normalized.replace(original, replacement)
        return normalized.strip("\n")

    @staticmethod
    def _key_token_for_character(character: str) -> str:
        if character == "\t":
            return "TAB"
        return character

    @staticmethod
    def _delay_for_character(character: str, default_delay_ms: int) -> int:
        if character == " ":
            return max(default_delay_ms // 2, 10)
        if character in {".", ",", "!", "?", ";", ":"}:
            return default_delay_ms + 12
        return default_delay_ms

    @staticmethod
    def _system_prompt() -> str:
        return (
            "You draft plain text that will be typed verbatim on a remote computer by a Raspberry Pi and Teensy keyboard bridge. "
            "Turn the user's request into the exact text that should be typed. "
            "Return only structured JSON. "
            "Write polished, sanitized plain text with no markdown fences, no bullet formatting unless the user explicitly wants bullets, "
            "and no commentary inside the typed text. "
            "If the user asks for an email or message, draft the body unless they explicitly ask for a subject line. "
            "Keep paragraph breaks when helpful. "
            "Set send_enter to true only when the user clearly wants the bridge to press Enter after typing. "
            "Do not set send_enter true for normal email drafting, chat drafting, or note writing unless the user explicitly asks to submit."
        )

    @staticmethod
    def _user_prompt(prompt: str, transcript: str) -> str:
        if prompt and transcript:
            return (
                f"Typed hint or instruction:\n{prompt}\n\n"
                f"Voice transcript to interpret:\n{transcript}\n"
            )
        if transcript:
            return f"Voice transcript to interpret:\n{transcript}\n"
        return f"Instruction to interpret:\n{prompt}\n"
