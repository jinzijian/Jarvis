from typing import Literal

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # App
    app_name: str = "SpeakFlow"
    app_version: str = "0.1.0"

    # OpenAI
    openai_api_key: str = ""
    whisper_model: str = "whisper-1"
    gpt_model: str = "gpt-5.4"
    gpt_max_tokens: int = 4096
    gpt_prompt_cache_retention: Literal["in-memory", "24h"] = "24h"

    # Composio (optional)
    composio_api_key: str = ""

    # CORS
    cors_origins: list[str] = ["*"]

    # Audio
    max_audio_size_mb: int = 25
    allowed_audio_formats: list[str] = [
        "mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm", "ogg", "flac",
    ]

    # Data directory for SQLite
    data_dir: str = "./data"

    model_config = {
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "case_sensitive": False,
    }


settings = Settings()
