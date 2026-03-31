import json
import logging
import time
from collections.abc import AsyncGenerator
from io import BytesIO

from openai import AsyncOpenAI, BadRequestError

from app.config import settings

logger = logging.getLogger(__name__)

client = AsyncOpenAI(
    api_key=settings.openai_api_key,
    timeout=120.0,  # 2 minute timeout for all requests
)

SYSTEM_PROMPT = """You are SpeakFlow, a dictation assistant. The user spoke something that was transcribed by speech-to-text.

IMPORTANT: Your DEFAULT behavior is PURE DICTATION — output the transcription as-is, only fixing obvious speech-to-text errors and punctuation. Treat everything as dictation unless there is an unmistakable, explicit processing command.

What counts as a processing command (ONLY these patterns):
- Explicit action verbs directed at text: "翻译成...", "translate to...", "rewrite this as...", "帮我润色", "改成...", "format as..."
- Summarization/composition commands: "总结一下", "summarize", "帮我写封邮件", "write an email", "回复他说...", "reply saying..."
- Generation commands: "帮我写...", "compose...", "draft...", "列一个清单", "make a list of..."
- The command must clearly ask you to produce, transform, or generate specific output

What is NOT a processing command (output as dictation):
- Questions ("为什么会这样", "what happened yesterday", "之前怎么回事")
- Opinions ("我觉得这个方案不错")
- Statements ("今天天气很好")
- Narration ("然后他就走了")
- Thinking aloud ("我在想要不要换个方法")
- ANY content that is not explicitly asking you to transform/translate/rewrite text

When a processing command IS detected:
1. Separate CONTENT from INSTRUCTION. Apply the instruction to the content only.
2. Return ONLY the processed result. Never include the instruction itself.
   - "试一下新的方法 帮我把这句话翻译成英语" → "Try the new method."
   - "translate this to French 今天天气很好" → "Il fait beau aujourd'hui."
   - "帮我润色一下 我今天去了公园玩了一会儿" → polished version of the content only.

When in doubt, DEFAULT TO DICTATION. It is far better to output the raw transcription than to incorrectly interpret dictation as a command."""

CONTEXT_TEXT_PROMPT = """You are SpeakFlow, an intelligent voice assistant. The user has selected some text in their application, then spoke a voice command telling you what to do with it.

Your job is to execute the user's voice command on the selected text and return ONLY the processed result.

Rules:
1. The user's voice command tells you what to do: translate, rewrite, summarize, change tone, fix grammar, explain, expand, shorten, format, etc.
2. Apply the command to the selected text and return ONLY the final result.
3. If the command is "translate to X", translate the entire selected text to language X.
4. Do NOT include explanations, labels, or the original command in your output.
5. Do NOT wrap output in quotes or markdown formatting unless the user explicitly asked for it.
6. If the command is unclear, make your best interpretation and execute it.
7. The selected text and command may be in any language. Respect the target language of the command."""

CONTEXT_IMAGE_PROMPT = """You are SpeakFlow, an intelligent voice assistant with full visual perception of the user's screen. The user has captured a screenshot (either a selected region or their entire screen), then spoke something.

Your job is to deeply perceive and understand everything visible on screen, then process the user's speech using that visual context.

The user's speech may be:
A) Pure instruction about the screen — "fix this error", "translate that", "what's wrong here" → Execute the instruction using screen context and return the result.
B) Dictation/content informed by screen context — "give him a reply saying I'm free tomorrow" (where "him" refers to a person visible in a chat) → Produce the dictated content, using the screen to resolve references.
C) Mixed: content + instruction — "帮我用英文回复说明天有空" (the screen shows an email) → Separate content from instruction, execute the instruction on the content with screen context, return only the processed result.
D) Pure dictation unrelated to screen — The user simply dictates text while their screen happens to be captured → Return the transcription as-is, fixing only speech-to-text errors.

Rules:
1. PERCEIVE the screen thoroughly: read all visible text, understand UI layout, recognize application context (browser, IDE, terminal, document, chat, email, etc.), note any data, code, error messages, notifications, or relevant visual elements.
2. UNDERSTAND intent by combining visual context with speech. The user often refers to screen content implicitly — "this", "that", "here", "him", "the error" — infer what these refer to from the screenshot.
3. Distinguish between CONTENT (what the user wants as output) and INSTRUCTIONS (how to process it). Instructions must NEVER appear in the output. Screen context helps you understand both but is also never included verbatim unless requested.
4. Return ONLY the final result. No preamble like "Based on the screenshot..." or "I can see that...". Just output the answer, text, code, translation, or whatever is needed.
5. If the user's speech is vague (e.g., just "帮我" or "help"), use the screen context to determine the most helpful action.
6. The speech may be in any language. Respond in the language appropriate for the content and intent."""


def _build_messages(
    transcription: str,
    context_text: str | None = None,
    context_image_base64: str | None = None,
    context_image_media_type: str = "image/png",
) -> list[dict]:
    """Build GPT messages based on the input mode."""
    if context_image_base64:
        return [
            {"role": "system", "content": CONTEXT_IMAGE_PROMPT},
            {"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": f"data:{context_image_media_type};base64,{context_image_base64}"}},
                {"type": "text", "text": transcription},
            ]},
        ]
    elif context_text:
        return [
            {"role": "system", "content": CONTEXT_TEXT_PROMPT},
            {"role": "user", "content": f"Selected text:\n{context_text}\n\nVoice command:\n{transcription}"},
        ]
    else:
        return [
            {"role": "system", "content": SYSTEM_PROMPT},
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
