from __future__ import annotations

from dataclasses import asdict, dataclass, field
import json
from pathlib import Path
from typing import Any


def _normalize_db_path_template(value: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        return ""
    if not cleaned.startswith("/"):
        cleaned = f"/{cleaned}"
    return cleaned.rstrip("/") or "/"


def _normalize_confidence(value: str) -> str:
    cleaned = value.strip().lower()
    return cleaned if cleaned in {"low", "medium", "high"} else "high"


@dataclass(frozen=True)
class WorkflowStepTemplate:
    kind: str
    when: str = "always"
    key: str = ""
    text: str = ""
    modifiers: tuple[str, ...] = ()
    duration_ms: int = 0
    delay_after_ms: int = 0
    repeat: int = 1

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "WorkflowStepTemplate":
        modifiers_raw = raw.get("modifiers", ())
        if isinstance(modifiers_raw, str):
            modifiers = tuple(part.strip().upper() for part in modifiers_raw.split("+") if part.strip())
        else:
            modifiers = tuple(str(part).strip().upper() for part in modifiers_raw if str(part).strip())
        when = str(raw.get("when", "always")).strip().lower() or "always"
        if when not in {"always", "has_quantity"}:
            when = "always"
        return cls(
            kind=str(raw.get("kind", "")).strip().lower(),
            when=when,
            key=str(raw.get("key", "")).strip(),
            text=str(raw.get("text", "")).strip(),
            modifiers=modifiers,
            duration_ms=max(int(raw.get("duration_ms", 0) or 0), 0),
            delay_after_ms=max(int(raw.get("delay_after_ms", 0) or 0), 0),
            repeat=max(int(raw.get("repeat", 1) or 1), 1),
        )

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["modifiers"] = list(self.modifiers)
        return payload


@dataclass(frozen=True)
class WorkflowProfile:
    before_all: tuple[WorkflowStepTemplate, ...] = ()
    per_item: tuple[WorkflowStepTemplate, ...] = ()
    after_all: tuple[WorkflowStepTemplate, ...] = ()

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "WorkflowProfile":
        return cls(
            before_all=tuple(
                WorkflowStepTemplate.from_dict(step)
                for step in raw.get("before_all", [])
                if isinstance(step, dict)
            ),
            per_item=tuple(
                WorkflowStepTemplate.from_dict(step)
                for step in raw.get("per_item", [])
                if isinstance(step, dict)
            ),
            after_all=tuple(
                WorkflowStepTemplate.from_dict(step)
                for step in raw.get("after_all", [])
                if isinstance(step, dict)
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "before_all": [step.to_dict() for step in self.before_all],
            "per_item": [step.to_dict() for step in self.per_item],
            "after_all": [step.to_dict() for step in self.after_all],
        }


def default_workflow_profile() -> WorkflowProfile:
    return WorkflowProfile(
        per_item=(
            WorkflowStepTemplate(kind="key", key="F6", delay_after_ms=250),
            WorkflowStepTemplate(kind="text", text="{code}", delay_after_ms=90),
            WorkflowStepTemplate(kind="key", key="ENTER", delay_after_ms=350),
            WorkflowStepTemplate(kind="key", key="TAB", when="has_quantity", delay_after_ms=120),
            WorkflowStepTemplate(kind="text", text="{quantity}", when="has_quantity", delay_after_ms=90),
            WorkflowStepTemplate(kind="key", key="ENTER", delay_after_ms=300),
            WorkflowStepTemplate(kind="delay", duration_ms=150),
        )
    )


@dataclass(slots=True)
class ProducerConfig:
    runtime_api_base_url: str = "http://127.0.0.1:8787"
    runtime_api_key: str = ""
    producer_api_key: str = ""
    request_timeout_s: float = 20.0
    firebase_credentials_path: str = ""
    firebase_database_url: str = ""
    firebase_commands_path_template: str = "/bridges/{bridge_id}/commands"
    firebase_state_path_template: str = "/bridges/{bridge_id}/state"
    recommendation_limit: int = 5
    auto_approve_min_confidence: str = "high"
    workflow_profile: WorkflowProfile = field(default_factory=default_workflow_profile)

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "ProducerConfig":
        profile_raw = raw.get("workflow_profile")
        profile = WorkflowProfile.from_dict(profile_raw) if isinstance(profile_raw, dict) else default_workflow_profile()
        return cls(
            runtime_api_base_url=str(raw.get("runtime_api_base_url", "http://127.0.0.1:8787")).strip(),
            runtime_api_key=str(raw.get("runtime_api_key", "")).strip(),
            producer_api_key=str(raw.get("producer_api_key", "")).strip(),
            request_timeout_s=max(float(raw.get("request_timeout_s", 20.0) or 20.0), 1.0),
            firebase_credentials_path=str(raw.get("firebase_credentials_path", "")).strip(),
            firebase_database_url=str(raw.get("firebase_database_url", "")).strip(),
            firebase_commands_path_template=_normalize_db_path_template(
                str(raw.get("firebase_commands_path_template", "/bridges/{bridge_id}/commands"))
            ),
            firebase_state_path_template=_normalize_db_path_template(
                str(raw.get("firebase_state_path_template", "/bridges/{bridge_id}/state"))
            ),
            recommendation_limit=max(int(raw.get("recommendation_limit", 5) or 5), 1),
            auto_approve_min_confidence=_normalize_confidence(str(raw.get("auto_approve_min_confidence", "high"))),
            workflow_profile=profile,
        )

    @classmethod
    def load(cls, path: Path) -> "ProducerConfig":
        data = json.loads(path.read_text(encoding="utf-8"))
        return cls.from_dict(data).resolved(path.parent)

    def resolved(self, base_dir: Path) -> "ProducerConfig":
        payload = self.to_dict()
        credentials_path = str(payload["firebase_credentials_path"]).strip()
        if credentials_path:
            payload["firebase_credentials_path"] = (
                str((base_dir / credentials_path).resolve())
                if not Path(credentials_path).is_absolute()
                else credentials_path
            )
        return ProducerConfig.from_dict(payload)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.to_dict(), indent=2), encoding="utf-8")

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["workflow_profile"] = self.workflow_profile.to_dict()
        return payload

    def validate(self) -> list[str]:
        errors: list[str] = []
        if not self.runtime_api_base_url:
            errors.append("runtime_api_base_url is required")
        if self.request_timeout_s <= 0:
            errors.append("request_timeout_s must be positive")
        if not self.firebase_commands_path_template:
            errors.append("firebase_commands_path_template is required")
        if not self.firebase_state_path_template:
            errors.append("firebase_state_path_template is required")
        if self.recommendation_limit <= 0:
            errors.append("recommendation_limit must be positive")
        if not self.workflow_profile.per_item:
            errors.append("workflow_profile.per_item must include at least one step")
        return errors

    def validate_for_publish(self) -> list[str]:
        errors = self.validate()
        if not self.firebase_credentials_path:
            errors.append("firebase_credentials_path is required for publish")
        if not self.firebase_database_url:
            errors.append("firebase_database_url is required for publish")
        credentials_path = Path(self.firebase_credentials_path)
        if self.firebase_credentials_path and not credentials_path.exists():
            errors.append(f"firebase_credentials_path does not exist: {credentials_path}")
        return errors

    def commands_path(self, bridge_id: str) -> str:
        rendered = self.firebase_commands_path_template.format(bridge_id=bridge_id.strip() or "default")
        return _normalize_db_path_template(rendered)

    def state_path(self, bridge_id: str) -> str:
        rendered = self.firebase_state_path_template.format(bridge_id=bridge_id.strip() or "default")
        return _normalize_db_path_template(rendered)

