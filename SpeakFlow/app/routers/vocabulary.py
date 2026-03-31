import json
import logging

from fastapi import APIRouter, HTTPException
from openai import AsyncOpenAI
from pydantic import BaseModel

from app.config import settings
from app.db import get_db
from app.services.vocabulary_service import get_user_vocabulary, upsert_vocabulary_entries

logger = logging.getLogger(__name__)
router = APIRouter()

client = AsyncOpenAI(api_key=settings.openai_api_key, timeout=120.0)
MAX_CANDIDATES_PER_BATCH = 100
MAX_VOCAB_TEXT_LENGTH = 500
MAX_CONTEXT_LENGTH = 4000

VOCABULARY_JUDGE_PROMPT = """以下是用户语音转写后修改的记录。请判断哪些是"语音识别错误纠正"，哪些不是。

只提取符合以下条件的：
- 语音识别把某个词/短语听错了，用户修正为正确的
- 专有名词、人名、产品名、术语等 Whisper 容易听错的

排除以下情况：
- 用户执行了指令（翻译、改写、润色等），输出和输入本来就应该不同
- 用户追加/删除了大段内容（不是纠正，是编辑）
- 标点符号调整
- 无法确定是纠正还是有意改写的

请严格返回如下格式的 JSON（必须是数组，即使只有一项）：
{"corrections": [{"correct": "正确词", "wrong": "错误词"}, ...]}
如果没有符合条件的，返回 {"corrections": []}。
只返回 JSON，不要其他文字。"""


class CandidateItem(BaseModel):
    original: str
    edited: str
    source: str
    fullContext: str | None = None
    timestamp: str


class CandidatesRequest(BaseModel):
    candidates: list[CandidateItem]


class ConfirmedEntry(BaseModel):
    correct: str
    wrong: str


class VocabularyResponse(BaseModel):
    confirmed: list[ConfirmedEntry]


class VocabularyListEntry(BaseModel):
    correct: str
    wrong: str
    count: int
    last_used: str


class VocabularyListResponse(BaseModel):
    entries: list[VocabularyListEntry]
    prompt: str | None = None


@router.get("/vocabulary", response_model=VocabularyListResponse)
async def get_vocabulary():
    entries = await get_user_vocabulary()
    prompt_parts = []
    total_length = 0
    for entry in entries:
        part = entry["correct"]
        if total_length + len(part) + 2 > 800:
            break
        prompt_parts.append(part)
        total_length += len(part) + 2
    return VocabularyListResponse(
        entries=[VocabularyListEntry(**e) for e in entries],
        prompt=", ".join(prompt_parts) if prompt_parts else None,
    )


class VocabularyAddRequest(BaseModel):
    correct: str
    wrong: str


@router.post("/vocabulary", response_model=VocabularyListEntry)
async def add_vocabulary_entry(request: VocabularyAddRequest):
    if (
        len(request.correct.strip()) == 0
        or len(request.wrong.strip()) == 0
        or len(request.correct) > MAX_VOCAB_TEXT_LENGTH
        or len(request.wrong) > MAX_VOCAB_TEXT_LENGTH
    ):
        raise HTTPException(status_code=400, detail="Invalid vocabulary entry.")
    entries = await upsert_vocabulary_entries(
        [{"correct": request.correct, "wrong": request.wrong}],
    )
    if entries:
        e = entries[0]
        return VocabularyListEntry(
            correct=e["correct"], wrong=e["wrong"],
            count=e["count"], last_used=e["last_used"],
        )
    raise HTTPException(status_code=500, detail="Failed to add entry")


@router.delete("/vocabulary/{correct}/{wrong}")
async def delete_vocabulary_entry(correct: str, wrong: str):
    db = await get_db()
    cursor = await db.execute(
        "DELETE FROM user_vocabulary WHERE correct = ? AND wrong = ?",
        (correct, wrong),
    )
    await db.commit()
    if cursor.rowcount > 0:
        return {"deleted": True}
    raise HTTPException(status_code=404, detail="Entry not found")


@router.post("/vocabulary/process", response_model=VocabularyResponse)
async def process_vocabulary(request: CandidatesRequest):
    logger.info("vocabulary/process: candidates=%d", len(request.candidates))

    if not request.candidates:
        return VocabularyResponse(confirmed=[])
    if len(request.candidates) > MAX_CANDIDATES_PER_BATCH:
        raise HTTPException(status_code=400, detail="Too many vocabulary candidates.")

    for candidate in request.candidates:
        if (
            not candidate.original.strip()
            or not candidate.edited.strip()
            or len(candidate.original) > MAX_VOCAB_TEXT_LENGTH
            or len(candidate.edited) > MAX_VOCAB_TEXT_LENGTH
        ):
            raise HTTPException(status_code=400, detail="Invalid vocabulary candidate.")

    candidates_text = "\n".join(
        f"- 原文: \"{c.original}\" → 修改为: \"{c.edited}\" (来源: {c.source})"
        for c in request.candidates
    )

    response = await client.chat.completions.create(
        model=settings.gpt_model,
        messages=[
            {"role": "system", "content": VOCABULARY_JUDGE_PROMPT},
            {"role": "user", "content": candidates_text},
        ],
        max_completion_tokens=2000,
        response_format={"type": "json_object"},
    )

    if not response.choices or not response.choices[0].message.content:
        return VocabularyResponse(confirmed=[])
    content = response.choices[0].message.content.strip()

    try:
        parsed = json.loads(content)
        if isinstance(parsed, list):
            entries = parsed
        elif isinstance(parsed, dict):
            if "correct" in parsed and "wrong" in parsed:
                entries = [parsed]
            else:
                for key in ("entries", "confirmed", "result", "corrections"):
                    if key in parsed and isinstance(parsed[key], list):
                        entries = parsed[key]
                        break
                else:
                    entries = []
        else:
            entries = []

        confirmed = [
            ConfirmedEntry(correct=e["correct"][:MAX_VOCAB_TEXT_LENGTH], wrong=e["wrong"][:MAX_VOCAB_TEXT_LENGTH])
            for e in entries
            if isinstance(e, dict)
            and "correct" in e and "wrong" in e
            and isinstance(e["correct"], str) and isinstance(e["wrong"], str)
            and e["correct"].strip() and e["wrong"].strip()
        ]
    except (json.JSONDecodeError, KeyError) as exc:
        logger.error("Failed to parse vocabulary LLM response: %s", exc)
        confirmed = []

    if confirmed:
        await upsert_vocabulary_entries(
            [{"correct": e.correct, "wrong": e.wrong} for e in confirmed],
        )

    logger.info("vocabulary/process: confirmed %d entries", len(confirmed))
    return VocabularyResponse(confirmed=confirmed)
