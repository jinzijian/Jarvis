import logging

from fastapi import HTTPException, UploadFile

from app.config import settings

logger = logging.getLogger(__name__)

ALLOWED_EXTENSIONS = set(settings.allowed_audio_formats)
MAX_SIZE_BYTES = settings.max_audio_size_mb * 1024 * 1024
READ_CHUNK_BYTES = 1024 * 1024


def get_extension(filename: str) -> str:
    if not filename or "." not in filename:
        return ""
    return filename.rsplit(".", 1)[-1].lower()


async def validate_audio(file: UploadFile) -> bytes:
    ext = get_extension(file.filename or "")
    logger.info("validate_audio: filename=%s extension=%s content_type=%s", file.filename, ext, file.content_type)
    if ext not in ALLOWED_EXTENSIONS:
        logger.warning("validate_audio: unsupported format '%s' for file=%s", ext, file.filename)
        raise HTTPException(
            status_code=415,
            detail=f"Unsupported audio format '{ext}'. Accepted: {', '.join(sorted(ALLOWED_EXTENSIONS))}",
        )

    chunks: list[bytes] = []
    total_size = 0
    while True:
        chunk = await file.read(READ_CHUNK_BYTES)
        if not chunk:
            break
        total_size += len(chunk)
        if total_size > MAX_SIZE_BYTES:
            logger.warning("validate_audio: file exceeds size limit (%d bytes > %d bytes) file=%s",
                           total_size, MAX_SIZE_BYTES, file.filename)
            raise HTTPException(
                status_code=413,
                detail=f"Audio file exceeds {settings.max_audio_size_mb}MB limit.",
            )
        chunks.append(chunk)

    if total_size == 0:
        logger.warning("validate_audio: empty file received file=%s", file.filename)
        raise HTTPException(
            status_code=400,
            detail="Audio file is empty.",
        )

    logger.info("validate_audio: valid file=%s size=%d bytes", file.filename, total_size)
    return b"".join(chunks)
