"""Multi-layered security system inspired by Claude Code's safety architecture.

Layers:
1. Prompt injection detection in client messages
2. Tool argument sanitization and audit
3. Rate limiting helpers
"""

from __future__ import annotations

import logging
import re
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Layer 1: Prompt injection detection
# ---------------------------------------------------------------------------

# Suspicious patterns that may indicate prompt injection attempts
INJECTION_PATTERNS: list[tuple[str, str]] = [
    # Role hijacking
    (r"(?i)ignore\s+(all\s+)?previous\s+instructions", "role_hijack"),
    (r"(?i)forget\s+(all\s+)?(your\s+)?instructions", "role_hijack"),
    (r"(?i)you\s+are\s+now\s+(a|an)\s+", "role_hijack"),
    (r"(?i)act\s+as\s+(a|an)\s+", "role_hijack"),
    (r"(?i)pretend\s+(to\s+be|you\s+are)", "role_hijack"),
    (r"(?i)from\s+now\s+on.*you\s+(are|will|must|should)", "role_hijack"),
    # System prompt extraction
    (r"(?i)(show|reveal|print|output|repeat|display)\s+(your\s+)?(system\s+prompt|instructions|rules)", "prompt_extraction"),
    (r"(?i)what\s+(are|is)\s+your\s+(system\s+)?prompt", "prompt_extraction"),
    # Encoding bypass
    (r"(?i)base64\s*decode", "encoding_bypass"),
    (r"(?i)rot13", "encoding_bypass"),
    # Delimiter injection
    (r"<\s*/?\s*system\s*>", "delimiter_injection"),
    (r"\[INST\]|\[/INST\]", "delimiter_injection"),
    (r"<\|im_start\|>|<\|im_end\|>", "delimiter_injection"),
    (r"###\s*(System|Human|Assistant)\s*:", "delimiter_injection"),
    # Tool fabrication
    (r"(?i)(create|add|register|define)\s+(a\s+)?(new\s+)?tool", "tool_fabrication"),
    (r"(?i)execute\s+(this\s+)?(shell|bash|command|code)", "tool_fabrication"),
]


def detect_prompt_injection(text: str) -> list[dict[str, str]]:
    """Scan text for prompt injection patterns.

    Returns a list of detections, each with 'pattern_type' and 'matched_text'.
    Empty list means no injection detected.
    """
    if not isinstance(text, str):
        return []

    detections: list[dict[str, str]] = []
    for pattern, pattern_type in INJECTION_PATTERNS:
        matches = re.findall(pattern, text)
        if matches:
            # Get the actual matched text for logging
            match_obj = re.search(pattern, text)
            matched = match_obj.group(0) if match_obj else str(matches[0])
            detections.append({
                "pattern_type": pattern_type,
                "matched_text": matched[:100],  # Truncate for safety
            })
    return detections


def scan_messages_for_injection(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Scan all user/system messages for prompt injection.

    Returns list of detections with message index and details.
    """
    all_detections: list[dict[str, Any]] = []
    for i, msg in enumerate(messages):
        content = msg.get("content", "")
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = " ".join(
                part.get("text", "") for part in content
                if isinstance(part, dict) and part.get("type") == "text"
            )
        if not text:
            continue

        detections = detect_prompt_injection(text)
        if detections:
            for d in detections:
                all_detections.append({
                    "message_index": i,
                    "role": msg.get("role", "unknown"),
                    **d,
                })

    if all_detections:
        logger.warning(
            "Prompt injection detected: %d suspicious patterns in %d messages",
            len(all_detections),
            len({d["message_index"] for d in all_detections}),
        )
    return all_detections


# ---------------------------------------------------------------------------
# Layer 2: Tool argument sanitization
# ---------------------------------------------------------------------------

# Dangerous argument patterns by key name
DANGEROUS_ARG_PATTERNS: dict[str, list[tuple[str, str]]] = {
    # SQL injection in any string argument
    "*": [
        (r";\s*(DROP|DELETE|ALTER|TRUNCATE|INSERT|UPDATE)\s+", "sql_injection"),
        (r"'\s*(OR|AND)\s+'?\d+'\s*=\s*'?\d+", "sql_injection"),
    ],
    # Command injection in path/command arguments
    "command": [
        (r"[;&|`$]", "command_injection"),
        (r"\$\(", "command_injection"),
    ],
    "path": [
        (r"\.\./", "path_traversal"),
        (r"[;&|`$]", "command_injection"),
    ],
    "file_path": [
        (r"\.\./", "path_traversal"),
    ],
    "url": [
        (r"javascript:", "xss"),
        (r"data:text/html", "xss"),
    ],
}


def audit_tool_arguments(tool_name: str, arguments: dict[str, Any]) -> list[dict[str, str]]:
    """Audit tool arguments for dangerous patterns.

    Returns list of findings, each with 'key', 'threat_type', and 'detail'.
    """
    findings: list[dict[str, str]] = []

    for key, value in arguments.items():
        if not isinstance(value, str):
            continue

        # Check key-specific patterns
        patterns_to_check = DANGEROUS_ARG_PATTERNS.get(key.lower(), [])
        # Also check wildcard patterns
        patterns_to_check += DANGEROUS_ARG_PATTERNS.get("*", [])

        for pattern, threat_type in patterns_to_check:
            if re.search(pattern, value, re.IGNORECASE):
                findings.append({
                    "key": key,
                    "threat_type": threat_type,
                    "detail": f"Suspicious pattern in argument '{key}' of tool '{tool_name}'",
                })

    if findings:
        logger.warning(
            "Tool argument audit findings: tool=%s count=%d types=%s",
            tool_name,
            len(findings),
            list({f["threat_type"] for f in findings}),
        )
    return findings
