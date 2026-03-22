from __future__ import annotations

from dataclasses import dataclass
import json
from typing import Any

import httpx

from .config import ProducerConfig
from .drafts import DraftLineItem, DraftTurnResult, EstimateDraft
from .models import EstimateScopeItem


@dataclass(frozen=True)
class OpenAIDraftAgent:
    config: ProducerConfig
    runtime_client: Any

    async def apply_turn(self, draft: EstimateDraft, user_text: str) -> DraftTurnResult:
        response = await self._create_response(
            {
                "model": self.config.agent_model,
                "reasoning": {"effort": self.config.agent_reasoning_effort},
                "input": [
                    {
                        "role": "system",
                        "content": [{"type": "input_text", "text": self._system_prompt()}],
                    },
                    {
                        "role": "user",
                        "content": [{"type": "input_text", "text": self._user_prompt(draft, user_text)}],
                    },
                ],
                "tools": self._tool_definitions(),
                "tool_choice": "auto",
                "store": True,
                "max_output_tokens": 3000,
            }
        )
        response_id = str(response.get("id", "")).strip()

        while True:
            calls = self._function_calls(response)
            if not calls:
                break

            tool_outputs = []
            for call in calls:
                name = str(call.get("name", "")).strip()
                call_id = str(call.get("call_id", "")).strip()
                arguments = self._parse_json(str(call.get("arguments", "{}")))
                result = self._run_tool(name, arguments)
                tool_outputs.append(
                    {
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": json.dumps(result),
                    }
                )

            response = await self._create_response(
                {
                    "model": self.config.agent_model,
                    "previous_response_id": response_id,
                    "input": tool_outputs,
                    "tools": self._tool_definitions(),
                    "tool_choice": "auto",
                    "store": True,
                    "max_output_tokens": 3000,
                }
            )
            response_id = str(response.get("id", response_id)).strip() or response_id

        raw_output = self._output_text(response)
        payload = self._parse_json(raw_output)
        assistant_reply = str(payload.get("assistant_reply", "")).strip() or "Updated the draft."
        operations = payload.get("operations", [])
        updated = self._apply_operations(draft, operations)
        return DraftTurnResult(draft=updated, assistant_reply=assistant_reply)

    async def _create_response(self, payload: dict[str, Any]) -> dict[str, Any]:
        endpoint = self.config.openai_base_url.rstrip("/") + "/responses"
        headers = {
            "Authorization": f"Bearer {self.config.openai_api_key.strip()}",
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(timeout=self.config.request_timeout_s) as client:
            response = await client.post(endpoint, headers=headers, json=payload)
        if response.status_code < 200 or response.status_code >= 300:
            raise RuntimeError(f"OpenAI draft agent request failed with status {response.status_code}: {response.text}")
        data = response.json()
        if not isinstance(data, dict):
            raise RuntimeError("OpenAI draft agent response was not a JSON object.")
        return data

    def _tool_definitions(self) -> list[dict[str, Any]]:
        return [
            {
                "type": "function",
                "name": "search_line_items",
                "description": "Search the curated Xactimate catalog for the best CAT/SEL candidates for a described scope item.",
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "room": {"type": ["string", "null"]},
                        "section": {"type": ["string", "null"]},
                        "surface": {"type": ["string", "null"]},
                        "damage_type": {"type": ["string", "null"]},
                        "keywords": {"type": ["string", "null"]},
                        "limit": {"type": ["integer", "null"]},
                    },
                    "required": [
                        "query",
                        "room",
                        "section",
                        "surface",
                        "damage_type",
                        "keywords",
                        "limit",
                    ],
                    "additionalProperties": False,
                },
            },
            {
                "type": "function",
                "name": "get_line_item",
                "description": "Load a known CAT/SEL code and its details from the curated catalog.",
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "code": {"type": "string"},
                    },
                    "required": ["code"],
                    "additionalProperties": False,
                },
            },
        ]

    def _run_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "search_line_items":
            scope_item = EstimateScopeItem(
                item_id="tool-search",
                description=str(arguments.get("query", "")).strip(),
                room=str(arguments.get("room", "")).strip(),
                section=str(arguments.get("section", "")).strip(),
                surface=str(arguments.get("surface", "")).strip(),
                damage_type=str(arguments.get("damage_type", "")).strip(),
                keywords=str(arguments.get("keywords", "")).strip(),
            )
            limit = max(int(arguments.get("limit", 5) or 5), 1)
            candidates = self.runtime_client.recommend_for_item(scope_item, limit)
            return {
                "candidates": [candidate.to_dict() for candidate in candidates],
            }
        if name == "get_line_item":
            item = self.runtime_client.get_item(str(arguments.get("code", "")).strip())
            return {"item": item.to_dict()}
        raise RuntimeError(f"Unknown tool call: {name}")

    def _system_prompt(self) -> str:
        return (
            "You are the root Xactimate draft orchestrator for an insurance adjuster. "
            "Your job is to evolve a room-by-room estimate draft through chat. "
            "Always keep scope organized by room, then by section from ceiling to floor where appropriate. "
            "Typical section names are Ceiling, Walls, Floors, then system-specific sections like Cabinetry, Plumbing, Electrical, or HVAC when they matter. "
            "The backend automatically inserts note separator rows from section titles, so your operations should focus on line items. "
            "Never invent CAT/SEL codes. Use search_line_items and get_line_item before adding any line item. "
            "Preserve existing accepted items unless the user clearly asks to remove or replace them. "
            "When the user corrects a room or section, use clear_section or remove_line_item before adding replacements. "
            "Return JSON only with this shape: "
            "{\"assistant_reply\":\"short field-ready reply\","
            "\"operations\":["
            "{\"op\":\"clear_section\",\"room\":\"Bedroom 1\",\"section\":\"Walls\"},"
            "{\"op\":\"remove_line_item\",\"room\":\"Bedroom 1\",\"section\":\"Ceiling\",\"approved_code\":\"DRY/PCH\"},"
            "{\"op\":\"add_line_item\",\"room\":\"Bedroom 1\",\"section\":\"Ceiling\",\"approved_code\":\"DRY/PCH\","
            "\"description\":\"2x2 drywall patch\",\"quantity\":\"1\",\"surface\":\"Ceiling\",\"damage_type\":\"Patch\","
            "\"keywords\":\"2x2 patch picture frame\",\"rationale\":\"why this code fits\"}"
            "]}"
        )

    def _user_prompt(self, draft: EstimateDraft, user_text: str) -> str:
        recent_messages = "\n".join(
            f"{message.role}: {message.text}"
            for message in draft.messages[-8:]
        ) or "No prior messages."
        return (
            f"Job ID: {draft.job_id}\n"
            f"Bridge ID: {draft.bridge_id}\n\n"
            f"Current draft:\n{draft.summary_for_prompt()}\n\n"
            f"Recent conversation:\n{recent_messages}\n\n"
            f"Latest user turn:\n{user_text}\n"
        )

    def _function_calls(self, response: dict[str, Any]) -> list[dict[str, Any]]:
        calls: list[dict[str, Any]] = []
        for item in response.get("output", []):
            if isinstance(item, dict) and item.get("type") == "function_call":
                calls.append(item)
        return calls

    def _output_text(self, response: dict[str, Any]) -> str:
        if isinstance(response.get("output_text"), str) and response["output_text"].strip():
            return response["output_text"]

        texts: list[str] = []
        for item in response.get("output", []):
            if not isinstance(item, dict) or item.get("type") != "message":
                continue
            for content in item.get("content", []):
                if not isinstance(content, dict):
                    continue
                if isinstance(content.get("text"), str):
                    texts.append(content["text"])
        return "\n".join(texts).strip()

    def _parse_json(self, text: str) -> dict[str, Any]:
        cleaned = text.strip()
        if not cleaned:
            return {}
        if cleaned.startswith("```"):
            cleaned = cleaned.strip("`")
            if cleaned.startswith("json"):
                cleaned = cleaned[4:].strip()
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

    def _apply_operations(self, draft: EstimateDraft, operations: Any) -> EstimateDraft:
        if not isinstance(operations, list):
            return draft
        updated = draft
        for raw in operations:
            if not isinstance(raw, dict):
                continue
            op = str(raw.get("op", "")).strip().lower()
            room = str(raw.get("room", "")).strip()
            section = str(raw.get("section", "")).strip()
            if op == "clear_section":
                updated = updated.clear_section(room, section)
                continue
            if op == "remove_line_item":
                updated = updated.remove_line_item(room, section, str(raw.get("approved_code", "")).strip())
                continue
            if op != "add_line_item":
                continue

            approved_code = str(raw.get("approved_code", "")).strip().upper()
            if not approved_code:
                continue
            updated = updated.add_item(
                DraftLineItem.create(
                    room=room,
                    section=section,
                    approved_code=approved_code,
                    description=str(raw.get("description", "")).strip(),
                    quantity=str(raw.get("quantity", "")).strip(),
                    surface=str(raw.get("surface", "")).strip(),
                    damage_type=str(raw.get("damage_type", "")).strip(),
                    keywords=str(raw.get("keywords", "")).strip(),
                    rationale=str(raw.get("rationale", "")).strip(),
                )
            )
        return updated
