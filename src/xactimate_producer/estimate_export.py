from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol
from uuid import uuid4

from .config import ProducerConfig
from .direct_output import BridgeNotReadyError
from .models import CompiledCommand, PublishResult, QueueSnapshot


def _now_stamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%d-%H%M%S")


class EstimateExportPublisherProtocol(Protocol):
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


@dataclass(frozen=True)
class EstimateExportRow:
    cat: str
    sel: str
    quantity: str

    @classmethod
    def from_payload(cls, raw: dict[str, Any], index: int) -> "EstimateExportRow":
        cat = str(raw.get("cat", raw.get("category", ""))).strip().upper()
        sel = str(raw.get("sel", raw.get("selector", ""))).strip().upper()
        cat_sel = str(raw.get("cat_sel", raw.get("catSel", raw.get("code", "")))).strip().upper()
        quantity = str(raw.get("quantity", raw.get("qty", ""))).strip()
        if (not cat or not sel) and cat_sel:
            cat, sel = cls._split_cat_sel(cat_sel=cat_sel, index=index)
        if not cat:
            raise RuntimeError(f"Export row {index} is missing cat.")
        if not sel:
            raise RuntimeError(f"Export row {index} is missing sel.")
        if not quantity:
            raise RuntimeError(f"Export row {index} is missing quantity.")
        return cls(cat=cat, sel=sel, quantity=quantity)

    @property
    def cat_sel(self) -> str:
        return f"{self.cat}/{self.sel}"

    def to_dict(self) -> dict[str, str]:
        return {
            "cat": self.cat,
            "sel": self.sel,
            "cat_sel": self.cat_sel,
            "quantity": self.quantity,
        }

    @staticmethod
    def _split_cat_sel(*, cat_sel: str, index: int) -> tuple[str, str]:
        if "/" not in cat_sel:
            raise RuntimeError(f"Export row {index} cat_sel must look like CAT/SEL.")
        cat, sel = cat_sel.split("/", 1)
        cat = cat.strip().upper()
        sel = sel.strip().upper()
        if not cat or not sel:
            raise RuntimeError(f"Export row {index} cat_sel must include both CAT and SEL.")
        return cat, sel


@dataclass(frozen=True)
class EstimateExportPublishEnvelope:
    publish: PublishResult
    bridge_id: str
    title: str
    rows: tuple[EstimateExportRow, ...]
    command_count_preview: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "publish": self.publish.to_dict(),
            "bridge_id": self.bridge_id,
            "title": self.title,
            "rows": [row.to_dict() for row in self.rows],
            "row_count": len(self.rows),
            "command_count_preview": self.command_count_preview,
        }


class EstimateExportService:
    def __init__(
        self,
        config: ProducerConfig,
        publisher: EstimateExportPublisherProtocol | None = None,
    ) -> None:
        self._config = config
        self._publisher = publisher

    def publish_rows(
        self,
        *,
        bridge_id: str,
        rows: tuple[EstimateExportRow, ...],
        title: str = "",
    ) -> EstimateExportPublishEnvelope:
        if self._publisher is None:
            raise RuntimeError("Firebase publish is not configured for estimate export.")
        if not rows:
            raise RuntimeError("At least one estimate export row is required.")

        bridge = bridge_id.strip() or "default"
        snapshot = self._publisher.snapshot(bridge)
        if not snapshot.bridge_online:
            raise BridgeNotReadyError(
                f"Bridge {bridge} is offline or stale. Make sure the Pi bridge is running before exporting rows."
            )
        if not snapshot.bridge_ready:
            raise BridgeNotReadyError(
                f"Bridge {bridge} is still busy with {snapshot.pending_command_count} pending command(s). Wait for it to go idle."
            )

        commands = self.compile_row_commands(rows=rows)
        job_id = f"estimate-export-{_now_stamp()}-{uuid4().hex[:6]}"
        publish = self._publisher.publish_commands(
            bridge_id=bridge,
            job_id=job_id,
            commands=commands,
            approved_codes=tuple(row.cat_sel for row in rows),
        )
        return EstimateExportPublishEnvelope(
            publish=publish,
            bridge_id=bridge,
            title=title.strip() or "Estimate Export",
            rows=rows,
            command_count_preview=len(commands),
        )

    def compile_row_commands(
        self,
        *,
        rows: tuple[EstimateExportRow, ...],
        starting_seq: int = 1,
    ) -> tuple[CompiledCommand, ...]:
        commands: list[CompiledCommand] = []
        seq = starting_seq
        commands.append(
            CompiledCommand(
                seq=seq,
                kind="upall",
                delay_after_ms=self._config.estimate_export_initial_delay_ms,
                metadata={"mode": "estimate_export", "command_role": "reset_modifiers"},
            )
        )
        seq += 1

        for row_index, row in enumerate(rows, start=1):
            for character in row.cat:
                commands.append(
                    CompiledCommand(
                        seq=seq,
                        kind="key",
                        key=self._key_token_for_character(character),
                        delay_after_ms=self._config.estimate_export_key_delay_ms,
                        metadata={
                            "mode": "estimate_export",
                            "command_role": "cat",
                            "row_index": row_index,
                        },
                    )
                )
                seq += 1

            commands.append(
                CompiledCommand(
                    seq=seq,
                    kind="key",
                    key="TAB",
                    delay_after_ms=self._config.estimate_export_tab_delay_ms,
                    metadata={
                        "mode": "estimate_export",
                        "command_role": "advance_to_sel",
                        "row_index": row_index,
                    },
                )
            )
            seq += 1

            for character in row.sel:
                commands.append(
                    CompiledCommand(
                        seq=seq,
                        kind="key",
                        key=self._key_token_for_character(character),
                        delay_after_ms=self._config.estimate_export_key_delay_ms,
                        metadata={
                            "mode": "estimate_export",
                            "command_role": "sel",
                            "row_index": row_index,
                        },
                    )
                )
                seq += 1

            commands.append(
                CompiledCommand(
                    seq=seq,
                    kind="key",
                    key="TAB",
                    delay_after_ms=self._config.estimate_export_tab_delay_ms,
                    metadata={
                        "mode": "estimate_export",
                        "command_role": "advance_to_quantity",
                        "row_index": row_index,
                    },
                )
            )
            seq += 1

            for character in row.quantity:
                commands.append(
                    CompiledCommand(
                        seq=seq,
                        kind="key",
                        key=self._key_token_for_character(character),
                        delay_after_ms=self._delay_for_quantity_character(character),
                        metadata={
                            "mode": "estimate_export",
                            "command_role": "quantity",
                            "row_index": row_index,
                        },
                    )
                )
                seq += 1

            commands.append(
                CompiledCommand(
                    seq=seq,
                    kind="key",
                    key="ENTER",
                    delay_after_ms=self._config.estimate_export_row_advance_delay_ms,
                    metadata={
                        "mode": "estimate_export",
                        "command_role": "advance_to_next_row",
                        "row_index": row_index,
                    },
                )
            )
            seq += 1

        return tuple(commands)

    @staticmethod
    def parse_rows(raw_rows: Any) -> tuple[EstimateExportRow, ...]:
        if not isinstance(raw_rows, list):
            raise RuntimeError("rows must be an array of {cat, sel, quantity} or {cat_sel, quantity} objects.")
        rows = tuple(
            EstimateExportRow.from_payload(raw, index + 1)
            for index, raw in enumerate(raw_rows)
            if isinstance(raw, dict)
        )
        if not rows:
            raise RuntimeError("rows must include at least one valid export row.")
        return rows

    @staticmethod
    def _key_token_for_character(character: str) -> str:
        if character == " ":
            return "SPACE"
        if character == "\t":
            return "TAB"
        return character

    def _delay_for_quantity_character(self, character: str) -> int:
        if character in {",", ".", "*", "+", "-", "/", "(", ")"}:
            return self._config.estimate_export_formula_key_delay_ms
        return self._config.estimate_export_key_delay_ms
