import logging
import math

from app.db import get_db

logger = logging.getLogger(__name__)


async def create_history_record(
    transcription: str,
    result: str,
    audio_duration_seconds: float | None,
    processing_time_ms: int,
    whisper_model: str,
    gpt_model: str,
    input_token_count: int,
    output_token_count: int,
    **_kwargs,
) -> dict:
    db = await get_db()
    cursor = await db.execute(
        """INSERT INTO processing_history
           (transcription, result, audio_duration_seconds, processing_time_ms,
            whisper_model, gpt_model, input_token_count, output_token_count)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (transcription, result, audio_duration_seconds, processing_time_ms,
         whisper_model, gpt_model, input_token_count, output_token_count),
    )
    await db.commit()
    logger.info("History record created: id=%s", cursor.lastrowid)
    row = await db.execute_fetchall(
        "SELECT * FROM processing_history WHERE id = ?", (cursor.lastrowid,)
    )
    if row:
        return dict(row[0])
    return {"id": cursor.lastrowid, "created_at": None}


async def get_history_list(page: int = 1, per_page: int = 20, **_kwargs) -> dict:
    db = await get_db()
    offset = (page - 1) * per_page

    count_row = await db.execute_fetchall("SELECT COUNT(*) as cnt FROM processing_history")
    total = count_row[0]["cnt"] if count_row else 0

    rows = await db.execute_fetchall(
        "SELECT * FROM processing_history ORDER BY created_at DESC LIMIT ? OFFSET ?",
        (per_page, offset),
    )
    return {
        "items": [dict(r) for r in rows],
        "total": total,
        "page": page,
        "per_page": per_page,
        "pages": math.ceil(total / per_page) if total else 0,
    }


async def get_history_item(item_id: int, **_kwargs) -> dict | None:
    db = await get_db()
    rows = await db.execute_fetchall(
        "SELECT * FROM processing_history WHERE id = ?", (item_id,)
    )
    return dict(rows[0]) if rows else None


async def delete_history_item(item_id: int, **_kwargs) -> bool:
    db = await get_db()
    cursor = await db.execute(
        "DELETE FROM processing_history WHERE id = ?", (item_id,)
    )
    await db.commit()
    return cursor.rowcount > 0
