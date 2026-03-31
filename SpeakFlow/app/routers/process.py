import base64
import json
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, File, Form, HTTPException, Query, UploadFile
from fastapi.responses import StreamingResponse

from app.config import settings
from app.models.schemas import ProcessResponse
from app.services.history_service import create_history_record
from app.services.openai_service import process_audio, process_audio_stream
from app.services.usage_service import increment_usage
from app.utils.audio import validate_audio
from app.utils.image import optimize_image

logger = logging.getLogger(__name__)
router = APIRouter()

MAX_IMAGE_SIZE_MB = 10
MAX_VOCABULARY_PROMPT_CHARS = 4000
ALLOWED_IMAGE_CONTENT_TYPES = {"image/png", "image/jpeg", "image/webp"}
ALLOWED_REASONING_EFFORTS = {"low", "medium", "high"}


async def _save_record_and_usage(meta: dict) -> tuple[dict, list[str]]:
    warnings: list[str] = []
    record = {"id": None, "created_at": datetime.now(timezone.utc)}
    try:
        record = await create_history_record(
            transcription=meta["transcription"],
            result=meta["result"],
            audio_duration_seconds=meta["audio_duration_seconds"],
            processing_time_ms=meta["processing_time_ms"],
            whisper_model=settings.whisper_model,
            gpt_model=settings.gpt_model,
            input_token_count=meta["input_tokens"],
            output_token_count=meta["output_tokens"],
        )
    except Exception as exc:
        logger.error("create_history_record failed: %s", exc, exc_info=True)
        warnings.append("history_save_failed")

    try:
        await increment_usage(
            audio_seconds=meta["audio_duration_seconds"],
            input_tokens=meta["input_tokens"],
            output_tokens=meta["output_tokens"],
        )
    except Exception as exc:
        logger.error("increment_usage failed: %s", exc, exc_info=True)
        warnings.append("usage_update_failed")

    return record, warnings


@router.post("/process")
async def process_voice(
    audio: UploadFile = File(...),
    context_text: str | None = Form(None),
    context_image: UploadFile | None = File(None),
    reasoning_effort: str | None = Form(None),
    vocabulary_prompt: str | None = Form(None),
    language: str | None = Query(None),
    stream: bool = Query(False),
):
    logger.info("process_voice: file=%s content_type=%s stream=%s", audio.filename, audio.content_type, stream)

    if reasoning_effort and reasoning_effort not in ALLOWED_REASONING_EFFORTS:
        raise HTTPException(status_code=400, detail="Invalid reasoning_effort value.")

    if vocabulary_prompt and len(vocabulary_prompt) > MAX_VOCABULARY_PROMPT_CHARS:
        raise HTTPException(status_code=400, detail="Vocabulary prompt is too long.")

    try:
        audio_bytes = await validate_audio(audio)
    except HTTPException:
        raise
    logger.info("Audio validated: %d bytes", len(audio_bytes))

    # Process optional context image
    context_image_base64 = None
    context_image_media_type = "image/png"
    if context_image and context_image.filename:
        if context_image.content_type not in ALLOWED_IMAGE_CONTENT_TYPES:
            raise HTTPException(status_code=415, detail="Unsupported screenshot content type.")
        image_bytes = await context_image.read()
        if len(image_bytes) > MAX_IMAGE_SIZE_MB * 1024 * 1024:
            raise HTTPException(status_code=413, detail=f"Screenshot exceeds {MAX_IMAGE_SIZE_MB}MB limit.")
        if len(image_bytes) > 0:
            original_size = len(image_bytes)
            image_bytes, context_image_media_type = optimize_image(image_bytes, context_image.content_type or "image/png")
            logger.info("Image optimized %d -> %d bytes", original_size, len(image_bytes))
            context_image_base64 = base64.b64encode(image_bytes).decode("utf-8")

    if stream:
        return await _stream_response(
            audio_bytes, audio.filename or "audio.wav", language,
            context_text=context_text, context_image_base64=context_image_base64,
            context_image_media_type=context_image_media_type,
            reasoning_effort=reasoning_effort,
            vocabulary_prompt=vocabulary_prompt,
        )

    try:
        result = await process_audio(
            audio_bytes=audio_bytes,
            filename=audio.filename or "audio.wav",
            language=language,
            context_text=context_text,
            context_image_base64=context_image_base64,
            context_image_media_type=context_image_media_type,
            reasoning_effort=reasoning_effort,
            vocabulary_prompt=vocabulary_prompt,
        )
    except Exception as e:
        logger.error("process_audio failed: %s", e, exc_info=True)
        raise

    record, warnings = await _save_record_and_usage(result)

    response = ProcessResponse(
        id=record.get("id"),
        transcription=result["transcription"],
        result=result["result"],
        processing_time_ms=result["processing_time_ms"],
        audio_duration_seconds=result["audio_duration_seconds"],
        created_at=record.get("created_at"),
    )
    if warnings:
        return {**response.model_dump(), "warnings": warnings}
    return response


async def _stream_response(
    audio_bytes: bytes,
    filename: str,
    language: str | None,
    context_text: str | None = None,
    context_image_base64: str | None = None,
    context_image_media_type: str = "image/png",
    reasoning_effort: str | None = None,
    vocabulary_prompt: str | None = None,
):
    stream_gen = process_audio_stream(
        audio_bytes=audio_bytes,
        filename=filename,
        language=language,
        context_text=context_text,
        context_image_base64=context_image_base64,
        context_image_media_type=context_image_media_type,
        reasoning_effort=reasoning_effort,
        vocabulary_prompt=vocabulary_prompt,
    )
    first_event = await stream_gen.__anext__()

    async def event_generator():
        meta = None
        for event in _filter_meta(first_event):
            if isinstance(event, dict):
                meta = event
            else:
                yield event

        async for event in stream_gen:
            for item in _filter_meta(event):
                if isinstance(item, dict):
                    meta = item
                else:
                    yield item

        if meta:
            await _save_record_and_usage(meta)
            yield f"data: {json.dumps(meta)}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


def _filter_meta(event: str) -> list:
    if event.startswith("data: {"):
        try:
            payload = json.loads(event[len("data: "):].strip())
            if payload.get("event") == "metadata":
                return [payload]
        except json.JSONDecodeError:
            pass
    return [event]
