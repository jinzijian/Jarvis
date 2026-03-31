import logging

from fastapi import APIRouter, HTTPException, Query

from app.services.history_service import delete_history_item, get_history_item, get_history_list

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/history")
async def list_history(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
):
    return await get_history_list(page, per_page)


@router.get("/history/{item_id}")
async def get_single_history(item_id: int):
    item = await get_history_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="History item not found")
    return item


@router.delete("/history/{item_id}", status_code=204)
async def remove_history(item_id: int):
    deleted = await delete_history_item(item_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="History item not found")
