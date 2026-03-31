"""Tool permission system inspired by Claude Code's allow/ask/deny model.

Tools are classified into three tiers:
- allow: Safe, read-only operations that execute immediately.
- ask:   Potentially destructive or externally-visible actions that require user confirmation.
- deny:  Blocked operations that are never executed.

Classification is pattern-based on tool name prefixes/keywords.
"""

from __future__ import annotations

import logging
import re
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Permission rules (pattern → behavior)
# Patterns are matched case-insensitively against the tool name.
# More specific patterns should come first; first match wins.
# ---------------------------------------------------------------------------

# Tools that are always blocked
DENY_PATTERNS: list[str] = [
    r".*DELETE_ACCOUNT.*",
    r".*DROP_DATABASE.*",
    r".*REMOVE_ALL.*",
    r".*FORMAT_DISK.*",
]

# Tools that require user confirmation before execution
ASK_PATTERNS: list[str] = [
    # Sending / publishing
    r".*SEND_EMAIL.*",
    r".*SEND_MESSAGE.*",
    r".*POST_MESSAGE.*",
    r".*CREATE_ISSUE.*",
    r".*CREATE_PULL.*",
    r".*REPLY.*",
    r".*FORWARD.*",
    # Deletion
    r".*DELETE.*",
    r".*REMOVE.*",
    r".*TRASH.*",
    r".*ARCHIVE.*",
    # Modification of shared state
    r".*UPDATE.*",
    r".*EDIT.*",
    r".*MODIFY.*",
    r".*MOVE.*",
    r".*RENAME.*",
    # Financial / payment
    r".*PAYMENT.*",
    r".*TRANSFER.*",
    r".*PURCHASE.*",
    # Calendar mutations
    r".*CREATE_EVENT.*",
    r".*DELETE_EVENT.*",
    r".*UPDATE_EVENT.*",
    r".*RESPOND_TO_EVENT.*",
]

# Everything else is allowed by default.
# Explicit allow patterns for documentation / override purposes:
ALLOW_PATTERNS: list[str] = [
    r".*SEARCH.*",
    r".*LIST.*",
    r".*GET.*",
    r".*READ.*",
    r".*FETCH.*",
    r".*FIND.*",
    r".*CHECK.*",
    r".*VIEW.*",
    r".*SHOW.*",
    r".*PROFILE.*",
    r".*LABELS.*",
]


def _match_any(name: str, patterns: list[str]) -> bool:
    upper = name.upper()
    return any(re.fullmatch(p, upper) for p in patterns)


def classify_tool(name: str) -> str:
    """Classify a single tool name into 'allow', 'ask', or 'deny'."""
    if _match_any(name, DENY_PATTERNS):
        return "deny"
    if _match_any(name, ALLOW_PATTERNS):
        return "allow"
    if _match_any(name, ASK_PATTERNS):
        return "ask"
    # Default: allow for read-like names, ask for everything else
    upper = name.upper()
    if any(kw in upper for kw in ("SEARCH", "LIST", "GET", "READ", "FETCH", "FIND", "CHECK", "VIEW")):
        return "allow"
    return "ask"


def classify_tools(tool_names: list[str]) -> dict[str, list[str]]:
    """Classify a list of tool names into allow/ask/deny buckets."""
    result: dict[str, list[str]] = {"allow": [], "ask": [], "deny": []}
    for name in tool_names:
        tier = classify_tool(name)
        result[tier].append(name)
    return result


def filter_denied_tools(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Remove denied tools from the tool list before sending to the LLM.

    Denied tools should never even appear in the model's schema.
    """
    filtered = []
    for tool in tools:
        fn = tool.get("function", {})
        name = fn.get("name", "")
        if classify_tool(name) == "deny":
            logger.warning("Tool denied and filtered out: %s", name)
            continue
        filtered.append(tool)
    return filtered


def check_tool_permission(tool_name: str) -> dict[str, Any]:
    """Check permission for a tool call and return a decision.

    Returns:
        {
            "behavior": "allow" | "ask" | "deny",
            "message": str | None,  # Human-readable explanation
        }
    """
    tier = classify_tool(tool_name)
    if tier == "deny":
        return {
            "behavior": "deny",
            "message": f"Tool '{tool_name}' is blocked by security policy.",
        }
    if tier == "ask":
        return {
            "behavior": "ask",
            "message": f"Tool '{tool_name}' requires user confirmation before execution.",
        }
    return {
        "behavior": "allow",
        "message": None,
    }
