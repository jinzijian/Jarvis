"""Setup endpoints for first-run configuration.

Allows the client to:
- Check current configuration status (API key set, Composio configured, etc.)
- Validate and save an OpenAI API key
- Get/set the GPT model
"""

import logging
import os
from pathlib import Path

from fastapi import APIRouter, HTTPException
from openai import AsyncOpenAI
from pydantic import BaseModel

from app.config import settings

logger = logging.getLogger(__name__)
router = APIRouter()

ENV_FILE_PATH = Path(__file__).resolve().parent.parent.parent / ".env"


class SetupStatusResponse(BaseModel):
    openai_api_key_set: bool
    openai_api_key_valid: bool | None = None  # None = not yet checked
    openai_api_key_preview: str | None = None  # e.g. "sk-...abc"
    gpt_model: str
    whisper_model: str
    composio_api_key_set: bool
    backend_version: str


class ValidateKeyRequest(BaseModel):
    api_key: str


class ValidateKeyResponse(BaseModel):
    valid: bool
    message: str
    models: list[str] | None = None


class SaveKeyRequest(BaseModel):
    api_key: str


class SaveModelRequest(BaseModel):
    model: str


def _key_preview(key: str) -> str:
    """Show first 3 and last 4 chars of an API key."""
    if len(key) <= 10:
        return "***"
    return f"{key[:7]}...{key[-4:]}"


def _read_env_lines() -> list[str]:
    if ENV_FILE_PATH.exists():
        return ENV_FILE_PATH.read_text().splitlines()
    return []


def _write_env(key: str, value: str):
    """Write or update a key=value in the .env file."""
    lines = _read_env_lines()
    found = False
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(f"{key}=") or stripped.startswith(f"# {key}="):
            new_lines.append(f"{key}={value}")
            found = True
        else:
            new_lines.append(line)
    if not found:
        new_lines.append(f"{key}={value}")
    ENV_FILE_PATH.write_text("\n".join(new_lines) + "\n")


@router.get("/status", response_model=SetupStatusResponse)
async def get_setup_status():
    """Check current configuration status."""
    api_key = settings.openai_api_key
    has_key = bool(api_key and api_key != "sk-..." and not api_key.startswith("sk-..."))

    return SetupStatusResponse(
        openai_api_key_set=has_key,
        openai_api_key_preview=_key_preview(api_key) if has_key else None,
        gpt_model=settings.gpt_model,
        whisper_model=settings.whisper_model,
        composio_api_key_set=bool(settings.composio_api_key),
        backend_version=settings.app_version,
    )


@router.post("/validate-key", response_model=ValidateKeyResponse)
async def validate_openai_key(body: ValidateKeyRequest):
    """Validate an OpenAI API key by making a test API call."""
    key = body.api_key.strip()
    if not key:
        raise HTTPException(status_code=400, detail="API key is empty.")

    try:
        test_client = AsyncOpenAI(api_key=key, timeout=15.0)
        models_response = await test_client.models.list()
        model_ids = [m.id for m in models_response.data[:20]]
        await test_client.close()
        return ValidateKeyResponse(
            valid=True,
            message="API key is valid.",
            models=sorted(model_ids),
        )
    except Exception as e:
        error_msg = str(e)
        if "401" in error_msg or "invalid" in error_msg.lower():
            return ValidateKeyResponse(valid=False, message="Invalid API key. Please check and try again.")
        if "429" in error_msg:
            return ValidateKeyResponse(valid=False, message="Rate limited. The key may be valid but has hit its quota.")
        return ValidateKeyResponse(valid=False, message=f"Could not validate: {error_msg[:200]}")


@router.post("/save-key")
async def save_openai_key(body: SaveKeyRequest):
    """Save the OpenAI API key to .env and reload settings."""
    key = body.api_key.strip()
    if not key:
        raise HTTPException(status_code=400, detail="API key is empty.")

    _write_env("OPENAI_API_KEY", key)

    # Update the running settings object
    settings.openai_api_key = key

    # Also update the global OpenAI client
    from app.services.openai_service import client
    client.api_key = key

    logger.info("OpenAI API key saved and applied: %s", _key_preview(key))
    return {"ok": True, "preview": _key_preview(key)}


@router.post("/save-model")
async def save_model(body: SaveModelRequest):
    """Save the GPT model to .env and reload settings."""
    model = body.model.strip()
    if not model:
        raise HTTPException(status_code=400, detail="Model name is empty.")

    _write_env("GPT_MODEL", model)
    settings.gpt_model = model

    logger.info("GPT model saved: %s", model)
    return {"ok": True, "model": model}
