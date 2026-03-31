from fastapi import Request
from fastapi.responses import JSONResponse
from openai import APIError, APIConnectionError, RateLimitError


async def openai_exception_handler(request: Request, exc: APIError):
    if isinstance(exc, RateLimitError):
        return JSONResponse(
            status_code=503,
            content={"detail": "AI service temporarily unavailable. Please try again shortly."},
        )
    if isinstance(exc, APIConnectionError):
        return JSONResponse(
            status_code=503,
            content={"detail": "Unable to connect to AI service."},
        )
    return JSONResponse(
        status_code=502,
        content={"detail": "AI processing failed. Please try again."},
    )
