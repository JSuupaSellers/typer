from __future__ import annotations

from dataclasses import dataclass

from .config import WorkflowProfile, WorkflowStepTemplate
from .models import CompiledCommand, ExecutionPlan, PlannedEstimateItem


class _SafeFormatDict(dict[str, str]):
    def __missing__(self, key: str) -> str:
        return ""


@dataclass(frozen=True)
class WorkflowCompiler:
    profile: WorkflowProfile

    def compile(self, plan: ExecutionPlan, starting_seq: int = 1) -> tuple[CompiledCommand, ...]:
        seq = max(int(starting_seq), 1)
        commands: list[CompiledCommand] = []

        for step in self.profile.before_all:
            command = self._render_step(step, seq, _SafeFormatDict({"job_id": plan.job.job_id}))
            if command is None:
                continue
            commands.append(command)
            seq += 1

        for index, item in enumerate(plan.items, start=1):
            if item.approved_candidate is None:
                continue
            context = self._item_context(plan, item, index)
            steps = self.profile.note_item if item.source.item_type == "note" else self.profile.per_item
            for step in steps:
                command = self._render_step(step, seq, context)
                if command is None:
                    continue
                commands.append(command)
                seq += 1

        for step in self.profile.after_all:
            command = self._render_step(step, seq, _SafeFormatDict({"job_id": plan.job.job_id}))
            if command is None:
                continue
            commands.append(command)
            seq += 1

        return tuple(commands)

    def _item_context(self, plan: ExecutionPlan, item: PlannedEstimateItem, index: int) -> _SafeFormatDict:
        approved = item.approved_candidate
        assert approved is not None
        source = item.source
        metadata = {
            "job_id": plan.job.job_id,
            "bridge_id": plan.job.bridge_id,
            "scope_item_id": source.item_id,
            "line_code": approved.item.code,
            "line_activity": source.activity,
            "line_description": approved.item.description,
            "line_index": index,
            "scope_description": source.description,
            "item_type": source.item_type,
        }
        return _SafeFormatDict(
            {
                "job_id": plan.job.job_id,
                "bridge_id": plan.job.bridge_id,
                "scope_item_id": source.item_id,
                "line_index": str(index),
                "item_type": source.item_type,
                "code": approved.item.code,
                "category": approved.item.category,
                "selector": approved.item.selector,
                "description": approved.item.description,
                "unit": approved.item.unit,
                "details": approved.item.details,
                "quantity": source.quantity,
                "activity": source.activity,
                "room": source.room,
                "section": source.section,
                "surface": source.surface,
                "damage_type": source.damage_type,
                "keywords": source.keywords,
                "note": source.note or source.description or source.section,
                "__metadata__": metadata,
            }
        )

    def _render_step(
        self,
        step: WorkflowStepTemplate,
        seq: int,
        context: _SafeFormatDict,
    ) -> CompiledCommand | None:
        if step.when == "has_quantity" and not context.get("quantity", "").strip():
            return None

        key = step.key.format_map(context).strip() if step.key else ""
        text = step.text.format_map(context).strip() if step.text else ""
        modifiers = tuple(part.format_map(context).strip().upper() for part in step.modifiers if part.strip())
        metadata = dict(context.get("__metadata__", {}))

        if step.kind == "text" and not text:
            return None
        if step.kind in {"key", "combo"} and not key:
            raise ValueError(f"Workflow step {step.kind} is missing a key.")
        if step.kind == "delay" and step.duration_ms <= 0:
            raise ValueError("Workflow delay steps must include duration_ms.")

        return CompiledCommand(
            seq=seq,
            kind=step.kind,
            key=key,
            text=text,
            modifiers=modifiers,
            duration_ms=step.duration_ms,
            delay_after_ms=step.delay_after_ms,
            repeat=step.repeat,
            metadata=metadata,
        )
