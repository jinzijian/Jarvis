import logging
from datetime import date

from app.db import get_db

logger = logging.getLogger(__name__)


async def get_user_vocabulary(**_kwargs) -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        "SELECT correct, wrong, count, last_used FROM user_vocabulary ORDER BY count DESC"
    )
    return [dict(r) for r in rows]


async def upsert_vocabulary_entries(entries: list[dict], **_kwargs) -> list[dict]:
    db = await get_db()
    today = str(date.today())
    results = []

    for entry in entries:
        rows = await db.execute_fetchall(
            "SELECT id, count FROM user_vocabulary WHERE correct = ? AND wrong = ?",
            (entry["correct"], entry["wrong"]),
        )
        if rows:
            existing = dict(rows[0])
            await db.execute(
                "UPDATE user_vocabulary SET count = ?, last_used = ? WHERE id = ?",
                (existing["count"] + 1, today, existing["id"]),
            )
        else:
            await db.execute(
                "INSERT INTO user_vocabulary (correct, wrong, count, last_used) VALUES (?, ?, 1, ?)",
                (entry["correct"], entry["wrong"], today),
            )

        updated = await db.execute_fetchall(
            "SELECT * FROM user_vocabulary WHERE correct = ? AND wrong = ?",
            (entry["correct"], entry["wrong"]),
        )
        if updated:
            results.append(dict(updated[0]))

    await db.commit()
    logger.info("Upserted %d vocabulary entries", len(results))
    return results
