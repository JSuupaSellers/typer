from __future__ import annotations

from dataclasses import dataclass, field

from .models import KeyboardCommand


@dataclass(slots=True)
class PendingCommandBuffer:
    next_seq: int = 1
    _pending: dict[int, KeyboardCommand] = field(default_factory=dict)

    def push(self, commands: list[KeyboardCommand]) -> list[KeyboardCommand]:
        for command in commands:
            if command.seq < self.next_seq:
                continue
            self._pending.setdefault(command.seq, command)
        ready: list[KeyboardCommand] = []
        while self.next_seq in self._pending:
            ready.append(self._pending.pop(self.next_seq))
            self.next_seq += 1
        return ready

    def pending_count(self) -> int:
        return len(self._pending)

