import logging
from functools import lru_cache

from fastapi import APIRouter, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

from app.config import settings
from app.security import audit_tool_arguments
from app.tool_permissions import check_tool_permission
from app.tool_validation import truncate_tool_result, validate_tool_input

logger = logging.getLogger(__name__)

router = APIRouter()


@lru_cache()
def _get_composio():
    if not settings.composio_api_key:
        raise HTTPException(status_code=503, detail="Composio API key not configured.")
    from composio import Composio
    return Composio(api_key=settings.composio_api_key)


# Use a fixed local user ID for Composio (no auth system)
LOCAL_USER_ID = "local-user"


class ConnectRequest(BaseModel):
    app_name: str


class ConnectionOut(BaseModel):
    id: str
    app_name: str
    status: str


def _list_user_connection_ids() -> set[str]:
    composio = _get_composio()
    resp = composio.connected_accounts.list(user_ids=[LOCAL_USER_ID])
    items = getattr(resp, "items", []) or []
    return {str(getattr(acc, "id", "")) for acc in items if getattr(acc, "id", None)}


@router.get("/connections", response_model=list[ConnectionOut])
async def get_connections():
    try:
        composio = _get_composio()
        resp = composio.connected_accounts.list(user_ids=[LOCAL_USER_ID])
        items = getattr(resp, "items", []) or []
        results = []
        for acc in items:
            status = getattr(acc, "status", "")
            slug = getattr(acc, "toolkit_slug", None) or getattr(acc, "app_name", "") or ""
            conn_id = getattr(acc, "id", "") or ""
            if slug:
                results.append(ConnectionOut(
                    id=str(conn_id), app_name=slug.lower(),
                    status=str(status).upper() if status else "ACTIVE",
                ))
        return results
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Composio list connections failed: %s", e, exc_info=True)
        return []


@router.post("/connect")
async def connect_app(req: ConnectRequest):
    toolkit_name = req.app_name.lower()
    try:
        composio = _get_composio()
        session = composio.create(user_id=LOCAL_USER_ID)
        try:
            resp = composio.connected_accounts.list(
                user_ids=[LOCAL_USER_ID], toolkit_slugs=[toolkit_name]
            )
            items = getattr(resp, "items", []) or []
            for acc in items:
                status = str(getattr(acc, "status", "")).upper()
                if status == "ACTIVE":
                    return {"redirect_url": None, "already_connected": True}
        except Exception as check_err:
            logger.warning("Could not check existing connections: %s", check_err)
        connection_request = session.authorize(toolkit_name)
        redirect_url = getattr(connection_request, "redirect_url", None)
        if not redirect_url and isinstance(connection_request, dict):
            redirect_url = connection_request.get("redirect_url") or connection_request.get("redirectUrl")
        if not redirect_url:
            raise HTTPException(status_code=502, detail="No redirect URL returned")
        return {"redirect_url": redirect_url}
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Composio connect failed: %s", e, exc_info=True)
        raise HTTPException(status_code=502, detail=f"Failed to connect {req.app_name}.")


@router.delete("/connections/{connection_id}")
async def disconnect_app(connection_id: str):
    import httpx
    try:
        allowed_connection_ids = _list_user_connection_ids()
        if connection_id not in allowed_connection_ids:
            raise HTTPException(status_code=404, detail="Connection not found.")
        async with httpx.AsyncClient() as http_client:
            resp = await http_client.delete(
                f"https://backend.composio.dev/api/v3/connected_accounts/{connection_id}",
                headers={"x-api-key": settings.composio_api_key},
                timeout=15,
            )
            if resp.status_code not in (200, 204):
                raise HTTPException(status_code=502, detail="Failed to disconnect")
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Composio disconnect error: %s", e)
        raise HTTPException(status_code=502, detail="Failed to disconnect.")
    return {"ok": True}


@router.get("/apps")
async def list_apps():
    import httpx
    try:
        async with httpx.AsyncClient() as http_client:
            resp = await http_client.get(
                "https://backend.composio.dev/api/v1/apps",
                headers={"x-api-key": settings.composio_api_key},
                timeout=15,
            )
            if resp.status_code != 200:
                return []
        data = resp.json()
        items = data if isinstance(data, list) else data.get("items", data.get("data", []))
        return [
            {
                "key": a.get("key", a.get("appId", "")),
                "name": a.get("displayName") or a.get("name", ""),
                "description": a.get("description", ""),
                "logo": a.get("logo", ""),
                "categories": a.get("categories", []),
            }
            for a in items if a.get("name")
        ]
    except Exception as e:
        logger.error("Composio list apps failed: %s", e)
        return []


def _sanitize_schema(schema):
    if isinstance(schema, bool):
        return schema
    if not isinstance(schema, dict):
        return {}
    result = {}
    for k, v in schema.items():
        if k in ("properties", "patternProperties"):
            result[k] = {pk: _sanitize_schema(pv) for pk, pv in v.items()} if isinstance(v, dict) else {}
        elif k in ("items", "additionalProperties", "not"):
            result[k] = _sanitize_schema(v)
        elif k in ("allOf", "anyOf", "oneOf"):
            result[k] = [_sanitize_schema(item) for item in v] if isinstance(v, list) else []
        elif k == "required":
            if isinstance(v, list):
                result[k] = [str(x) for x in v if isinstance(x, str)]
        else:
            result[k] = v
    return result


class ToolsRequest(BaseModel):
    app_name: str | None = None


class ExecuteRequest(BaseModel):
    tool_name: str
    arguments: dict = {}


@router.post("/tools")
async def list_tools(req: ToolsRequest | None = None):
    try:
        composio = _get_composio()
        session = composio.create(user_id=LOCAL_USER_ID)
        tools = session.tools()
        result = []
        for t in tools:
            if isinstance(t, dict):
                fn = t.get("function", t)
                name = fn.get("name", "")
                desc = fn.get("description", "")
                params = fn.get("parameters", {})
            else:
                name = getattr(t, "slug", None) or getattr(t, "name", str(t))
                desc = getattr(t, "description", "")
                params = getattr(t, "parameters", {})
            if not name:
                continue
            if req and req.app_name:
                if not name.upper().startswith(req.app_name.upper() + "_"):
                    continue
            params = _sanitize_schema(params)
            result.append({"name": name, "description": desc, "parameters": params})
        return result
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Composio list tools failed: %s", e, exc_info=True)
        return []


@router.post("/execute")
async def execute_tool(req: ExecuteRequest):
    # Permission check
    perm = check_tool_permission(req.tool_name)
    if perm["behavior"] == "deny":
        raise HTTPException(status_code=403, detail=perm["message"])

    # Input validation
    validation = validate_tool_input(req.tool_name, req.arguments)
    if not validation.ok:
        raise HTTPException(status_code=400, detail=validation.message)

    # Security audit
    findings = audit_tool_arguments(req.tool_name, req.arguments)
    if findings:
        threat_types = [f["threat_type"] for f in findings]
        logger.warning("Security audit findings for %s: %s", req.tool_name, threat_types)
        # Block execution if critical threats found
        critical = {"sql_injection", "command_injection"}
        if critical & set(threat_types):
            raise HTTPException(
                status_code=403,
                detail=f"Blocked: security audit detected {threat_types}",
            )

    try:
        composio = _get_composio()
        result = composio.tools.execute(
            req.tool_name, user_id=LOCAL_USER_ID,
            arguments=req.arguments, dangerously_skip_version_check=True,
        )
        if isinstance(result, dict):
            import json
            raw = json.dumps(result, ensure_ascii=False)
        else:
            raw = str(result)
        # Truncate large results
        return {
            "result": truncate_tool_result(raw),
            "permission": perm["behavior"],
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Composio execute failed: %s %s", req.tool_name, e, exc_info=True)
        raise HTTPException(status_code=502, detail="Tool execution failed.")


@router.get("/callback", response_class=HTMLResponse)
async def oauth_callback():
    return HTMLResponse(
        "<html><body style='font-family:system-ui;display:flex;justify-content:center;"
        "align-items:center;height:100vh;margin:0;background:#111;color:#fff'>"
        "<div style='text-align:center'>"
        "<h2>Connected!</h2>"
        "<p style='color:#888'>You can close this tab and go back to SpeakFlow.</p>"
        "</div></body></html>"
    )
