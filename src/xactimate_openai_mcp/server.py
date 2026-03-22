from __future__ import annotations

from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP
from pydantic import BaseModel, Field

from .backend import OpenAIXactimateBackend


class ToolResult(BaseModel):
    status: str
    message: str = ""
    payload: dict[str, Any] = Field(default_factory=dict)


def create_server(
    runtime_database_path: str | Path,
    producer_config_path: str | Path,
    *,
    host: str = "127.0.0.1",
    port: int = 8000,
) -> FastMCP:
    backend = OpenAIXactimateBackend(runtime_database_path, producer_config_path)
    mcp = FastMCP(
        name="Xactimate OpenAI Tools",
        instructions=(
            "Use search_line_items and get_line_item to inspect the curated estimating catalog. "
            "Use plan_estimate_job before compile_estimate_job. "
            "Only call publish_estimate_job when the user explicitly wants commands written to Firebase "
            "and set confirm_publish=true."
        ),
        host=host,
        port=port,
        json_response=True,
        streamable_http_path="/mcp",
        sse_path="/sse",
    )

    @mcp.tool(
        name="search_line_items",
        description="Search the curated Xactimate catalog for the best CAT/SEL candidates for a described scope item.",
        structured_output=True,
    )
    def search_line_items(
        query: str,
        room: str = "",
        surface: str = "",
        damage_type: str = "",
        keywords: str = "",
        limit: int = 5,
    ) -> ToolResult:
        return ToolResult(**backend.search_line_items(query, room, surface, damage_type, keywords, limit))

    @mcp.tool(
        name="get_line_item",
        description="Get a specific curated line item and its saved usage scenarios by CAT/SEL code.",
        structured_output=True,
    )
    def get_line_item(code: str) -> ToolResult:
        return ToolResult(**backend.get_line_item(code))

    @mcp.tool(
        name="plan_estimate_job",
        description="Plan an estimate job from one or more scope items and return approved, review-required, or unresolved recommendations.",
        structured_output=True,
    )
    def plan_estimate_job(job: dict[str, Any]) -> ToolResult:
        return ToolResult(**backend.plan_estimate_job(job))

    @mcp.tool(
        name="compile_estimate_job",
        description="Compile an approved estimate job into deterministic keyboard commands without publishing to Firebase.",
        structured_output=True,
    )
    def compile_estimate_job(job: dict[str, Any], starting_seq: int = 1) -> ToolResult:
        return ToolResult(**backend.compile_estimate_job(job, starting_seq))

    @mcp.tool(
        name="publish_estimate_job",
        description="Publish an approved estimate job to Firebase for the Raspberry Pi bridge. Requires confirm_publish=true.",
        structured_output=True,
    )
    def publish_estimate_job(job: dict[str, Any], confirm_publish: bool = False) -> ToolResult:
        return ToolResult(**backend.publish_estimate_job(job, confirm_publish))

    return mcp

