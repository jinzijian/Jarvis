import logging
from io import BytesIO

from PIL import Image

logger = logging.getLogger(__name__)

MAX_SIDE = 2000
MAX_BYTES = 1 * 1024 * 1024  # 1MB target for GPT vision (saves tokens)
QUALITY_STEPS = [85, 75, 65, 50, 40]


def optimize_image(image_bytes: bytes, content_type: str) -> tuple[bytes, str]:
    """Compress and resize an image for GPT vision.

    Returns (optimized_bytes, media_type) where media_type is "image/jpeg" or "image/png".
    """
    img = Image.open(BytesIO(image_bytes))

    # Convert RGBA/palette to RGB for JPEG output
    if img.mode in ("RGBA", "P"):
        has_alpha = img.mode == "RGBA" or (img.mode == "P" and "transparency" in img.info)
        if has_alpha:
            # Keep as PNG if transparency matters
            if max(img.size) > MAX_SIDE:
                img.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
            buf = BytesIO()
            img.save(buf, "PNG", optimize=True)
            result = buf.getvalue()
            logger.info("Image optimized: %dx%d PNG, %d KB", img.width, img.height, len(result) // 1024)
            return result, "image/png"
        img = img.convert("RGB")
    elif img.mode != "RGB":
        img = img.convert("RGB")

    # Resize if larger than MAX_SIDE
    if max(img.size) > MAX_SIDE:
        img.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)

    # If already small enough as JPEG at high quality, return
    buf = BytesIO()
    img.save(buf, "JPEG", quality=85)
    result = buf.getvalue()

    if len(result) <= MAX_BYTES:
        logger.info("Image optimized: %dx%d JPEG q85, %d KB", img.width, img.height, len(result) // 1024)
        return result, "image/jpeg"

    # Progressive quality reduction
    for quality in QUALITY_STEPS[1:]:
        buf = BytesIO()
        img.save(buf, "JPEG", quality=quality)
        result = buf.getvalue()
        if len(result) <= MAX_BYTES:
            logger.info("Image optimized: %dx%d JPEG q%d, %d KB", img.width, img.height, quality, len(result) // 1024)
            return result, "image/jpeg"

    # Last resort: further downscale
    for scale in [0.75, 0.5]:
        scaled = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
        buf = BytesIO()
        scaled.save(buf, "JPEG", quality=50)
        result = buf.getvalue()
        if len(result) <= MAX_BYTES:
            logger.info("Image optimized: %dx%d JPEG q50 scaled, %d KB", scaled.width, scaled.height, len(result) // 1024)
            return result, "image/jpeg"

    logger.warning("Image still %d KB after all optimization attempts", len(result) // 1024)
    return result, "image/jpeg"
