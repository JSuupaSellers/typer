from __future__ import annotations

from typing import Annotated, Any

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Request, UploadFile

from .config import ProducerConfig
from .drafts import DraftCoordinator
from .direct_output import BridgeNotReadyError, DirectOutputService
from .models import EstimateJob
from .service import ProducerReviewRequiredError, ProducerService
from .transcription import (
    TranscriptionServiceProtocol,
    default_adjuster_prompt,
    default_direct_output_prompt,
)


def create_app(
    config: ProducerConfig,
    service: ProducerService,
    transcription_service: TranscriptionServiceProtocol | None = None,
    draft_coordinator: DraftCoordinator | None = None,
    direct_output_service: DirectOutputService | None = None,
) -> FastAPI:
    app = FastAPI(title="Xactimate Producer", version="0.1.0")
    app.state.config = config
    app.state.service = service
    app.state.transcription_service = transcription_service
    app.state.draft_coordinator = draft_coordinator
    app.state.direct_output_service = direct_output_service

    @app.on_event("startup")
    async def startup_resume_operations() -> None:
        coordinator = app.state.draft_coordinator
        if coordinator is not None:
            await coordinator.resume_pending_operations()

    def get_service(request: Request) -> ProducerService:
        return request.app.state.service

    def get_transcription_service(request: Request) -> TranscriptionServiceProtocol | None:
        return request.app.state.transcription_service

    def get_draft_coordinator(request: Request) -> DraftCoordinator:
        coordinator = request.app.state.draft_coordinator
        if coordinator is None:
            raise HTTPException(status_code=503, detail="Draft coordination is not configured.")
        return coordinator

    def get_direct_output_service(request: Request) -> DirectOutputService:
        direct = request.app.state.direct_output_service
        if direct is None:
            raise HTTPException(status_code=503, detail="Direct output is not configured.")
        return direct

    def draft_payload(drafts: DraftCoordinator, job_id: str, draft) -> dict[str, Any]:
        return {
            "draft": draft.to_dict(),
            "grouped_sections": draft.grouped_sections(),
            "room_states": drafts.list_room_states(job_id),
            "claim_status": drafts.claim_status(job_id),
            "operations": drafts.list_operations(job_id, include_completed=False),
        }

    def authorize(
        request: Request,
        x_api_key: Annotated[str | None, Header()] = None,
    ) -> None:
        configured_key = request.app.state.config.producer_api_key
        if configured_key and x_api_key != configured_key:
            raise HTTPException(status_code=401, detail="Invalid API key.")

    @app.get("/health")
    def health(request: Request, _auth: None = Depends(authorize)) -> dict[str, object]:
        runtime_url = request.app.state.config.runtime_api_base_url
        return {
            "status": "ok",
            "runtime_api_base_url": runtime_url,
            "commands_path_template": request.app.state.config.firebase_commands_path_template,
            "state_path_template": request.app.state.config.firebase_state_path_template,
            "draft_storage_dir": request.app.state.config.draft_storage_dir,
        }

    @app.post("/capture/intake")
    async def capture_intake(
        job_id: Annotated[str, Form()] = "job",
        bridge_id: Annotated[str, Form()] = "default",
        item_id: Annotated[str, Form()] = "scope-1",
        room: Annotated[str, Form()] = "",
        surface: Annotated[str, Form()] = "",
        damage_type: Annotated[str, Form()] = "",
        keywords: Annotated[str, Form()] = "",
        quantity: Annotated[str, Form()] = "",
        description: Annotated[str, Form()] = "",
        audio: UploadFile | None = File(default=None),
        photos: list[UploadFile] = File(default_factory=list),
        _auth: None = Depends(authorize),
        transcription: TranscriptionServiceProtocol | None = Depends(get_transcription_service),
    ) -> dict[str, object]:
        transcript = ""
        warnings: list[str] = []
        audio_filename = ""

        if audio is not None and audio.filename:
            audio_filename = audio.filename
            audio_bytes = await audio.read()
            if transcription is None:
                warnings.append("Audio was uploaded, but backend transcription is not configured.")
            elif audio_bytes:
                transcript = await transcription.transcribe_audio(
                    audio.filename,
                    audio_bytes,
                    prompt=default_adjuster_prompt(),
                )

        photo_filenames = [photo.filename or f"photo-{index + 1}" for index, photo in enumerate(photos)]
        description_parts = [description.strip()]
        if transcript and transcript.lower() != description.strip().lower():
            description_parts.append(transcript)
        combined_description = "\n\n".join(part for part in description_parts if part)

        draft_job = {
            "job_id": job_id.strip() or "job",
            "bridge_id": bridge_id.strip() or "default",
            "items": [
                {
                    "item_id": item_id.strip() or "scope-1",
                    "description": combined_description,
                    "room": room.strip(),
                    "surface": surface.strip(),
                    "damage_type": damage_type.strip(),
                    "keywords": keywords.strip(),
                    "quantity": quantity.strip(),
                }
            ],
        }

        return {
            "status": "ok",
            "message": "Capture draft prepared." if not warnings else " ".join(warnings),
            "transcript": transcript,
            "audio_filename": audio_filename,
            "photo_count": len(photo_filenames),
            "photo_filenames": photo_filenames,
            "job": draft_job,
        }

    @app.post("/direct/compose")
    async def direct_compose(
        payload: dict,
        _auth: None = Depends(authorize),
        direct: DirectOutputService = Depends(get_direct_output_service),
    ) -> dict[str, object]:
        prompt = str(payload.get("prompt", payload.get("text", ""))).strip()
        bridge_id = str(payload.get("bridge_id", payload.get("bridgeId", "default"))).strip() or "default"
        try:
            result = await direct.compose(prompt=prompt, bridge_id=bridge_id)
        except RuntimeError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        return {"status": "ok", **result.to_dict()}

    @app.post("/direct/voice-compose")
    async def direct_voice_compose(
        bridge_id: Annotated[str, Form()] = "default",
        prompt: Annotated[str, Form()] = "",
        audio: UploadFile | None = File(default=None),
        _auth: None = Depends(authorize),
        direct: DirectOutputService = Depends(get_direct_output_service),
        transcription: TranscriptionServiceProtocol | None = Depends(get_transcription_service),
    ) -> dict[str, object]:
        if audio is None or not audio.filename:
            raise HTTPException(status_code=400, detail="Audio is required for direct voice compose.")
        content = await audio.read()
        if not content:
            raise HTTPException(status_code=400, detail="Audio upload was empty.")
        if transcription is None:
            raise HTTPException(status_code=503, detail="Audio transcription is not configured.")
        transcript = await transcription.transcribe_audio(
            audio.filename,
            content,
            prompt=default_direct_output_prompt(),
        )
        try:
            result = await direct.compose(
                prompt=prompt.strip(),
                bridge_id=bridge_id.strip() or "default",
                transcript=transcript,
            )
        except RuntimeError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        return {"status": "ok", **result.to_dict()}

    @app.post("/direct/publish")
    def direct_publish(
        payload: dict,
        _auth: None = Depends(authorize),
        direct: DirectOutputService = Depends(get_direct_output_service),
    ) -> dict[str, object]:
        bridge_id = str(payload.get("bridge_id", payload.get("bridgeId", "default"))).strip() or "default"
        text = str(payload.get("text", "")).strip()
        title = str(payload.get("title", "")).strip()
        append_enter = bool(payload.get("send_enter", payload.get("append_enter", False)))
        try:
            result = direct.publish_text(
                bridge_id=bridge_id,
                text=text,
                title=title,
                append_enter=append_enter,
            )
        except BridgeNotReadyError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except RuntimeError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        return {"status": "ok", **result.to_dict()}

    @app.post("/drafts/open")
    def open_draft(
        payload: dict,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        job_id = str(payload.get("job_id", payload.get("jobId", ""))).strip() or "job"
        bridge_id = str(payload.get("bridge_id", payload.get("bridgeId", "default"))).strip() or "default"
        draft = drafts.open_draft(job_id, bridge_id)
        return {"status": "ok", **draft_payload(drafts, draft.job_id, draft)}

    @app.get("/drafts")
    def list_drafts(
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        return {
            "status": "ok",
            "drafts": [summary.to_dict() for summary in drafts.list_drafts()],
        }

    @app.get("/drafts/{job_id}")
    def get_draft(
        job_id: str,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        try:
            draft = drafts.get_draft(job_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=f"Unknown draft job: {job_id}") from exc
        return {"status": "ok", **draft_payload(drafts, job_id, draft)}

    @app.post("/drafts/{job_id}/messages")
    async def create_message_operation(
        job_id: str,
        payload: dict,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        bridge_id = str(payload.get("bridge_id", payload.get("bridgeId", "default"))).strip() or "default"
        text = str(payload.get("text", "")).strip()
        try:
            result = await drafts.submit_text_operation(job_id, bridge_id, text)
        except RuntimeError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"status": "ok", **result}

    @app.get("/operations/{operation_id}")
    def get_operation(
        operation_id: str,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        try:
            result = drafts.get_operation(operation_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=f"Unknown operation: {operation_id}") from exc
        return {"status": "ok", **result}

    @app.post("/drafts/{job_id}/chat")
    async def draft_chat(
        job_id: str,
        payload: dict,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        bridge_id = str(payload.get("bridge_id", payload.get("bridgeId", "default"))).strip() or "default"
        text = str(payload.get("text", "")).strip()
        try:
            result = await drafts.apply_text_turn(job_id, bridge_id, text)
        except RuntimeError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        return {
            "status": "ok",
            **result.to_dict(),
        }

    @app.post("/drafts/{job_id}/voice-messages")
    async def create_voice_operation(
        job_id: str,
        bridge_id: Annotated[str, Form()] = "default",
        text: Annotated[str, Form()] = "",
        audio: UploadFile | None = File(default=None),
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        if audio is None or not audio.filename:
            raise HTTPException(status_code=400, detail="Audio is required for a voice turn.")
        content = await audio.read()
        if not content:
            raise HTTPException(status_code=400, detail="Audio upload was empty.")
        try:
            result = await drafts.submit_voice_operation(job_id, bridge_id, audio.filename, content, text)
        except RuntimeError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"status": "ok", **result}

    @app.post("/drafts/{job_id}/voice-turn")
    async def draft_voice_turn(
        job_id: str,
        bridge_id: Annotated[str, Form()] = "default",
        text: Annotated[str, Form()] = "",
        audio: UploadFile | None = File(default=None),
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        if audio is None or not audio.filename:
            raise HTTPException(status_code=400, detail="Audio is required for a voice turn.")
        content = await audio.read()
        if not content:
            raise HTTPException(status_code=400, detail="Audio upload was empty.")
        try:
            result = await drafts.apply_voice_turn(job_id, bridge_id, audio.filename, content, text)
        except RuntimeError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        return {
            "status": "ok",
            **result.to_dict(),
        }

    @app.post("/drafts/{job_id}/items/{item_id}/status")
    def set_draft_item_status(
        job_id: str,
        item_id: str,
        payload: dict,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        try:
            draft = drafts.set_item_status(job_id, item_id, str(payload.get("status", "accepted")))
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=f"Unknown draft job: {job_id}") from exc
        return {"status": "ok", **draft_payload(drafts, job_id, draft)}

    @app.post("/drafts/{job_id}/accept-all")
    def accept_all_draft_items(
        job_id: str,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        try:
            draft = drafts.accept_all(job_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=f"Unknown draft job: {job_id}") from exc
        return {"status": "ok", **draft_payload(drafts, job_id, draft)}

    @app.post("/drafts/{job_id}/plan")
    def plan_draft(
        job_id: str,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        try:
            return {"status": "ok", **drafts.plan_draft(job_id)}
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=f"Unknown draft job: {job_id}") from exc

    @app.post("/drafts/{job_id}/publish")
    def publish_draft(
        job_id: str,
        _auth: None = Depends(authorize),
        drafts: DraftCoordinator = Depends(get_draft_coordinator),
    ) -> dict[str, object]:
        try:
            return {"status": "ok", **drafts.publish_draft(job_id)}
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=f"Unknown draft job: {job_id}") from exc
        except ProducerReviewRequiredError as exc:
            raise HTTPException(status_code=409, detail={"message": str(exc), "plan": exc.plan.to_dict()}) from exc

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
