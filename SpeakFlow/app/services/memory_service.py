"""Persistent memory system inspired by Claude Code's file-based memory.

Stores user preferences, feedback, and context across sessions in SQLite.
Memory types mirror Claude Code's taxonomy:
- user:      User role, preferences, habits
- feedback:  Interaction corrections and confirmations
- project:   Ongoing work context
- reference: Pointers to external resources
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

from app.db import get_db

logger = logging.getLogger(__name__)

MEMORY_SCHEMA = """
CREATE TABLE IF NOT EXISTS agent_memory (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL DEFAULT 'general',
    content TEXT NOT NULL,
    source TEXT DEFAULT 'auto',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP DEFAULT NULL,
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_memory_type ON agent_memory(type);
CREATE INDEX IF NOT EXISTS idx_memory_active ON agent_memory(is_active);
"""


async def init_memory_table():
    """Create the memory table if it doesn't exist."""
    db = await get_db()
    await db.executescript(MEMORY_SCHEMA)
    await db.commit()


async def save_memory(
    content: str,
    memory_type: str = "general",
    source: str = "auto",
) -> int:
    """Save a new memory entry. Returns the memory ID."""
    db = await get_db()
    now = datetime.now(timezone.utc).isoformat()
    cursor = await db.execute(
        """INSERT INTO agent_memory (type, content, source, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?)""",
        (memory_type, content, source, now, now),
    )
    await db.commit()
    memory_id = cursor.lastrowid
    logger.info("Memory saved: id=%d type=%s source=%s", memory_id, memory_type, source)
    return memory_id


async def get_active_memories(
    memory_type: str | None = None,
    limit: int = 20,
) -> list[dict[str, Any]]:
    """Retrieve active memories, optionally filtered by type."""
    db = await get_db()
    if memory_type:
        cursor = await db.execute(
            """SELECT id, type, content, source, created_at, updated_at
               FROM agent_memory
               WHERE is_active = 1 AND type = ?
               ORDER BY updated_at DESC LIMIT ?""",
            (memory_type, limit),
        )
    else:
        cursor = await db.execute(
            """SELECT id, type, content, source, created_at, updated_at
               FROM agent_memory
               WHERE is_active = 1
               ORDER BY updated_at DESC LIMIT ?""",
            (limit,),
        )
    rows = await cursor.fetchall()
    return [
        {
            "id": row["id"],
            "type": row["type"],
            "content": row["content"],
            "source": row["source"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }
        for row in rows
    ]


async def update_memory(memory_id: int, content: str) -> bool:
    """Update an existing memory's content."""
    db = await get_db()
    now = datetime.now(timezone.utc).isoformat()
    cursor = await db.execute(
        """UPDATE agent_memory SET content = ?, updated_at = ? WHERE id = ? AND is_active = 1""",
        (content, now, memory_id),
    )
    await db.commit()
    return cursor.rowcount > 0


async def deactivate_memory(memory_id: int) -> bool:
    """Soft-delete a memory by marking it inactive."""
    db = await get_db()
    cursor = await db.execute(
        """UPDATE agent_memory SET is_active = 0 WHERE id = ?""",
        (memory_id,),
    )
    await db.commit()
    return cursor.rowcount > 0


async def search_memories(query: str, limit: int = 10) -> list[dict[str, Any]]:
    """Simple text search across active memories."""
    db = await get_db()
    cursor = await db.execute(
        """SELECT id, type, content, source, created_at, updated_at
           FROM agent_memory
           WHERE is_active = 1 AND content LIKE ?
           ORDER BY updated_at DESC LIMIT ?""",
        (f"%{query}%", limit),
    )
    rows = await cursor.fetchall()
    return [
        {
            "id": row["id"],
            "type": row["type"],
            "content": row["content"],
            "source": row["source"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }
        for row in rows
    ]
