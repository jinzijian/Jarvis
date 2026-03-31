import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from openai import APIError

from app.config import settings
from app.db import close_db, init_db
from app.routers import agent, composio, health, history, memory, process, usage, vocabulary
from app.utils.exceptions import openai_exception_handler

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    from app.services.memory_service import init_memory_table
    await init_memory_table()
    yield
    await close_db()


app = FastAPI(
    title="SpeakFlow API",
    description="Voice input method backend - Speech to text with AI processing",
    version=settings.app_version,
    lifespan=lifespan,
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Exception handlers
app.add_exception_handler(APIError, openai_exception_handler)


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error("Unhandled exception on %s %s: %s", request.method, request.url.path, exc, exc_info=True)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})


# Routers
app.include_router(health.router, tags=["Health"])
app.include_router(process.router, prefix="/api/v1", tags=["Processing"])
app.include_router(history.router, prefix="/api/v1", tags=["History"])
app.include_router(usage.router, prefix="/api/v1", tags=["Usage"])
app.include_router(vocabulary.router, prefix="/api/v1", tags=["Vocabulary"])
app.include_router(agent.router, prefix="/api/v1/agent", tags=["Agent"])
app.include_router(composio.router, prefix="/api/v1/composio", tags=["Composio"])
app.include_router(memory.router, prefix="/api/v1/memory", tags=["Memory"])
