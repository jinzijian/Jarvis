"""Memory API endpoints for managing persistent agent memory."""

import logging

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.services.memory_service import (
    deactivate_memory,
    get_active_memories,
    save_memory,
    search_memories,
    update_memory,
)

logger = logging.getLogger(__name__)
router = APIRouter()


class MemoryCreateRequest(BaseModel):
    content: str
    type: str = "general"  # user, feedback, project, reference, general
    source: str = "user"


class MemoryUpdateRequest(BaseModel):
    content: str


class MemorySearchRequest(BaseModel):
    query: str
    limit: int = 10


@router.get("")
async def list_memories(type: str | None = None, limit: int = 20):
    return await get_active_memories(memory_type=type, limit=limit)


@router.post("")
async def create_memory(req: MemoryCreateRequest):
    if not req.content.strip():
        raise HTTPException(status_code=400, detail="Memory content cannot be empty.")
    memory_id = await save_memory(
        content=req.content.strip(),
        memory_type=req.type,
        source=req.source,
    )
    return {"id": memory_id, "status": "created"}


@router.put("/{memory_id}")
async def update_memory_endpoint(memory_id: int, req: MemoryUpdateRequest):
    if not req.content.strip():
        raise HTTPException(status_code=400, detail="Memory content cannot be empty.")
    ok = await update_memory(memory_id, req.content.strip())
    if not ok:
        raise HTTPException(status_code=404, detail="Memory not found.")
    return {"id": memory_id, "status": "updated"}


@router.delete("/{memory_id}")
async def delete_memory(memory_id: int):
    ok = await deactivate_memory(memory_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Memory not found.")
    return {"id": memory_id, "status": "deleted"}


@router.post("/search")
async def search_memories_endpoint(req: MemorySearchRequest):
    return await search_memories(req.query, limit=req.limit)
