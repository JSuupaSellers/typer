from __future__ import annotations

from contextlib import contextmanager
from time import time
from typing import Any
import uuid

import firebase_admin
from firebase_admin import credentials, db

from .config import ProducerConfig
from .models import CompiledJob, PublishResult, QueueSnapshot


def _as_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _max_sequence(payload: Any) -> int:
    if not isinstance(payload, dict):
        return 0
    max_seq = 0
    for key, value in payload.items():
        seq = 0
        if isinstance(value, dict):
            seq = _as_int(value.get("seq"))
        if seq <= 0:
            seq = _as_int(key)
        max_seq = max(max_seq, seq)
    return max_seq


class FirebaseCommandPublisher:
    def __init__(self, config: ProducerConfig) -> None:
        self._config = config

    def snapshot(self, bridge_id: str) -> QueueSnapshot:
        with self._session(bridge_id) as (commands_ref, state_ref):
            commands_payload = commands_ref.get() or {}
            state_payload = state_ref.get() or {}

        last_applied_seq = _as_int(state_payload.get("last_applied_seq"))
        max_published_seq = _max_sequence(commands_payload)
        producer_state = state_payload.get("producer", {}) if isinstance(state_payload, dict) else {}
        last_reserved_seq = _as_int(producer_state.get("last_reserved_seq"))
        next_seq = max(last_applied_seq, max_published_seq, last_reserved_seq) + 1

        return QueueSnapshot(
            bridge_id=bridge_id,
            last_applied_seq=last_applied_seq,
            max_published_seq=max_published_seq,
            last_reserved_seq=last_reserved_seq,
            next_seq=next_seq,
            commands_path=self._config.commands_path(bridge_id),
            state_path=self._config.state_path(bridge_id),
        )

    def reserve_sequence_range(
        self,
        bridge_id: str,
        job_id: str,
        command_count: int,
        floor_seq: int,
    ) -> int:
        if command_count <= 0:
            raise ValueError("command_count must be positive")

        with self._session(bridge_id) as (_, state_ref):
            reservation_ref = state_ref.child("producer")
            reserved_start: list[int] = [0]

            def update(current: Any) -> dict[str, Any]:
                payload = current if isinstance(current, dict) else {}
                last_reserved_seq = _as_int(payload.get("last_reserved_seq"))
                start_seq = max(last_reserved_seq + 1, max(floor_seq, 0) + 1)
                end_seq = start_seq + command_count - 1
                reserved_start[0] = start_seq
                return {
                    **payload,
                    "active_job_id": job_id,
                    "last_reserved_seq": end_seq,
                    "last_reserved_count": command_count,
                    "last_reserved_at_unix_s": time(),
                }

            reservation_ref.transaction(update)
        return reserved_start[0]

    def publish(self, compiled_job: CompiledJob) -> PublishResult:
        bridge_id = compiled_job.bridge_id
        job_id = compiled_job.job_id
        commands_path = self._config.commands_path(bridge_id)
        state_path = self._config.state_path(bridge_id)
        payload = {str(command.seq): command.queue_payload() for command in compiled_job.commands}

        with self._session(bridge_id) as (commands_ref, state_ref):
            commands_ref.update(payload)
            state_ref.update(
                {
                    "active_job_id": job_id,
                    "last_published_seq": compiled_job.ending_seq,
                    "last_published_at_unix_s": time(),
                    "published_command_count": compiled_job.command_count,
                    "published_from_seq": compiled_job.starting_seq,
                    "published_to_seq": compiled_job.ending_seq,
                }
            )

        approved_codes = tuple(
            item.approved_candidate.item.code
            for item in compiled_job.plan.items
            if item.approved_candidate is not None
        )
        return PublishResult(
            job_id=job_id,
            bridge_id=bridge_id,
            command_count=compiled_job.command_count,
            starting_seq=compiled_job.starting_seq,
            ending_seq=compiled_job.ending_seq,
            commands_path=commands_path,
            state_path=state_path,
            approved_codes=approved_codes,
        )

    @contextmanager
    def _session(self, bridge_id: str):
        credential = credentials.Certificate(self._config.firebase_credentials_path)
        app_name = f"xactimate-producer-{bridge_id}-{uuid.uuid4().hex}"
        app = firebase_admin.initialize_app(
            credential,
            {"databaseURL": self._config.firebase_database_url},
            name=app_name,
        )
        try:
            commands_ref = db.reference(self._config.commands_path(bridge_id), app=app)
            state_ref = db.reference(self._config.state_path(bridge_id), app=app)
            yield commands_ref, state_ref
        finally:
            firebase_admin.delete_app(app)

