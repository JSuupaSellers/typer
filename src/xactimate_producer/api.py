from __future__ import annotations

from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request

from .config import ProducerConfig
from .models import EstimateJob
from .service import ProducerReviewRequiredError, ProducerService


def create_app(config: ProducerConfig, service: ProducerService) -> FastAPI:
    app = FastAPI(title="Xactimate Producer", version="0.1.0")
    app.state.config = config
    app.state.service = service

    def get_service(request: Request) -> ProducerService:
        return request.app.state.service

    def authorize(
        request: Request,
        x_api_key: Annotated[str | None, Header()] = None,
    ) -> None:
        configured_key = request.app.state.config.producer_api_key
        if configured_key and x_api_key != configured_key:
            raise HTTPException(status_code=401, detail="Invalid API key.")

    @app.get("/health")
    def health(_auth: None = Depends(authorize), request: Request = None) -> dict[str, object]:
        runtime_url = request.app.state.config.runtime_api_base_url
        return {
            "status": "ok",
            "runtime_api_base_url": runtime_url,
            "commands_path_template": request.app.state.config.firebase_commands_path_template,
            "state_path_template": request.app.state.config.firebase_state_path_template,
        }

    @app.post("/plan")
    def plan(payload: dict, _auth: None = Depends(authorize), service: ProducerService = Depends(get_service)) -> dict[str, object]:
        job = EstimateJob.from_dict(payload)
        plan = service.plan_job(job)
        return plan.to_dict()

    @app.post("/compile")
    def compile_job(
        payload: dict,
        _auth: None = Depends(authorize),
        service: ProducerService = Depends(get_service),
    ) -> dict[str, object]:
        starting_seq = int(payload.get("starting_seq", 1) or 1)
        job_payload = payload.get("job") if isinstance(payload.get("job"), dict) else payload
        job = EstimateJob.from_dict(job_payload)
        try:
            compiled = service.compile_job(job, starting_seq=starting_seq)
        except ProducerReviewRequiredError as exc:
            raise HTTPException(status_code=409, detail={"message": str(exc), "plan": exc.plan.to_dict()}) from exc
        return compiled.to_dict()

    @app.post("/publish")
    def publish_job(
        payload: dict,
        _auth: None = Depends(authorize),
        service: ProducerService = Depends(get_service),
    ) -> dict[str, object]:
        job = EstimateJob.from_dict(payload)
        try:
            result = service.publish_job(job)
        except ProducerReviewRequiredError as exc:
            raise HTTPException(status_code=409, detail={"message": str(exc), "plan": exc.plan.to_dict()}) from exc
        return result.to_dict()

    return app

