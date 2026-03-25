from __future__ import annotations

from dataclasses import dataclass, field
from time import monotonic

from .models import KeyboardCommand


@dataclass(frozen=True, slots=True)
class GapRecovery:
    skipped_from_seq: int
    skipped_to_seq: int
    ready: tuple[KeyboardCommand, ...]


@dataclass(slots=True)
class PendingCommandBuffer:
    next_seq: int = 1
    _pending: dict[int, KeyboardCommand] = field(default_factory=dict)
    _gap_started_at_monotonic_s: float | None = None

    def push(self, commands: list[KeyboardCommand]) -> list[KeyboardCommand]:
        for command in commands:
            if command.seq < self.next_seq:
                continue
            self._pending.setdefault(command.seq, command)
        ready = self._drain_ready()
        self._refresh_gap_state()
        return ready

    def pending_count(self) -> int:
        return len(self._pending)

    def recover_stale_gap(self, max_gap_age_s: float) -> GapRecovery | None:
        if max_gap_age_s <= 0:
            return None
        if not self._pending or self.next_seq in self._pending:
            self._refresh_gap_state()
            return None

        now = monotonic()
        if self._gap_started_at_monotonic_s is None:
            self._gap_started_at_monotonic_s = now
            return None

        if (now - self._gap_started_at_monotonic_s) < max_gap_age_s:
            return None

        next_available_seq = min(self._pending)
        skipped_from_seq = self.next_seq
        skipped_to_seq = next_available_seq - 1
        self.next_seq = next_available_seq
        ready = tuple(self._drain_ready())
        self._refresh_gap_state()
        return GapRecovery(
            skipped_from_seq=skipped_from_seq,
            skipped_to_seq=skipped_to_seq,
            ready=ready,
        )

    def _drain_ready(self) -> list[KeyboardCommand]:
        ready: list[KeyboardCommand] = []
        while self.next_seq in self._pending:
            ready.append(self._pending.pop(self.next_seq))
            self.next_seq += 1
        return ready

    def _refresh_gap_state(self) -> None:
        if self._pending and self.next_seq not in self._pending:
            if self._gap_started_at_monotonic_s is None:
                self._gap_started_at_monotonic_s = monotonic()
            return
        self._gap_started_at_monotonic_s = None
