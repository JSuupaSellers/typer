from __future__ import annotations

import argparse
import json
from pathlib import Path

import uvicorn

from .api import create_app
from .config import ProducerConfig
from .drafts import DraftCoordinator, DraftStore
from .direct_output import DirectOutputService
from .estimate_export import EstimateExportService
from .models import EstimateJob
from .openai_agent import OpenAIDraftAgent
from .policy import PolicyEngine
from .publisher import FirebaseCommandPublisher
from .runtime_client import RuntimeCatalogClient
from .service import ProducerReviewRequiredError, ProducerService
from .transcription import OpenAITranscriptionService, TranscriptionConfig
from .workflow_agents import ClaimOrchestratorAgent, RoomPlannerAgent, RoomVerifier


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Compile curated Xactimate recommendations into Firebase command streams.")
    parser.add_argument("--config", required=True, help="Path to the producer config JSON")

    subparsers = parser.add_subparsers(dest="command", required=True)

    plan_parser = subparsers.add_parser("plan", help="Resolve scope items against the runtime API.")
    plan_parser.add_argument("--job", required=True, help="Path to the estimate job JSON")
    plan_parser.add_argument("--output", default="", help="Optional path to write the JSON result")

    compile_parser = subparsers.add_parser("compile", help="Compile an approved job into a command stream preview.")
    compile_parser.add_argument("--job", required=True, help="Path to the estimate job JSON")
    compile_parser.add_argument("--starting-seq", type=int, default=1, help="Starting sequence number for preview output")
    compile_parser.add_argument("--output", default="", help="Optional path to write the JSON result")

    publish_parser = subparsers.add_parser("publish", help="Reserve sequence numbers and publish the job to Firebase.")
    publish_parser.add_argument("--job", required=True, help="Path to the estimate job JSON")
    publish_parser.add_argument("--output", default="", help="Optional path to write the JSON result")

    serve_parser = subparsers.add_parser("serve", help="Serve the producer API.")
    serve_parser.add_argument("--host", default="127.0.0.1", help="Bind host")
    serve_parser.add_argument("--port", type=int, default=8790, help="Bind port")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    config = ProducerConfig.load(Path(args.config))

    if args.command == "serve":
        errors = config.validate()
        if errors:
            raise ValueError("; ".join(errors))
        with RuntimeCatalogClient(
            config.runtime_api_base_url,
            api_key=config.runtime_api_key,
            timeout_s=config.request_timeout_s,
        ) as runtime_client:
            publisher = None
            publish_errors = config.validate_for_publish()
            if not publish_errors:
                publisher = FirebaseCommandPublisher(config)
            service = ProducerService(config, runtime_client, publisher)
            transcription_service = OpenAITranscriptionService(
                TranscriptionConfig(
                    base_url=config.openai_base_url,
                    api_key=config.openai_api_key,
                    model=config.transcription_model,
                    timeout_s=config.request_timeout_s,
                )
            ) if config.openai_api_key.strip() else None
            policy_engine = PolicyEngine(config.policy_path)
            draft_coordinator = DraftCoordinator(
                DraftStore(config.draft_storage_dir),
                service,
                transcription_service=transcription_service,
                agent=OpenAIDraftAgent(config, runtime_client) if config.openai_api_key.strip() else None,
                orchestrator=ClaimOrchestratorAgent(config, policy_engine) if config.openai_api_key.strip() else None,
                room_planner=RoomPlannerAgent(config, runtime_client, policy_engine) if config.openai_api_key.strip() else None,
                room_verifier=RoomVerifier(policy_engine),
                policy_engine=policy_engine,
            )
            draft_coordinator._store.sync_policy_rules(policy_engine.to_rule_rows())
            app = create_app(
                config,
                service,
                transcription_service=transcription_service,
                draft_coordinator=draft_coordinator,
                direct_output_service=DirectOutputService(config, publisher),
                estimate_export_service=EstimateExportService(config, publisher),
            )
            uvicorn.run(app, host=args.host, port=args.port)
        return 0

    errors = config.validate()
    if errors:
        raise ValueError("; ".join(errors))
    if args.command == "publish":
        publish_errors = config.validate_for_publish()
        if publish_errors:
            raise ValueError("; ".join(publish_errors))

    job = EstimateJob.from_json_path(args.job)

    with RuntimeCatalogClient(
        config.runtime_api_base_url,
        api_key=config.runtime_api_key,
        timeout_s=config.request_timeout_s,
    ) as runtime_client:
        publisher = FirebaseCommandPublisher(config) if args.command == "publish" else None
        service = ProducerService(config, runtime_client, publisher)

        if args.command == "plan":
            payload = service.plan_job(job).to_dict()
            _emit_json(payload, args.output)
            return 0

        if args.command == "compile":
            try:
                payload = service.compile_job(job, starting_seq=args.starting_seq).to_dict()
                _emit_json(payload, args.output)
                return 0
            except ProducerReviewRequiredError as exc:
                payload = {"error": "review_required", "message": str(exc), "plan": exc.plan.to_dict()}
                _emit_json(payload, args.output)
                return 2

        if args.command == "publish":
            try:
                payload = service.publish_job(job).to_dict()
                _emit_json(payload, args.output)
                return 0
            except ProducerReviewRequiredError as exc:
                payload = {"error": "review_required", "message": str(exc), "plan": exc.plan.to_dict()}
                _emit_json(payload, args.output)
                return 2

    parser.error(f"Unknown command: {args.command}")
    return 2


def _emit_json(payload: dict[str, object], output_path: str) -> None:
    text = json.dumps(payload, indent=2)
    if output_path:
        path = Path(output_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text + "\n", encoding="utf-8")
        return
    print(text)


if __name__ == "__main__":
    raise SystemExit(main())
