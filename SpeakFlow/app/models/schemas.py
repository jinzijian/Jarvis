from datetime import datetime

from pydantic import BaseModel


# --- Processing ---
class ProcessResponse(BaseModel):
    id: int | None = None
    transcription: str
    result: str
    processing_time_ms: int
    audio_duration_seconds: float | None = None
    created_at: datetime | str | None = None


# --- History ---
class HistoryItem(BaseModel):
    id: int
    transcription: str
    result: str
    audio_duration_seconds: float | None = None
    created_at: str


class PaginatedHistory(BaseModel):
    items: list[HistoryItem]
    total: int
    page: int
    per_page: int
    pages: int


# --- Usage ---
class UsagePeriod(BaseModel):
    api_calls: int = 0
    audio_seconds: float = 0
    input_tokens: int = 0
    output_tokens: int = 0


class UsageStatsResponse(BaseModel):
    today: UsagePeriod
    total: UsagePeriod
