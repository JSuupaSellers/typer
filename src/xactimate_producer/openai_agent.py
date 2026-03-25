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
                "text": self._response_text_format(),
                "max_output_tokens": self._response_max_output_tokens(),
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
                    "text": self._response_text_format(),
                    "max_output_tokens": self._response_max_output_tokens(),
                }
            )
            response_id = str(response.get("id", response_id)).strip() or response_id

        raw_output = self._output_text(response)
        payload = self._parse_json(raw_output)
        if not payload and raw_output.strip():
            incomplete_reason = self._incomplete_reason(response)
            if incomplete_reason:
                raise RuntimeError(
                    "OpenAI draft agent ran out of output space while building this claim JSON. "
                    "Try the same claim again after the larger output-budget update, or split the claim into smaller room groups if it still happens."
                )
            preview = raw_output.strip().replace("\n", " ")[:280]
            raise RuntimeError(f"OpenAI draft agent returned unstructured output instead of draft JSON: {preview}")
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
        timeout_s = max(float(self.config.request_timeout_s), 300.0)
        try:
            async with httpx.AsyncClient(timeout=timeout_s) as client:
                response = await client.post(endpoint, headers=headers, json=payload)
        except httpx.TimeoutException as exc:
            raise RuntimeError(
                f"OpenAI draft agent timed out after {timeout_s:.0f}s while planning this claim. "
                "Try breaking the scope into smaller room groups if it keeps happening."
            ) from exc
        except httpx.HTTPError as exc:
            raise RuntimeError(f"OpenAI draft agent request failed: {exc}") from exc
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
                "description": (
                    "Search the curated Xactimate catalog for one atomic scope item. "
                    "The query must be a short estimator-style search phrase, not a full user sentence. "
                    "Good examples: 'seal water stain ceiling', 'paint acoustic ceiling', "
                    "'drywall patch 2x2', 're-apply protective coating carpet'. "
                    "Bad examples: whole-room narratives, questions, or multiple tasks joined with 'and'."
                ),
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": (
                                "Required. A compact 2-8 word search phrase for a single line-item need. "
                                "Do not include room names if room is provided separately."
                            ),
                        },
                        "room": {
                            "type": ["string", "null"],
                            "description": "Optional room or area, for example 'Living room' or 'Kitchen'.",
                        },
                        "section": {
                            "type": ["string", "null"],
                            "description": "Optional section like 'Ceiling', 'Walls', 'Floors', 'Electrical', or 'Plumbing'.",
                        },
                        "surface": {
                            "type": ["string", "null"],
                            "description": "Optional affected surface or component, for example 'Ceiling' or 'Wall'.",
                        },
                        "damage_type": {
                            "type": ["string", "null"],
                            "description": "Optional repair or damage pattern, for example 'Paint', 'Patch', 'Seal', or 'Protection'.",
                        },
                        "keywords": {
                            "type": ["string", "null"],
                            "description": "Optional comma-free shorthand keywords like 'water stain shellac' or 'carpet coating protect'.",
                        },
                        "limit": {
                            "type": ["integer", "null"],
                            "description": "Optional result cap. Use 5-8 when exploring and 3-5 when refining.",
                        },
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
                "name": "explore_line_item_search",
                "description": (
                    "Try 2-4 alternate search strategies for the same atomic scope item and compare the results. "
                    "Use this when the first search looks weak, overly broad, wrong-category, or ambiguous. "
                    "Each strategy should represent a different estimator-style phrasing, such as generic workflow, "
                    "surface-first phrasing, synonym phrasing, or a more domain-specific phrase."
                ),
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Required. The base atomic scope item being explored.",
                        },
                        "room": {
                            "type": ["string", "null"],
                            "description": "Optional room or area, for example 'Living room' or 'Kitchen'.",
                        },
                        "section": {
                            "type": ["string", "null"],
                            "description": "Optional section like 'Ceiling', 'Walls', 'Floors', 'Electrical', or 'Plumbing'.",
                        },
                        "surface": {
                            "type": ["string", "null"],
                            "description": "Optional affected surface or component, for example 'Ceiling' or 'Wall'.",
                        },
                        "damage_type": {
                            "type": ["string", "null"],
                            "description": "Optional repair or damage pattern, for example 'Paint', 'Patch', 'Seal', or 'Protection'.",
                        },
                        "keywords": {
                            "type": ["string", "null"],
                            "description": "Optional comma-free shorthand keywords like 'water stain shellac' or 'carpet coating protect'.",
                        },
                        "limit": {
                            "type": ["integer", "null"],
                            "description": "Optional result cap per strategy. Use 3-6 in most cases.",
                        },
                        "strategies": {
                            "type": "array",
                            "description": (
                                "Two to four alternate search plans. Make each one meaningfully different. "
                                "Example names: 'generic_paint', 'surface_first', 'synonym_variant', 'domain_specific'."
                            ),
                            "minItems": 2,
                            "maxItems": 4,
                            "items": {
                                "type": "object",
                                "properties": {
                                    "name": {
                                        "type": "string",
                                        "description": "Short label describing the strategy.",
                                    },
                                    "query": {
                                        "type": ["string", "null"],
                                        "description": "Optional override search phrase for this strategy.",
                                    },
                                    "room": {
                                        "type": ["string", "null"],
                                        "description": "Optional override room.",
                                    },
                                    "section": {
                                        "type": ["string", "null"],
                                        "description": "Optional override section.",
                                    },
                                    "surface": {
                                        "type": ["string", "null"],
                                        "description": "Optional override surface.",
                                    },
                                    "damage_type": {
                                        "type": ["string", "null"],
                                        "description": "Optional override damage type.",
                                    },
                                    "keywords": {
                                        "type": ["string", "null"],
                                        "description": "Optional override shorthand keywords.",
                                    },
                                    "limit": {
                                        "type": ["integer", "null"],
                                        "description": "Optional override result cap for this strategy.",
                                    },
                                },
                                "required": [
                                    "name",
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
                    },
                    "required": [
                        "query",
                        "room",
                        "section",
                        "surface",
                        "damage_type",
                        "keywords",
                        "limit",
                        "strategies",
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
            {
                "type": "function",
                "name": "get_estimating_defaults",
                "description": (
                    "Return deterministic Xactimate room-variable and scope-default guidance for common estimating patterns. "
                    "Use this before searching when the user describes room-wide trim, baseboard, chair rail, crown, paint, or other scope "
                    "that should usually use a room variable like PF, PC, F, W, C, or WC."
                ),
                "strict": True,
                "parameters": {
                    "type": "object",
                    "properties": {
                        "topic": {
                            "type": ["string", "null"],
                            "description": "Optional freeform topic such as 'baseboard reset', 'room variables', or 'trim around room'.",
                        },
                        "component": {
                            "type": ["string", "null"],
                            "description": "Optional component like 'baseboard', 'chair rail', 'crown', or 'ceiling'.",
                        },
                        "action": {
                            "type": ["string", "null"],
                            "description": "Optional action like 'detach and reset', 'paint', 'replace', or 'reset'.",
                        },
                        "room_scope": {
                            "type": ["boolean", "null"],
                            "description": "Optional hint that the task applies to the full room.",
                        },
                    },
                    "required": ["topic", "component", "action", "room_scope"],
                    "additionalProperties": False,
                },
            },
        ]

    def _run_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "search_line_items":
            scope_item = self._scope_item_from_tool_arguments(arguments, item_id="tool-search")
            limit = max(int(arguments.get("limit", 5) or 5), 1)
            candidates = self.runtime_client.recommend_for_item(scope_item, limit)
            return self._search_response(scope_item, limit, candidates)
        if name == "explore_line_item_search":
            scope_item = self._scope_item_from_tool_arguments(arguments, item_id="tool-search-explore")
            limit = max(int(arguments.get("limit", 5) or 5), 1)
            raw_strategies = arguments.get("strategies", [])
            strategies = [strategy for strategy in raw_strategies if isinstance(strategy, dict)]
            return self.runtime_client.explore_strategies(scope_item, strategies, limit)
        if name == "get_line_item":
            item = self.runtime_client.get_item(str(arguments.get("code", "")).strip())
            return {"item": item.to_dict()}
        if name == "get_estimating_defaults":
            return self._estimating_defaults(arguments)
        raise RuntimeError(f"Unknown tool call: {name}")

    def _response_max_output_tokens(self) -> int:
        return 60_000

    def _incomplete_reason(self, response: dict[str, Any]) -> str:
        details = response.get("incomplete_details")
        if isinstance(details, dict):
            reason = str(details.get("reason", "")).strip()
            if reason:
                return reason
        for item in response.get("output", []):
            if not isinstance(item, dict):
                continue
            if str(item.get("status", "")).strip().lower() == "incomplete":
                return "incomplete"
        if str(response.get("status", "")).strip().lower() == "incomplete":
            return "incomplete"
        return ""

    def _response_text_format(self) -> dict[str, Any]:
        return {
            "format": {
                "type": "json_schema",
                "name": "draft_turn_response",
                "strict": True,
                "schema": {
                    "type": "object",
                    "properties": {
                        "assistant_reply": {
                            "type": "string",
                            "description": "Short field-ready reply to show in the chat UI.",
                        },
                        "operations": {
                            "type": "array",
                            "description": "Ordered draft mutations to apply to the current claim draft.",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "op": {
                                        "type": "string",
                                        "enum": ["clear_section", "remove_line_item", "add_line_item"],
                                    },
                                    "room": {"type": "string"},
                                    "section": {"type": "string"},
                                    "approved_code": {"type": "string"},
                                    "description": {"type": "string"},
                                    "quantity": {"type": "string"},
                                    "activity": {"type": "string"},
                                    "surface": {"type": "string"},
                                    "damage_type": {"type": "string"},
                                    "keywords": {"type": "string"},
                                    "rationale": {"type": "string"},
                                },
                                "required": [
                                    "op",
                                    "room",
                                    "section",
                                    "approved_code",
                                    "description",
                                    "quantity",
                                    "activity",
                                    "surface",
                                    "damage_type",
                                    "keywords",
                                    "rationale",
                                ],
                                "additionalProperties": False,
                            },
                        },
                    },
                    "required": ["assistant_reply", "operations"],
                    "additionalProperties": False,
                },
            }
        }

    def _system_prompt(self) -> str:
        return (
            "You are the root Xactimate draft orchestrator for an insurance adjuster. "
            "Your job is to evolve a room-by-room estimate draft through chat. "
            "Always keep scope organized by room, then by section from ceiling to floor where appropriate. "
            "Typical section names are Ceiling, Walls, Floors, then system-specific sections like Cabinetry, Plumbing, Electrical, or HVAC when they matter. "
            "The backend automatically inserts note separator rows from section titles, so your operations should focus on line items. "
            "Never invent CAT/SEL codes. Use get_estimating_defaults, search_line_items, explore_line_item_search, and get_line_item before adding any line item. "
            "You are responsible for the final structured estimate JSON. "
            "Tool results are advisory context so you can choose the right CAT/SEL, quantity expression, and activity in your output. "
            "For search_line_items, search one atomic scope item at a time. "
            "Do not send the whole user narrative into the tool. "
            "Convert each need into a short estimator-style query like 'seal water stain ceiling', "
            "'paint acoustic ceiling', 'clean baseboard', 'clean trim', 'paint wall', 'drywall patch 2x2', or 're-apply protective coating carpet'. "
            "If the user describes multiple needs, make multiple search_line_items calls. "
            "If the user says a component needs both cleaning and painting, treat that as separate workflow intents. "
            "Search the clean intent separately from the paint or seal intent. "
            "Do not let a paint or seal item satisfy a requested clean step, and do not let a clean item satisfy a requested paint step. "
            "If clean-only support is weak or absent for a surface, say that clearly in your rationale instead of collapsing the clean intent into a paint line. "
            "For broad interior wall or ceiling cleaning with no specialty surface called out, prefer the CLN/AV family as the generic clean fallback when search supports it. "
            "For smoke or soot claims, search using generic component cleaning terms like 'clean baseboard', 'clean crown molding', 'clean door', or 'clean textured ceiling' unless the catalog clearly supports a more specific phrase. "
            "Before searching or adding room-wide trim, baseboard, chair rail, crown, or paint items, call get_estimating_defaults to choose the right room variable and baseline convention. "
            "Use room, section, surface, damage_type, and keywords fields to narrow the search instead of overloading query text. "
            "When a search returns weak or obviously wrong candidates, first try a narrower or more domain-specific query. "
            "If you want to compare different phrasings or tactics, call explore_line_item_search with 2-4 distinct strategies such as generic workflow, synonym variant, surface-first phrasing, or domain-specific phrasing. "
            "Important estimating defaults: PF means perimeter of floor. "
            "For room-wide trim like baseboard or chair rail, default quantity to PF unless the user gives partial footage or a deduction like PF-12. "
            "If the user's wording clearly implies an activity such as detach and reset, reset only, paint, or remove, set the activity field in your JSON. "
            "If the user says 'detach and reset baseboard 3 1/4 inch', preserve that intent in your output instead of waiting for search results to spell it out. "
            "Search is mainly to find the right CAT/SEL family and quantity basis. "
            "If the user asks what search returned, answer with the top returned CAT/SEL candidates and why they look right or wrong. "
            "Preserve existing accepted items unless the user clearly asks to remove or replace them. "
            "When the user corrects a room or section, use clear_section or remove_line_item before adding replacements. "
            "Return JSON only with this shape: "
            "{\"assistant_reply\":\"short field-ready reply\","
            "\"operations\":["
            "{\"op\":\"clear_section\",\"room\":\"Bedroom 1\",\"section\":\"Walls\"},"
            "{\"op\":\"remove_line_item\",\"room\":\"Bedroom 1\",\"section\":\"Ceiling\",\"approved_code\":\"DRY/PCH\"},"
            "{\"op\":\"add_line_item\",\"room\":\"Bedroom 1\",\"section\":\"Ceiling\",\"approved_code\":\"DRY/PCH\","
            "\"description\":\"2x2 drywall patch\",\"quantity\":\"1\",\"activity\":\"R\",\"surface\":\"Ceiling\",\"damage_type\":\"Patch\","
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

    def _scope_item_from_tool_arguments(self, arguments: dict[str, Any], item_id: str) -> EstimateScopeItem:
        return EstimateScopeItem(
            item_id=item_id,
            description=str(arguments.get("query", "")).strip(),
            room=str(arguments.get("room", "")).strip(),
            section=str(arguments.get("section", "")).strip(),
            surface=str(arguments.get("surface", "")).strip(),
            damage_type=str(arguments.get("damage_type", "")).strip(),
            keywords=str(arguments.get("keywords", "")).strip(),
        )

    def _search_response(
        self,
        scope_item: EstimateScopeItem,
        limit: int,
        candidates: list[Any],
    ) -> dict[str, Any]:
        return {
            "search_request": {
                "query": scope_item.description,
                "room": scope_item.room,
                "section": scope_item.section,
                "surface": scope_item.surface,
                "damage_type": scope_item.damage_type,
                "keywords": scope_item.keywords,
                "limit": limit,
            },
            "candidates": [candidate.to_dict() for candidate in candidates],
        }

    def _estimating_defaults(self, arguments: dict[str, Any]) -> dict[str, Any]:
        topic = str(arguments.get("topic", "")).strip()
        component = str(arguments.get("component", "")).strip().lower()
        action = str(arguments.get("action", "")).strip().lower()
        room_scope = arguments.get("room_scope", None)

        rules = [
            "PF means Perimeter of Floor.",
            "PC means Perimeter of Ceiling.",
            "F means Floor Area.",
            "W means Wall Area.",
            "C means Ceiling Area.",
            "WC means Walls and Ceiling.",
            "For room-wide trim items like baseboard or chair rail, default quantity to PF unless the user specifies partial LF or a deduction.",
        ]

        suggestions: list[dict[str, Any]] = []
        normalized_text = " ".join(part for part in (topic.lower(), component, action) if part).strip()

        if any(term in normalized_text for term in {"baseboard", "chair rail", "crown", "trim"}):
            suggestions.append(
                {
                    "when": "room-wide trim around a room",
                    "quantity": "PF",
                    "reason": "Trim around the room usually follows the perimeter of floor in Xactimate.",
                }
            )

        if "baseboard" in normalized_text and any(term in normalized_text for term in {"detach", "reset"}):
            suggestions.extend(
                [
                    {
                        "when": "full-room baseboard detach and reset",
                        "approved_code": "FNC/BRS",
                        "quantity": "PF",
                        "reason": "Current price list has an explicit Baseboard - Detach & reset selector.",
                    },
                    {
                        "when": "full-room multi-member baseboard detach and reset",
                        "approved_code": "FNC/BRS>",
                        "quantity": "PF",
                        "reason": "Use the multi-member detach/reset selector when the trim is built up from multiple members.",
                    },
                    {
                        "when": "reset only after another company already detached the baseboard",
                        "approved_code": "FNC/BR",
                        "quantity": "PF",
                        "reason": "Reset-only selector excludes detaching and is intended after prior removal.",
                    },
                ]
            )

        if "baseboard" in normalized_text and "replace" in normalized_text:
            suggestions.append(
                {
                    "when": "generic full-room baseboard replacement with no size or material given",
                    "approved_code": "FNC/B3",
                    "quantity": "PF",
                    "reason": "Default practical assumption is common paint-grade 3 1/4 inch baseboard unless the user specifies otherwise.",
                }
            )

        if "baseboard" in normalized_text and "paint" in normalized_text:
            suggestions.append(
                {
                    "when": "full-room baseboard paint, two coats",
                    "approved_code": "PNT/B2",
                    "quantity": "PF",
                    "reason": "Baseboard paint in a room usually tracks the room perimeter.",
                }
            )

        if room_scope is True and not suggestions:
            suggestions.append(
                {
                    "when": "generic full-room scope with no better default",
                    "quantity": "PF",
                    "reason": "Room-wide trim defaults often start from PF when the item runs around the floor perimeter.",
                }
            )

        return {
            "topic": topic,
            "component": component,
            "action": action,
            "room_scope": room_scope,
            "variables": {
                "PF": "Perimeter of Floor",
                "PC": "Perimeter of Ceiling",
                "F": "Floor Area",
                "W": "Wall Area",
                "C": "Ceiling Area",
                "WC": "Walls and Ceiling",
            },
            "rules": rules,
            "suggestions": suggestions,
            "notes": [
                "Use explicit CAT/SEL selectors from the current price list when they exist.",
                "This backend does not yet store a separate activity-code field, so explicit selectors are safer than relying on activity syntax.",
                "If the user gives a deduction such as doorway footage, subtract it from PF like PF-12.",
            ],
        }

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
                    activity=str(raw.get("activity", "")).strip(),
                    surface=str(raw.get("surface", "")).strip(),
                    damage_type=str(raw.get("damage_type", "")).strip(),
                    keywords=str(raw.get("keywords", "")).strip(),
                    rationale=str(raw.get("rationale", "")).strip(),
                )
            )
        return updated
