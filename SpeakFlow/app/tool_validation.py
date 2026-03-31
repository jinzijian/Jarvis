"""Tool input validation layer inspired by Claude Code's validateInput() pattern.

Validates tool arguments AFTER schema parsing but BEFORE execution.
Each validator returns a ValidationResult with pass/fail and a message.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

MAX_TOOL_RESULT_CHARS = 50_000  # Used by result size management (Task 6)


class ValidationResult:
    def __init__(self, ok: bool, message: str = ""):
        self.ok = ok
        self.message = message

    @classmethod
    def success(cls) -> "ValidationResult":
        return cls(ok=True)

    @classmethod
    def fail(cls, message: str) -> "ValidationResult":
        return cls(ok=False, message=message)


# ---------------------------------------------------------------------------
# Validator registry: tool_name_pattern → validator function
# ---------------------------------------------------------------------------

_VALIDATORS: list[tuple[str, Any]] = []


def _register(pattern: str):
    def decorator(fn):
        _VALIDATORS.append((pattern, fn))
        return fn
    return decorator


# ---------------------------------------------------------------------------
# Email validators
# ---------------------------------------------------------------------------

@_register(r".*SEND_EMAIL.*|.*GMAIL_SEND.*|.*CREATE_DRAFT.*")
def _validate_email(tool_name: str, args: dict[str, Any]) -> ValidationResult:
    to = args.get("to") or args.get("recipient") or args.get("recipient_email") or ""
    if isinstance(to, str) and to:
        # Basic email format check
        if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", to):
            return ValidationResult.fail(
                f"Invalid email address format: '{to}'. Please provide a valid email."
            )
    subject = args.get("subject") or ""
    body = args.get("body") or args.get("message") or args.get("html_message") or ""
    if isinstance(body, str) and len(body) > 100_000:
        return ValidationResult.fail(
            "Email body is too large (>100K chars). Please reduce the content."
        )
    return ValidationResult.success()


# ---------------------------------------------------------------------------
# URL / web validators
# ---------------------------------------------------------------------------

@_register(r".*FETCH.*URL.*|.*BROWSE.*|.*OPEN_URL.*|.*WEB.*")
def _validate_url(tool_name: str, args: dict[str, Any]) -> ValidationResult:
    url = args.get("url") or args.get("link") or ""
    if isinstance(url, str) and url:
        try:
            parsed = urlparse(url)
        except Exception:
            return ValidationResult.fail(f"Invalid URL: '{url}'")
        if parsed.scheme not in ("http", "https", ""):
            return ValidationResult.fail(
                f"URL scheme '{parsed.scheme}' is not allowed. Only http/https are permitted."
            )
        # Block localhost / internal IPs (SSRF prevention)
        host = (parsed.hostname or "").lower()
        if host in ("localhost", "127.0.0.1", "0.0.0.0", "::1") or host.startswith("192.168.") or host.startswith("10.") or host.startswith("172."):
            return ValidationResult.fail(
                f"URL points to internal/private address '{host}'. This is blocked for security."
            )
    return ValidationResult.success()


# ---------------------------------------------------------------------------
# File / path validators
# ---------------------------------------------------------------------------

@_register(r".*FILE.*|.*READ_FILE.*|.*WRITE_FILE.*|.*DELETE_FILE.*")
def _validate_file_path(tool_name: str, args: dict[str, Any]) -> ValidationResult:
    path = args.get("path") or args.get("file_path") or args.get("filename") or ""
    if isinstance(path, str) and path:
        # Block path traversal
        if ".." in path:
            return ValidationResult.fail(
                f"Path traversal detected in '{path}'. '..' is not allowed."
            )
        # Block sensitive paths
        sensitive = ("/etc/passwd", "/etc/shadow", ".env", "credentials", "secret", ".ssh", "id_rsa")
        lower = path.lower()
        for s in sensitive:
            if s in lower:
                return ValidationResult.fail(
                    f"Access to sensitive path '{path}' is blocked."
                )
    return ValidationResult.success()


# ---------------------------------------------------------------------------
# Slack validators
# ---------------------------------------------------------------------------

@_register(r".*SLACK.*SEND.*|.*SLACK.*POST.*|.*SLACK.*MESSAGE.*")
def _validate_slack(tool_name: str, args: dict[str, Any]) -> ValidationResult:
    channel = args.get("channel") or args.get("channel_id") or ""
    text = args.get("text") or args.get("message") or ""
    if isinstance(text, str) and len(text) > 40_000:
        return ValidationResult.fail(
            "Slack message is too long (>40K chars). Slack has a 40K char limit."
        )
    return ValidationResult.success()


# ---------------------------------------------------------------------------
# Generic batch operation validator
# ---------------------------------------------------------------------------

@_register(r".*BATCH.*|.*BULK.*")
def _validate_batch(tool_name: str, args: dict[str, Any]) -> ValidationResult:
    # Check for suspiciously large batch sizes
    for key in ("count", "limit", "batch_size", "num"):
        val = args.get(key)
        if isinstance(val, int) and val > 100:
            return ValidationResult.fail(
                f"Batch size {val} for '{key}' is too large. Maximum is 100."
            )
    return ValidationResult.success()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def validate_tool_input(tool_name: str, arguments: dict[str, Any]) -> ValidationResult:
    """Run all matching validators against the tool input.

    Returns the first failure, or success if all pass.
    """
    upper = tool_name.upper()
    for pattern, validator in _VALIDATORS:
        if re.fullmatch(pattern, upper):
            result = validator(tool_name, arguments)
            if not result.ok:
                logger.warning(
                    "Tool input validation failed: tool=%s reason=%s",
                    tool_name, result.message,
                )
                return result
    return ValidationResult.success()


def truncate_tool_result(result: str, max_chars: int = MAX_TOOL_RESULT_CHARS) -> str:
    """Truncate tool results that exceed the size limit.

    Large results waste tokens when sent back to the LLM.
    """
    if len(result) <= max_chars:
        return result
    truncated = result[:max_chars]
    logger.info(
        "Tool result truncated from %d to %d chars", len(result), max_chars,
    )
    return truncated + f"\n\n...[truncated, showing {max_chars}/{len(result)} chars]"
