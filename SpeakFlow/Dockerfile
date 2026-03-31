FROM python:3.13-slim

WORKDIR /app

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Copy dependency files
COPY pyproject.toml .

# Install dependencies
RUN uv pip install --system --no-cache -r pyproject.toml

# Copy application code
COPY app/ app/

CMD uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}
