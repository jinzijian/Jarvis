import logging
from datetime import datetime, timezone

from fastapi import APIRouter

from app.config import settings
from app.db import get_db

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/health")
async def health_check():
    checks = {}
    try:
        db = await get_db()
        await db.execute_fetchall("SELECT 1")
        checks["database"] = "ok"
    except Exception as exc:
        logger.warning("Health check: database unreachable: %s", exc)
        checks["database"] = "unreachable"

    overall = "healthy" if all(v == "ok" for v in checks.values()) else "degraded"
    return {
        "status": overall,
        "version": settings.app_version,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "checks": checks,
    }
