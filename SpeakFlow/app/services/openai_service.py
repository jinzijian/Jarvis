import json
import logging
import time
from collections.abc import AsyncGenerator
from io import BytesIO

from openai import AsyncOpenAI, BadRequestError

from app.config import settings
from app.prompts import build_context_image_prompt, build_context_text_prompt, build_dictation_prompt

logger = logging.getLogger(__name__)

client = AsyncOpenAI(
    api_key=settings.openai_api_key,
    timeout=120.0,  # 2 minute timeout for all requests
)


def _build_messages(
    transcription: str,
    context_text: str | None = None,
    context_image_base64: str | None = None,
    context_image_media_type: str = "image/png",
) -> list[dict]:
    """Build GPT messages based on the input mode."""
    if context_image_base64:
        return [
            {"role": "system", "content": build_context_image_prompt()},
            {"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": f"data:{context_image_media_type};base64,{context_image_base64}"}},
                {"type": "text", "text": transcription},
            ]},
        ]
    elif context_text:
        return [
            {"role": "system", "content": build_context_text_prompt()},
            {"role": "user", "content": f"Selected text:\n{context_text}\n\nVoice command:\n{transcription}"},
        ]
    else:
        return [
            {"role": "system", "content": build_dictation_prompt()},
            {"role": "user", "content": transcription},
        ]


async def transcribe_audio(
    audio_bytes: bytes,
    filename: str,
    language: str | None = None,
    vocabulary_prompt: str | None = None,
) -> tuple[str, float | None]:
    audio_file = BytesIO(audio_bytes)
    audio_file.name = filename

    kwargs = {
        "model": settings.whisper_model,
        "file": audio_file,
        "response_format": "verbose_json",
    }
    if language:
        kwargs["language"] = language
    if vocabulary_prompt:
        kwargs["prompt"] = vocabulary_prompt

    logger.info(
        "Whisper transcription starting: model=%s, filename=%s, audio_size=%d bytes, language=%s",
        settings.whisper_model, filename, len(audio_bytes), language,
    )
    t0 = time.monotonic()
    try:
        response = await client.audio.transcriptions.create(**kwargs)
    except BadRequestError as e:
        if "too short" in str(e):
            logger.warning("Whisper rejected audio as too short: filename=%s", filename)
            from fastapi import HTTPException
            raise HTTPException(status_code=400, detail="Audio too short. Please record for longer.")
        logger.error("Whisper BadRequestError: filename=%s", filename, exc_info=True)
        raise
    except Exception:
        logger.error("Whisper transcription failed: filename=%s", filename, exc_info=True)
        raise
    whisper_ms = int((time.monotonic() - t0) * 1000)
    audio_duration = getattr(response, "duration", None)
    logger.info(
        "Whisper transcription completed: duration=%.1fs, whisper_time=%dms, text_length=%d",
        audio_duration or 0, whisper_ms, len(response.text),
    )
    return response.text, audio_duration


async def process_audio_stream(
    audio_bytes: bytes,
    filename: str,
    language: str | None = None,
    context_text: str | None = None,
    context_image_base64: str | None = None,
    context_image_media_type: str = "image/png",
    reasoning_effort: str | None = None,
    vocabulary_prompt: str | None = None,
) -> AsyncGenerator[str, None]:
    """Transcribe audio, then stream GPT result as SSE events.

    NOTE: all awaits before first yield run eagerly so errors surface
    before the HTTP 200 response starts.
    """
    start = time.monotonic()
    mode = "image" if context_image_base64 else ("text" if context_text else "dictation")
    logger.info(
        "process_audio_stream starting: mode=%s, filename=%s, reasoning_effort=%s",
        mode, filename, reasoning_effort,
    )

    transcription, duration = await transcribe_audio(audio_bytes, filename, language, vocabulary_prompt)

    messages = _build_messages(transcription, context_text, context_image_base64, context_image_media_type)

    extra_kwargs = {}
    if reasoning_effort:
        extra_kwargs["reasoning_effort"] = reasoning_effort

    logger.info(
        "GPT streaming request starting: model=%s, max_tokens=%s",
        settings.gpt_model, settings.gpt_max_tokens,
    )
    gpt_start = time.monotonic()
    stream = await client.chat.completions.create(
        model=settings.gpt_model,
        messages=messages,
        max_completion_tokens=settings.gpt_max_tokens,
        stream=True,
        stream_options={"include_usage": True},
        **extra_kwargs,
    )

    # --- Everything above runs eagerly (before first yield) ---

    full_result = []
    input_tokens = 0
    output_tokens = 0

    async for chunk in stream:
        if chunk.usage:
            input_tokens = chunk.usage.prompt_tokens
            output_tokens = chunk.usage.completion_tokens

        if chunk.choices:
            delta = chunk.choices[0].delta
            if delta.content:
                full_result.append(delta.content)
                yield f"data: {delta.content}\n\n"

    gpt_ms = int((time.monotonic() - gpt_start) * 1000)
    elapsed_ms = int((time.monotonic() - start) * 1000)

    logger.info(
        "GPT streaming completed: gpt_time=%dms, input_tokens=%d, output_tokens=%d, result_length=%d",
        gpt_ms, input_tokens, output_tokens, len("".join(full_result)),
    )
    logger.info(
        "process_audio_stream finished: total_time=%dms, audio_duration=%.1fs",
        elapsed_ms, duration or 0,
    )

    meta = json.dumps({
        "event": "metadata",
        "transcription": transcription,
        "result": "".join(full_result),
        "audio_duration_seconds": duration,
        "processing_time_ms": elapsed_ms,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
    })
    yield f"data: {meta}\n\n"
    yield "data: [DONE]\n\n"


async def process_audio(
    audio_bytes: bytes,
    filename: str,
    language: str | None = None,
    context_text: str | None = None,
    context_image_base64: str | None = None,
    context_image_media_type: str = "image/png",
    reasoning_effort: str | None = None,
    vocabulary_prompt: str | None = None,
) -> dict:
    start = time.monotonic()
    mode = "image" if context_image_base64 else ("text" if context_text else "dictation")
    logger.info(
        "process_audio starting: mode=%s, filename=%s, reasoning_effort=%s",
        mode, filename, reasoning_effort,
    )

    transcription, duration = await transcribe_audio(audio_bytes, filename, language, vocabulary_prompt)

    messages = _build_messages(transcription, context_text, context_image_base64, context_image_media_type)

    extra_kwargs = {}
    if reasoning_effort:
        extra_kwargs["reasoning_effort"] = reasoning_effort

    logger.info(
        "GPT completion request starting: model=%s, max_tokens=%s",
        settings.gpt_model, settings.gpt_max_tokens,
    )
    gpt_start = time.monotonic()
    try:
        response = await client.chat.completions.create(
            model=settings.gpt_model,
            messages=messages,
            max_completion_tokens=settings.gpt_max_tokens,
            **extra_kwargs,
        )
    except Exception:
        logger.error("GPT completion failed: model=%s", settings.gpt_model, exc_info=True)
        raise
    gpt_ms = int((time.monotonic() - gpt_start) * 1000)
    if not response.choices:
        logger.error("GPT returned empty choices: model=%s", settings.gpt_model)
        raise ValueError("OpenAI returned empty choices")
    choice = response.choices[0]
    elapsed_ms = int((time.monotonic() - start) * 1000)

    logger.info(
        "GPT completion finished: gpt_time=%dms, input_tokens=%d, output_tokens=%d",
        gpt_ms, response.usage.prompt_tokens, response.usage.completion_tokens,
    )
    logger.info(
        "process_audio finished: total_time=%dms, audio_duration=%.1fs",
        elapsed_ms, duration or 0,
    )

    return {
        "transcription": transcription,
        "result": (choice.message.content or "").strip(),
        "audio_duration_seconds": duration,
        "processing_time_ms": elapsed_ms,
        "input_tokens": response.usage.prompt_tokens,
        "output_tokens": response.usage.completion_tokens,
    }
