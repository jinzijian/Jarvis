import json
import logging
import re
from hashlib import sha256
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.config import settings
from app.prompts import build_agent_system_prompt
from app.security import audit_tool_arguments, scan_messages_for_injection
from app.services.openai_service import client
from app.services.usage_service import increment_usage
from app.tool_permissions import check_tool_permission, filter_denied_tools
from app.tool_validation import truncate_tool_result, validate_tool_input

logger = logging.getLogger(__name__)
router = APIRouter()

ALLOWED_AGENT_MESSAGE_ROLES = {"user", "assistant", "tool"}
MAX_AGENT_MESSAGES = 100
MAX_AGENT_TOOLS = 128
MAX_PROMPT_CACHE_KEY_CHARS = 128


class AgentChatRequest(BaseModel):
    messages: list[dict[str, Any]]
    tools: list[dict[str, Any]] | None = None
    prompt_cache_key: str | None = None
    connected_tools: list[str] | None = None  # Names of connected integrations
    recent_actions: list[str] | None = None  # Recent user actions for context


class AgentMessageResponse(BaseModel):
    role: str
    content: str | None = None
    tool_calls: list[dict[str, Any]] | None = None


class AgentUsageResponse(BaseModel):
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    cached_prompt_tokens: int


class ToolPermissionInfo(BaseModel):
    tool_name: str
    behavior: str  # allow, ask, deny
    message: str | None = None


class AgentChatResponse(BaseModel):
    message: AgentMessageResponse
    usage: AgentUsageResponse
    tool_permissions: list[ToolPermissionInfo] | None = None
    security_warnings: list[str] | None = None


def _is_json_like(value: Any) -> bool:
    if value is None or isinstance(value, str | int | float | bool):
        return True
    if isinstance(value, list):
        return all(_is_json_like(item) for item in value)
    if isinstance(value, dict):
        return all(isinstance(key, str) and _is_json_like(item) for key, item in value.items())
    return False


def _extract_system_context(content: Any) -> str | None:
    if isinstance(content, str):
        text = content.strip()
        return text or None
    if isinstance(content, list):
        text_parts: list[str] = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str):
                value = part["text"].strip()
                if value:
                    text_parts.append(value)
        if text_parts:
            return "\n".join(text_parts)
    return None


def _sanitize_tool_calls(tool_calls: Any) -> list[dict[str, Any]] | None:
    if tool_calls is None:
        return None
    if not isinstance(tool_calls, list):
        raise HTTPException(status_code=400, detail="Invalid assistant tool_calls payload.")
    sanitized: list[dict[str, Any]] = []
    for call in tool_calls:
        if not isinstance(call, dict):
            raise HTTPException(status_code=400, detail="Invalid assistant tool_call entry.")
        call_id = call.get("id")
        if not isinstance(call_id, str) or not call_id:
            raise HTTPException(status_code=400, detail="Assistant tool_call is missing an id.")
        if call.get("type") != "function":
            raise HTTPException(status_code=400, detail="Only function tool_calls are supported.")
        function = call.get("function")
        if not isinstance(function, dict):
            raise HTTPException(status_code=400, detail="Assistant tool_call function is invalid.")
        name = function.get("name")
        arguments = function.get("arguments")
        if not isinstance(name, str) or not name:
            raise HTTPException(status_code=400, detail="Assistant tool_call function name is invalid.")
        if not isinstance(arguments, str):
            raise HTTPException(status_code=400, detail="Assistant tool_call arguments must be a string.")
        sanitized.append({
            "id": call_id,
            "type": "function",
            "function": {"name": name, "arguments": arguments},
        })
    return sanitized


def _sanitize_messages(
    messages: list[dict[str, Any]],
    *,
    tools: list[dict[str, Any]] | None = None,
    connected_tools: list[str] | None = None,
    recent_actions: list[str] | None = None,
    memories: list[dict[str, str]] | None = None,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Sanitize messages and build the system prompt.

    Returns (sanitized_messages, security_warnings).
    """
    if not messages:
        raise HTTPException(status_code=400, detail="At least one agent message is required.")
    if len(messages) > MAX_AGENT_MESSAGES:
        raise HTTPException(status_code=400, detail="Too many agent messages.")

    sanitized: list[dict[str, Any]] = []
    client_system_context: list[str] = []
    security_warnings: list[str] = []

    for message in messages:
        if not isinstance(message, dict):
            raise HTTPException(status_code=400, detail="Invalid agent message payload.")
        role = message.get("role")
        if role == "system":
            context = _extract_system_context(message.get("content"))
            if context:
                client_system_context.append(context)
            continue
        if role not in ALLOWED_AGENT_MESSAGE_ROLES:
            raise HTTPException(status_code=400, detail=f"Unsupported agent message role: {role}")
        content = message.get("content")
        if content is not None and not _is_json_like(content):
            raise HTTPException(status_code=400, detail="Agent message content must be JSON-serializable.")
        sanitized_message: dict[str, Any] = {"role": role, "content": content}
        if role == "assistant":
            sanitized_tool_calls = _sanitize_tool_calls(message.get("tool_calls"))
            if sanitized_tool_calls is not None:
                sanitized_message["tool_calls"] = sanitized_tool_calls
        if role == "tool":
            tool_call_id = message.get("tool_call_id")
            if not isinstance(tool_call_id, str) or not tool_call_id:
                raise HTTPException(status_code=400, detail="Tool messages require tool_call_id.")
            sanitized_message["tool_call_id"] = tool_call_id
            # Task 6: Truncate large tool results
            if isinstance(content, str):
                sanitized_message["content"] = truncate_tool_result(content)
        sanitized.append(sanitized_message)

    if not sanitized:
        raise HTTPException(status_code=400, detail="No valid agent messages remain after sanitization.")

    # Security Layer: Scan for prompt injection
    injection_detections = scan_messages_for_injection(sanitized)
    if injection_detections:
        warning_types = list({d["pattern_type"] for d in injection_detections})
        security_warnings.append(
            f"Detected potential prompt injection patterns: {', '.join(warning_types)}. "
            "The model has been instructed to ignore these."
        )

    # Build modular system prompt
    system_prompt = build_agent_system_prompt(
        client_contexts=client_system_context,
        tools=tools,
        connected_tools=connected_tools,
        recent_actions=recent_actions,
        memories=memories,
    )

    return [{"role": "system", "content": system_prompt}, *sanitized], security_warnings


def _sanitize_tools(tools: list[dict[str, Any]] | None) -> list[dict[str, Any]] | None:
    if tools is None:
        return None
    if len(tools) > MAX_AGENT_TOOLS:
        raise HTTPException(status_code=400, detail="Too many agent tools.")
    sanitized: list[dict[str, Any]] = []
    seen_names: set[str] = set()
    for tool in tools:
        if not isinstance(tool, dict):
            raise HTTPException(status_code=400, detail="Invalid tool definition payload.")
        if tool.get("type") != "function":
            raise HTTPException(status_code=400, detail="Only function tools are supported.")
        function = tool.get("function")
        if not isinstance(function, dict):
            raise HTTPException(status_code=400, detail="Tool function definition is invalid.")
        name = function.get("name")
        description = function.get("description")
        parameters = function.get("parameters")
        if not isinstance(name, str) or not name or len(name) > 128:
            raise HTTPException(status_code=400, detail="Tool function name is invalid.")
        if name in seen_names:
            raise HTTPException(status_code=400, detail=f"Duplicate tool name: {name}")
        if description is not None and not isinstance(description, str):
            raise HTTPException(status_code=400, detail=f"Tool description must be a string: {name}")
        if not isinstance(parameters, dict) or not _is_json_like(parameters):
            raise HTTPException(status_code=400, detail=f"Tool parameters must be a JSON object: {name}")
        sanitized.append({
            "type": "function",
            "function": {"name": name, "description": description or "", "parameters": parameters},
        })
        seen_names.add(name)

    # Filter out denied tools before sending to LLM
    sanitized = filter_denied_tools(sanitized)
    return sanitized


def _resolve_prompt_cache_key(raw_key: str | None, sanitized_messages: list[dict[str, Any]]) -> str:
    if raw_key:
        key = raw_key.strip()
        if key:
            key = re.sub(r"[^a-zA-Z0-9:_-]", "-", key)
            return key[:MAX_PROMPT_CACHE_KEY_CHARS]
    first_user_content: Any = ""
    for msg in sanitized_messages:
        if msg.get("role") == "user":
            first_user_content = msg.get("content")
            break
    digest = sha256(str(first_user_content).encode("utf-8")).hexdigest()[:32]
    return f"agent:{digest}"


def _build_tool_permissions(tools: list[dict[str, Any]] | None) -> list[ToolPermissionInfo] | None:
    """Build permission info for each tool to return to the client."""
    if not tools:
        return None
    permissions = []
    for tool in tools:
        name = tool.get("function", {}).get("name", "")
        if name:
            perm = check_tool_permission(name)
            permissions.append(ToolPermissionInfo(
                tool_name=name,
                behavior=perm["behavior"],
                message=perm["message"],
            ))
    return permissions


async def _load_memories() -> list[dict[str, str]] | None:
    """Load active memories for prompt context."""
    try:
        from app.services.memory_service import get_active_memories
        memories = await get_active_memories(limit=20)
        return memories if memories else None
    except Exception as e:
        logger.debug("Could not load memories: %s", e)
        return None


@router.post("/chat", response_model=AgentChatResponse)
async def agent_chat(body: AgentChatRequest):
    logger.info("agent_chat: messages=%d", len(body.messages))

    sanitized_tools = _sanitize_tools(body.tools)

    # Load persistent memories
    memories = await _load_memories()

    sanitized_messages, security_warnings = _sanitize_messages(
        body.messages,
        tools=sanitized_tools,
        connected_tools=body.connected_tools,
        recent_actions=body.recent_actions,
        memories=memories,
    )
    prompt_cache_key = _resolve_prompt_cache_key(body.prompt_cache_key, sanitized_messages)

    # Validate tool results in messages (security audit)
    for msg in sanitized_messages:
        if msg.get("role") == "tool" and isinstance(msg.get("content"), str):
            # Audit tool result content for security issues
            try:
                result_data = json.loads(msg["content"])
                if isinstance(result_data, dict):
                    # Extract tool name from context if available
                    findings = audit_tool_arguments("tool_result", result_data)
                    if findings:
                        security_warnings.append(
                            f"Suspicious content in tool result: {[f['threat_type'] for f in findings]}"
                        )
            except (json.JSONDecodeError, TypeError):
                pass  # Non-JSON content is fine

    kwargs: dict[str, Any] = {
        "model": settings.gpt_model,
        "messages": sanitized_messages,
        "max_completion_tokens": settings.gpt_max_tokens,
        "prompt_cache_key": prompt_cache_key,
        "prompt_cache_retention": settings.gpt_prompt_cache_retention,
    }
    if sanitized_tools:
        kwargs["tools"] = sanitized_tools

    try:
        response = await client.chat.completions.create(**kwargs)
    except Exception as e:
        error_text = str(e).lower()
        if "prompt_cache" in error_text or "unknown parameter" in error_text:
            logger.warning("OpenAI rejected prompt cache params, retrying without: %s", e)
            fallback_kwargs = dict(kwargs)
            fallback_kwargs.pop("prompt_cache_key", None)
            fallback_kwargs.pop("prompt_cache_retention", None)
            try:
                response = await client.chat.completions.create(**fallback_kwargs)
            except Exception as retry_error:
                logger.error("OpenAI retry failed: %s", retry_error, exc_info=True)
                raise HTTPException(status_code=502, detail="LLM request failed.")
        else:
            logger.error("OpenAI failed: %s", e, exc_info=True)
            raise HTTPException(status_code=502, detail="LLM request failed.")

    if not response.choices:
        raise HTTPException(status_code=502, detail="LLM returned empty choices.")
    choice = response.choices[0].message
    if response.usage is None:
        raise HTTPException(status_code=502, detail="LLM usage metadata missing.")

    cached_prompt_tokens = (
        response.usage.prompt_tokens_details.cached_tokens
        if response.usage.prompt_tokens_details and response.usage.prompt_tokens_details.cached_tokens is not None
        else 0
    )

    await increment_usage(
        audio_seconds=0,
        input_tokens=response.usage.prompt_tokens,
        output_tokens=response.usage.completion_tokens,
    )

    tool_calls = None
    tool_permissions_info: list[ToolPermissionInfo] | None = None
    if choice.tool_calls:
        tool_calls = []
        tool_permissions_info = []
        for tc in choice.tool_calls:
            # Check permission for each tool call
            perm = check_tool_permission(tc.function.name)
            tool_permissions_info.append(ToolPermissionInfo(
                tool_name=tc.function.name,
                behavior=perm["behavior"],
                message=perm["message"],
            ))

            # Validate tool input
            try:
                args = json.loads(tc.function.arguments)
            except json.JSONDecodeError:
                args = {}
            validation = validate_tool_input(tc.function.name, args)
            if not validation.ok:
                security_warnings.append(
                    f"Tool '{tc.function.name}' input validation failed: {validation.message}"
                )

            # Security audit on tool arguments
            findings = audit_tool_arguments(tc.function.name, args)
            if findings:
                security_warnings.append(
                    f"Security audit warning for '{tc.function.name}': "
                    f"{[f['threat_type'] for f in findings]}"
                )

            tool_calls.append({
                "id": tc.id,
                "type": tc.type,
                "function": {"name": tc.function.name, "arguments": tc.function.arguments},
            })

    return AgentChatResponse(
        message=AgentMessageResponse(role=choice.role, content=choice.content, tool_calls=tool_calls),
        usage=AgentUsageResponse(
            prompt_tokens=response.usage.prompt_tokens,
            completion_tokens=response.usage.completion_tokens,
            total_tokens=response.usage.total_tokens,
            cached_prompt_tokens=cached_prompt_tokens,
        ),
        tool_permissions=tool_permissions_info,
        security_warnings=security_warnings if security_warnings else None,
    )
