import logging
from datetime import date

from app.db import get_db

logger = logging.getLogger(__name__)


async def increment_usage(
    audio_seconds: float | None = 0,
    input_tokens: int = 0,
    output_tokens: int = 0,
    **_kwargs,
):
    today = str(date.today())
    db = await get_db()
    await db.execute(
        """INSERT INTO usage_daily (date, api_calls_count, audio_seconds_total, input_tokens_total, output_tokens_total)
           VALUES (?, 1, ?, ?, ?)
           ON CONFLICT(date) DO UPDATE SET
               api_calls_count = api_calls_count + 1,
               audio_seconds_total = audio_seconds_total + excluded.audio_seconds_total,
               input_tokens_total = input_tokens_total + excluded.input_tokens_total,
               output_tokens_total = output_tokens_total + excluded.output_tokens_total""",
        (today, audio_seconds or 0, input_tokens, output_tokens),
    )
    await db.commit()


async def get_today_usage(**_kwargs) -> dict:
    today = str(date.today())
    db = await get_db()
    rows = await db.execute_fetchall(
        "SELECT * FROM usage_daily WHERE date = ?", (today,)
    )
    if rows:
        r = dict(rows[0])
        return {
            "api_calls_count": r["api_calls_count"],
            "audio_seconds_total": r["audio_seconds_total"],
            "input_tokens_total": r["input_tokens_total"],
            "output_tokens_total": r["output_tokens_total"],
        }
    return {"api_calls_count": 0, "audio_seconds_total": 0, "input_tokens_total": 0, "output_tokens_total": 0}


async def get_total_usage(**_kwargs) -> dict:
    db = await get_db()
    rows = await db.execute_fetchall(
        """SELECT
               COALESCE(SUM(api_calls_count), 0) as api_calls_count,
               COALESCE(SUM(audio_seconds_total), 0) as audio_seconds_total,
               COALESCE(SUM(input_tokens_total), 0) as input_tokens_total,
               COALESCE(SUM(output_tokens_total), 0) as output_tokens_total
           FROM usage_daily"""
    )
    if rows:
        return dict(rows[0])
    return {"api_calls_count": 0, "audio_seconds_total": 0, "input_tokens_total": 0, "output_tokens_total": 0}
