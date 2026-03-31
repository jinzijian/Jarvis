import logging

from fastapi import APIRouter

from app.services.usage_service import get_today_usage, get_total_usage

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/usage")
async def usage_stats():
    today = await get_today_usage()
    total = await get_total_usage()
    return {
        "today": {
            "api_calls": today["api_calls_count"],
            "audio_seconds": today["audio_seconds_total"],
            "input_tokens": today["input_tokens_total"],
            "output_tokens": today["output_tokens_total"],
        },
        "total": {
            "api_calls": total["api_calls_count"],
            "audio_seconds": total["audio_seconds_total"],
            "input_tokens": total["input_tokens_total"],
            "output_tokens": total["output_tokens_total"],
        },
    }
