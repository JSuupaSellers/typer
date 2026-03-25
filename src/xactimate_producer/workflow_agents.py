from __future__ import annotations

from dataclasses import dataclass
import json
import re
from typing import Any, Protocol

import httpx

from .config import ProducerConfig
from .models import EstimateScopeItem
from .policy import PolicyEngine, PolicyVerification


def _normalized(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.strip().lower()).strip()


def _title(text: str) -> str:
    cleaned = re.sub(r"\s+", " ", text.strip())
    return cleaned.title() if cleaned else "General"


def _json_schema(name: str, schema: dict[str, Any]) -> dict[str, Any]:
    return {"format": {"type": "json_schema", "name": name, "strict": True, "schema": schema}}


@dataclass(frozen=True)
class ToolTrace:
    tool_name: str
    request: dict[str, Any]
    response: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "tool_name": self.tool_name,
            "request": self.request,
            "response": self.response,
        }


@dataclass(frozen=True)
class RoomTask:
    room: str
    room_type: str
    loss_type: str
    summary: str
    sections: tuple[str, ...]
    priority: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "room": self.room,
            "room_type": self.room_type,
            "loss_type": self.loss_type,
            "summary": self.summary,
            "sections": list(self.sections),
            "priority": self.priority,
        }


@dataclass(frozen=True)
class ClaimTurnPlan:
    assistant_reply: str
    claim_summary: str
    loss_type: str
    rooms: tuple[RoomTask, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "assistant_reply": self.assistant_reply,
            "claim_summary": self.claim_summary,
            "loss_type": self.loss_type,
            "rooms": [room.to_dict() for room in self.rooms],
        }


@dataclass(frozen=True)
class RoomPlanResult:
    room: str
    assistant_reply: str
    summary: str
    operations: tuple[dict[str, Any], ...]
    traces: tuple[ToolTrace, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "room": self.room,
            "assistant_reply": self.assistant_reply,
            "summary": self.summary,
            "operations": list(self.operations),
            "traces": [trace.to_dict() for trace in self.traces],
        }


@dataclass(frozen=True)
class RoomVerificationResult:
    room: str
    verification: PolicyVerification

    def to_dict(self) -> dict[str, Any]:
        return {"room": self.room, **self.verification.to_dict()}


class RuntimeCatalogProtocol(Protocol):
    def recommend_for_item(self, scope_item: EstimateScopeItem, limit: int): ...

    def get_item(self, code: str): ...


class OpenAIWorkflowClient:
    def __init__(self, config: ProducerConfig) -> None:
        self._config = config

    async def create_response(self, payload: dict[str, Any]) -> dict[str, Any]:
        endpoint = self._config.openai_base_url.rstrip("/") + "/responses"
        headers = {
            "Authorization": f"Bearer {self._config.openai_api_key.strip()}",
            "Content-Type": "application/json",
        }
        timeout_s = max(float(self._config.request_timeout_s), 120.0)
        try:
            async with httpx.AsyncClient(timeout=timeout_s) as client:
                response = await client.post(endpoint, headers=headers, json=payload)
        except httpx.TimeoutException as exc:
            raise RuntimeError(f"OpenAI workflow request timed out after {timeout_s:.0f}s.") from exc
        except httpx.HTTPError as exc:
            raise RuntimeError(f"OpenAI workflow request failed: {exc}") from exc
        if response.status_code < 200 or response.status_code >= 300:
            raise RuntimeError(f"OpenAI workflow request failed with status {response.status_code}: {response.text}")
        data = response.json()
        if not isinstance(data, dict):
            raise RuntimeError("OpenAI workflow response was not a JSON object.")
        return data

    @staticmethod
    def output_text(response: dict[str, Any]) -> str:
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

    @staticmethod
    def parse_json(text: str) -> dict[str, Any]:
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

    @staticmethod
    def function_calls(response: dict[str, Any]) -> list[dict[str, Any]]:
        return [
            item
            for item in response.get("output", [])
            if isinstance(item, dict) and item.get("type") == "function_call"
        ]


class ClaimOrchestratorAgent:
    def __init__(self, config: ProducerConfig, policy: PolicyEngine) -> None:
        self._config = config
        self._policy = policy
        self._client = OpenAIWorkflowClient(config)

    async def orchestrate(
        self,
        *,
        draft_summary: str,
        existing_rooms: list[str],
        recent_messages: list[str],
        user_text: str,
    ) -> ClaimTurnPlan:
        if not self._config.openai_api_key.strip():
            return self._heuristic_plan(existing_rooms, user_text)

        response = await self._client.create_response(
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
                        "content": [{"type": "input_text", "text": self._user_prompt(draft_summary, existing_rooms, recent_messages, user_text)}],
                    },
                ],
                "store": True,
                "text": _json_schema(
                    "claim_turn_plan",
                    {
                        "type": "object",
                        "properties": {
                            "assistant_reply": {"type": "string"},
                            "claim_summary": {"type": "string"},
                            "loss_type": {"type": "string"},
                            "rooms": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "room": {"type": "string"},
                                        "room_type": {"type": "string"},
                                        "loss_type": {"type": "string"},
                                        "summary": {"type": "string"},
                                        "sections": {"type": "array", "items": {"type": "string"}},
                                        "priority": {"type": "integer"}
                                    },
                                    "required": ["room", "room_type", "loss_type", "summary", "sections", "priority"],
                                    "additionalProperties": False,
                                }
                            }
                        },
                        "required": ["assistant_reply", "claim_summary", "loss_type", "rooms"],
                        "additionalProperties": False,
                    },
                ),
                "max_output_tokens": 6_000,
            }
        )
        payload = self._client.parse_json(self._client.output_text(response))
        if not payload:
            return self._heuristic_plan(existing_rooms, user_text)

        rooms = tuple(
            RoomTask(
                room=_title(str(entry.get("room", ""))),
                room_type=_normalized(str(entry.get("room_type", "generic"))) or "generic",
                loss_type=_normalized(str(entry.get("loss_type", payload.get("loss_type", "generic")))) or "generic",
                summary=str(entry.get("summary", "")).strip() or user_text.strip(),
                sections=tuple(str(section).strip() for section in entry.get("sections", []) if str(section).strip()),
                priority=max(int(entry.get("priority", index + 1) or (index + 1)), 1),
            )
            for index, entry in enumerate(payload.get("rooms", []))
            if isinstance(entry, dict) and str(entry.get("room", "")).strip()
        )
        if not rooms:
            return self._heuristic_plan(existing_rooms, user_text)

        return ClaimTurnPlan(
            assistant_reply=str(payload.get("assistant_reply", "")).strip() or "Planning updated rooms now.",
            claim_summary=str(payload.get("claim_summary", user_text)).strip() or user_text.strip(),
            loss_type=_normalized(str(payload.get("loss_type", "generic"))) or "generic",
            rooms=tuple(sorted(rooms, key=lambda room: (room.priority, room.room))),
        )

    def _system_prompt(self) -> str:
        return (
            "You are the claim-turn orchestrator for an insurance adjusting workflow. "
            "Read one user turn in the context of the current claim, identify which rooms should be updated, "
            "summarize the room-scoped work, and suggest the section ordering to draft. "
            "Do not choose CAT/SEL codes here. "
            "Keep each room summary self-contained so a room planner can draft it independently. "
            "If the user mentions no room and exactly one room already exists, you may keep working in that room. "
            "Prefer room-by-room worklists, not whole-claim line-item decisions."
        )

    def _user_prompt(self, draft_summary: str, existing_rooms: list[str], recent_messages: list[str], user_text: str) -> str:
        conversation = "\n".join(recent_messages[-8:]) or "No prior messages."
        return (
            f"Existing rooms: {', '.join(existing_rooms) or 'None'}\n\n"
            f"Current claim draft summary:\n{draft_summary}\n\n"
            f"Recent conversation:\n{conversation}\n\n"
            f"Latest user turn:\n{user_text}\n"
        )

    def _heuristic_plan(self, existing_rooms: list[str], user_text: str) -> ClaimTurnPlan:
        text = user_text.strip()
        lowered = _normalized(text)
        rooms: list[RoomTask] = []
        room_patterns = [
            "living room",
            "family room",
            "dining room",
            "kitchen",
            "breakfast nook",
            "laundry room",
            "entry",
            "foyer",
            "hallway",
            "hall bathroom",
            "bathroom",
            "bedroom 1",
            "bedroom 2",
            "bedroom 3",
            "bedroom 4",
            "bedroom",
            "primary bedroom",
            "primary bathroom",
            "office",
            "closet",
            "stairs",
            "stairwell",
        ]
        seen: set[str] = set()
        for pattern in room_patterns:
            if pattern in lowered:
                room = _title(pattern)
                if room in seen:
                    continue
                seen.add(room)
                rooms.append(
                    RoomTask(
                        room=room,
                        room_type=_normalized(pattern),
                        loss_type=self._guess_loss_type(lowered),
                        summary=text,
                        sections=tuple(self._policy.room_template_payload(self._guess_loss_type(lowered), _normalized(pattern))["sections"]),
                        priority=len(rooms) + 1,
                    )
                )
        if not rooms:
            room = existing_rooms[0] if len(existing_rooms) == 1 else "General"
            room_type = _normalized(room) or "generic"
            rooms.append(
                RoomTask(
                    room=room,
                    room_type=room_type,
                    loss_type=self._guess_loss_type(lowered),
                    summary=text,
                    sections=tuple(self._policy.room_template_payload(self._guess_loss_type(lowered), room_type)["sections"]),
                    priority=1,
                )
            )
        return ClaimTurnPlan(
            assistant_reply=f"Queued updates for {', '.join(room.room for room in rooms)}.",
            claim_summary=text,
            loss_type=self._guess_loss_type(lowered),
            rooms=tuple(rooms),
        )

    @staticmethod
    def _guess_loss_type(lowered: str) -> str:
        if "smoke" in lowered or "soot" in lowered or "fire" in lowered:
            return "smoke"
        if "water" in lowered or "leak" in lowered or "drywall patch" in lowered or "stain" in lowered:
            return "water"
        return "generic"


class RoomPlannerAgent:
    def __init__(self, config: ProducerConfig, runtime_client: RuntimeCatalogProtocol, policy: PolicyEngine) -> None:
        self._config = config
        self._runtime_client = runtime_client
        self._policy = policy
        self._client = OpenAIWorkflowClient(config)

    async def plan_room(
        self,
        *,
        claim_summary: str,
        room_task: RoomTask,
        existing_room_summary: str,
    ) -> RoomPlanResult:
        if not self._config.openai_api_key.strip():
            return RoomPlanResult(room=room_task.room, assistant_reply=f"Saved note for {room_task.room}.", summary=room_task.summary, operations=(), traces=())

        traces: list[ToolTrace] = []
        response = await self._client.create_response(
            {
                "model": self._config.agent_model,
                "reasoning": {"effort": self._config.agent_reasoning_effort},
                "input": [
                    {
                        "role": "system",
                        "content": [{"type": "input_text", "text": self._system_prompt(room_task)}],
                    },
                    {
                        "role": "user",
                        "content": [{"type": "input_text", "text": self._user_prompt(claim_summary, room_task, existing_room_summary)}],
                    },
                ],
                "tools": self._tool_definitions(),
                "tool_choice": "auto",
                "store": True,
                "text": self._response_format(),
                "max_output_tokens": 20_000,
            }
        )
        response_id = str(response.get("id", "")).strip()

        while True:
            calls = self._client.function_calls(response)
            if not calls:
                break

            tool_outputs = []
            for call in calls:
                name = str(call.get("name", "")).strip()
                call_id = str(call.get("call_id", "")).strip()
                arguments = self._client.parse_json(str(call.get("arguments", "{}")))
                result = self._run_tool(name, arguments)
                traces.append(ToolTrace(tool_name=name, request=arguments, response=result))
                tool_outputs.append(
                    {
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": json.dumps(result),
                    }
                )

            response = await self._client.create_response(
                {
                    "model": self._config.agent_model,
                    "previous_response_id": response_id,
                    "input": tool_outputs,
                    "tools": self._tool_definitions(),
                    "tool_choice": "auto",
                    "store": True,
                    "text": self._response_format(),
                    "max_output_tokens": 20_000,
                }
            )
            response_id = str(response.get("id", response_id)).strip() or response_id

        payload = self._client.parse_json(self._client.output_text(response))
        if not payload:
            raise RuntimeError(f"Room planner returned no structured output for {room_task.room}.")

        operations = tuple(
            operation
            for operation in payload.get("operations", [])
            if isinstance(operation, dict)
        )
        return RoomPlanResult(
            room=room_task.room,
            assistant_reply=str(payload.get("assistant_reply", "")).strip() or f"Drafted {room_task.room}.",
            summary=str(payload.get("summary", room_task.summary)).strip() or room_task.summary,
            operations=operations,
            traces=tuple(traces),
        )

    def _tool_definitions(self) -> list[dict[str, Any]]:
        return [
            {
                "type": "function",
                "name": "search_catalog_candidates",
                "description": "Search the curated Xactimate catalog for a single component and intent, then return policy-filtered candidates.",
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "intent": {"type": "string"},
                        "component": {"type": "string"},
                        "room": {"type": ["string", "null"]},
                        "section": {"type": ["string", "null"]},
                        "surface": {"type": ["string", "null"]},
                        "severity": {"type": ["string", "null"]},
                        "keywords": {"type": ["string", "null"]},
                        "room_scope": {"type": ["boolean", "null"]},
                        "limit": {"type": ["integer", "null"]}
                    },
                    "required": ["intent", "component", "room", "section", "surface", "severity", "keywords", "room_scope", "limit"],
                    "additionalProperties": False,
                },
            },
            {
                "type": "function",
                "name": "get_policy_defaults",
                "description": "Return quantity, section, and preferred-code defaults for a component and intent.",
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "component": {"type": "string"},
                        "intent": {"type": "string"},
                        "surface": {"type": ["string", "null"]},
                        "room_scope": {"type": ["boolean", "null"]}
                    },
                    "required": ["component", "intent", "surface", "room_scope"],
                    "additionalProperties": False,
                },
            },
            {
                "type": "function",
                "name": "get_allowed_fallbacks",
                "description": "Return policy-approved and blocked fallback families for a component and intent.",
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "component": {"type": "string"},
                        "intent": {"type": "string"},
                        "surface": {"type": ["string", "null"]}
                    },
                    "required": ["component", "intent", "surface"],
                    "additionalProperties": False,
                },
            },
            {
                "type": "function",
                "name": "get_room_template",
                "description": "Return the default section ordering for a room and loss type.",
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "loss_type": {"type": "string"},
                        "room_type": {"type": "string"}
                    },
                    "required": ["loss_type", "room_type"],
                    "additionalProperties": False,
                },
            },
        ]

    def _response_format(self) -> dict[str, Any]:
        return _json_schema(
            "room_plan_response",
            {
                "type": "object",
                "properties": {
                    "assistant_reply": {"type": "string"},
                    "summary": {"type": "string"},
                    "operations": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "op": {"type": "string", "enum": ["clear_section", "remove_line_item", "add_line_item"]},
                                "room": {"type": "string"},
                                "section": {"type": "string"},
                                "category": {"type": "string"},
                                "selector": {"type": "string"},
                                "description": {"type": "string"},
                                "quantity": {"type": "string"},
                                "activity": {"type": "string"},
                                "surface": {"type": "string"},
                                "damage_type": {"type": "string"},
                                "keywords": {"type": "string"},
                                "rationale": {"type": "string"}
                            },
                            "required": ["op", "room", "section", "category", "selector", "description", "quantity", "activity", "surface", "damage_type", "keywords", "rationale"],
                            "additionalProperties": False,
                        }
                    }
                },
                "required": ["assistant_reply", "summary", "operations"],
                "additionalProperties": False,
            },
        )

    def _system_prompt(self, room_task: RoomTask) -> str:
        return (
            "You are the room planner for a durable Xactimate claim workflow. "
            f"You may only draft room-scoped operations for {room_task.room}. "
            "Use the provided policy and catalog tools before choosing a CAT/SEL. "
            "Return category and selector as separate fields, never as one combined PNT/SP-style string. "
            "Keep room work organized by section, and preserve separate intents like clean, seal, paint, patch, and detach/reset. "
            "Use clear_section only when the latest instruction clearly replaces prior scope in that section. "
            "Prefer policy-approved fallbacks over lexical lookalikes. "
            "Do not invent CAT/SEL codes. "
            "Return only structured operations for this room."
        )

    def _user_prompt(self, claim_summary: str, room_task: RoomTask, existing_room_summary: str) -> str:
        return (
            f"Claim summary:\n{claim_summary}\n\n"
            f"Room: {room_task.room}\n"
            f"Room type: {room_task.room_type}\n"
            f"Loss type: {room_task.loss_type}\n"
            f"Room instruction summary:\n{room_task.summary}\n\n"
            f"Preferred section order:\n{', '.join(room_task.sections) or 'Ceiling, Walls, Trim, Floors'}\n\n"
            f"Existing drafted state for this room:\n{existing_room_summary or 'No existing room items.'}\n"
        )

    def _run_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "search_catalog_candidates":
            intent = str(arguments.get("intent", "")).strip()
            component = str(arguments.get("component", "")).strip()
            room = str(arguments.get("room", "")).strip()
            section = str(arguments.get("section", "")).strip()
            surface = str(arguments.get("surface", "")).strip() or component
            severity = str(arguments.get("severity", "")).strip()
            keywords = str(arguments.get("keywords", "")).strip()
            room_scope = bool(arguments.get("room_scope", False))
            limit = max(int(arguments.get("limit", 5) or 5), 1)

            default_payload = self._policy.policy_defaults_payload(component, intent, surface, room_scope)
            query = self._search_phrase(intent, component, surface, severity)
            scope_item = EstimateScopeItem(
                item_id="policy-search",
                description=query,
                room=room,
                section=section or self._policy.recommended_section(component, surface),
                surface=surface,
                damage_type=intent.title(),
                keywords=keywords,
            )
            runtime_candidates = list(self._runtime_client.recommend_for_item(scope_item, limit))
            filtered = self._policy.rerank_candidates(
                component=component,
                intent=intent,
                surface=surface,
                room_scope=room_scope,
                candidates=runtime_candidates,
                load_item=self._runtime_client.get_item,
            )
            return {
                "search_request": {
                    "intent": intent,
                    "component": component,
                    "room": room,
                    "section": section,
                    "surface": surface,
                    "severity": severity,
                    "keywords": keywords,
                    "query": query,
                    "limit": limit,
                },
                "policy_defaults": default_payload,
                "candidates": [candidate.to_dict() for candidate in filtered[:limit]],
            }

        if name == "get_policy_defaults":
            return self._policy.policy_defaults_payload(
                str(arguments.get("component", "")).strip(),
                str(arguments.get("intent", "")).strip(),
                str(arguments.get("surface", "")).strip(),
                bool(arguments.get("room_scope", False)),
            )

        if name == "get_allowed_fallbacks":
            return self._policy.allowed_fallbacks_payload(
                str(arguments.get("component", "")).strip(),
                str(arguments.get("intent", "")).strip(),
                str(arguments.get("surface", "")).strip(),
            )

        if name == "get_room_template":
            return self._policy.room_template_payload(
                str(arguments.get("loss_type", "")).strip(),
                str(arguments.get("room_type", "")).strip(),
            )

        raise RuntimeError(f"Unknown planner tool: {name}")

    @staticmethod
    def _search_phrase(intent: str, component: str, surface: str, severity: str) -> str:
        parts = [intent.strip(), severity.strip(), component.strip() or surface.strip()]
        return " ".join(part for part in parts if part).strip()


class RoomVerifier:
    def __init__(self, policy: PolicyEngine) -> None:
        self._policy = policy

    def verify(self, *, room: str, room_summary: str, room_items: list[Any]) -> RoomVerificationResult:
        return RoomVerificationResult(
            room=room,
            verification=self._policy.verify_room(room_summary=room_summary, items=room_items),
        )
