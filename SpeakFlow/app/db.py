"""Local SQLite database for history, vocabulary, and usage tracking."""

import logging
from pathlib import Path

import aiosqlite

from app.config import settings

logger = logging.getLogger(__name__)

_db: aiosqlite.Connection | None = None

SCHEMA = """
CREATE TABLE IF NOT EXISTS processing_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    transcription TEXT NOT NULL,
    result TEXT NOT NULL,
    audio_duration_seconds REAL,
    processing_time_ms INTEGER,
    whisper_model TEXT,
    gpt_model TEXT,
    input_token_count INTEGER,
    output_token_count INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user_vocabulary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    correct TEXT NOT NULL,
    wrong TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 1,
    last_used TEXT NOT NULL,
    UNIQUE(correct, wrong)
);

CREATE TABLE IF NOT EXISTS usage_daily (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL UNIQUE,
    api_calls_count INTEGER NOT NULL DEFAULT 0,
    audio_seconds_total REAL NOT NULL DEFAULT 0,
    input_tokens_total INTEGER NOT NULL DEFAULT 0,
    output_tokens_total INTEGER NOT NULL DEFAULT 0
);
"""


async def init_db():
    global _db
    data_dir = Path(settings.data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)
    db_path = data_dir / "speakflow.db"
    _db = await aiosqlite.connect(str(db_path))
    _db.row_factory = aiosqlite.Row
    await _db.executescript(SCHEMA)
    await _db.commit()
    logger.info("SQLite database initialized at %s", db_path)


async def get_db() -> aiosqlite.Connection:
    if _db is None:
        await init_db()
    return _db


async def close_db():
    global _db
    if _db:
        await _db.close()
        _db = None
