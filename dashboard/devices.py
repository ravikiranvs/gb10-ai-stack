"""OpenClaw device pairing for the dashboard, through ops-bridge: list, approve, reject, revoke, a timed enrollment window and
per-user device labels. The dashboard has no access to the sandbox itself; every operation is an ops-bridge action."""

import asyncio
import json
import os
import re
import time
from pathlib import Path

import httpx

BRIDGE_URL = os.environ.get("BRIDGE_URL", "http://ops-bridge:9200")
BRIDGE_TOKEN_FILE = Path(os.environ.get("BRIDGE_TOKEN_FILE", "/run/secrets/bridge_dashboard_token"))
PUBLIC_HOST = os.environ.get("PUBLIC_HOST", "")
ENROLL_MINUTES = int(os.environ.get("OPENCLAW_ENROLL_MINUTES", "10"))
# A browser that asks to pair within this long after someone opened /connect is attributed to that person.
ATTRIBUTION_SECONDS = 600
BROWSER_CLIENT = "openclaw-control-ui"

REQUEST_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DEVICE_ID = re.compile(r"^[0-9a-f]{64}$")


class BridgeError(Exception):
    pass


def audit(**fields) -> None:
    print(json.dumps({"ts": round(time.time(), 3), "event": "audit", "source": "dashboard.devices", **fields},
                     separators=(",", ":")), flush=True)


class State:
    enroll_until = 0.0          # epoch seconds; the enrollment window is open while now < enroll_until
    enroll_by = ""
    connects: list[tuple[str, float]] = []   # (user, epoch) of recent /connect visits


state = State()


# ─────────────────────────── bridge client ───────────────────────────

async def bridge(action: str, **params) -> dict:
    try:
        token = BRIDGE_TOKEN_FILE.read_text().strip()
    except OSError as exc:
        raise BridgeError("the ops-bridge secret is not readable") from exc
    try:
        async with httpx.AsyncClient(base_url=BRIDGE_URL, timeout=60) as c:
            r = await c.post(f"/v1/actions/{action}", json={"params": params}, headers={"Authorization": f"Bearer {token}"})
    except httpx.HTTPError as exc:
        raise BridgeError("ops-bridge is unreachable") from exc
    if r.status_code == 409:
        raise BridgeError("the OpenClaw sandbox is not running")
    if r.status_code >= 400:
        detail = r.json().get("detail", r.text) if r.headers.get("content-type", "").startswith("application/json") else r.text
        raise BridgeError(f"ops-bridge refused ({r.status_code}): {detail}")
    return r.json()


async def run(action: str, **params) -> dict:
    res = await bridge(action, **params)
    if not res.get("ok"):
        raise BridgeError((res.get("stderr") or res.get("stdout") or "the operation failed").strip()[:300])
    return res


# ─────────────────────────── data ───────────────────────────

def ago(seconds) -> str:
    if seconds is None:
        return "—"
    s = int(seconds)
    if s < 90:
        return f"{max(s, 0)}s"
    if s < 5400:
        return f"{s // 60}m"
    if s < 172800:
        return f"{s // 3600}h"
    return f"{s // 86400}d"


def short(device_id: str) -> str:
    return device_id[:8]


def normalise_pending(p: dict, now: float) -> dict:
    scopes = p.get("scopes") or []
    return {
        "request_id": p.get("requestId", ""), "device_id": p.get("deviceId", ""),
        "name": p.get("displayName") or p.get("platform") or p.get("clientId") or "unknown device",
        "platform": p.get("platform") or "", "client": p.get("clientId") or "", "mode": p.get("clientMode") or "",
        "ip": p.get("remoteIp") or "", "scopes": scopes, "kind": "scope upgrade" if p.get("isRepair") else "new pairing",
        "age_s": now - p["ts"] / 1000 if p.get("ts") else None, "ts_ms": p.get("ts"),
        "is_browser": p.get("clientId") == BROWSER_CLIENT, "suggested_user": suggest_user(p.get("ts")),
    }


def normalise_paired(d: dict, now: float) -> dict:
    return {
        "device_id": d.get("deviceId", ""), "label": d.get("operatorLabel") or d.get("displayName") or d.get("label") or "",
        "platform": d.get("platform") or "", "client": d.get("clientId") or "", "ip": d.get("remoteIp") or "",
        "roles": d.get("roles") or ([d["role"]] if d.get("role") else []), "scopes": d.get("scopes") or [],
        "via": d.get("approvedVia") or "", "connected": bool(d.get("connected")),
        "seen_s": now - d["lastSeenAtMs"] / 1000 if d.get("lastSeenAtMs") else None,
        "is_browser": d.get("clientId") == BROWSER_CLIENT,
    }


async def list_devices() -> dict:
    res = await run("openclaw.devices.list")
    data = res.get("json") or {}
    now = time.time()
    return {"pending": [normalise_pending(p, now) for p in data.get("pending", [])],
            "paired": [normalise_paired(d, now) for d in data.get("paired", [])]}


# ─────────────────────────── attribution and labels ───────────────────────────

def record_connect(user: str) -> None:
    now = time.time()
    state.connects = [(u, t) for u, t in state.connects if now - t < 3600][-50:] + [(user, now)]


def suggest_user(ts_ms) -> str | None:
    """The one person who opened /connect shortly before this request, if exactly one did."""
    if not ts_ms:
        return None
    t = ts_ms / 1000
    users = {u for u, c in state.connects if t - ATTRIBUTION_SECONDS <= c <= t + 60}
    return next(iter(users)) if len(users) == 1 else None


def make_label(user: str, platform: str, ts: float) -> str:
    raw = f"{user} {platform or 'browser'} {time.strftime('%Y-%m-%d', time.localtime(ts))}"
    clean = re.sub(r"[^A-Za-z0-9 ._@:+-]", " ", raw).strip()
    return re.sub(r"\s+", " ", clean)[:64]


# ─────────────────────────── actions ───────────────────────────

async def approve(request_id: str, who: str, automatic: bool = False, req: dict | None = None) -> dict:
    if req is None:
        req = {p["request_id"]: p for p in (await list_devices())["pending"]}.get(request_id)
    await run("openclaw.devices.approve", request_id=request_id)
    label = None
    if req and req["suggested_user"] and req["is_browser"] and req["kind"] == "new pairing":
        label = make_label(req["suggested_user"], req["platform"], time.time())
        try:
            await run("openclaw.devices.rename", device_id=req["device_id"], label=label)
        except BridgeError:
            label = None   # the device is approved; a missing label is only cosmetic
    audit(action="approve", request=request_id, device=short(req["device_id"]) if req else None, by=who,
          automatic=automatic, label=label)
    return {"label": label}


async def reject(request_id: str, who: str) -> None:
    await run("openclaw.devices.reject", request_id=request_id)
    audit(action="reject", request=request_id, by=who)


async def revoke(device_id: str, who: str) -> None:
    await run("openclaw.devices.revoke", device_id=device_id, role="operator")  # kill the token first,
    await run("openclaw.devices.remove", device_id=device_id)                   # then drop the entry from the list
    audit(action="revoke", device=short(device_id), by=who)


def window_remaining() -> int:
    return max(0, int(state.enroll_until - time.time()))


def open_window(who: str, minutes: int = ENROLL_MINUTES) -> None:
    state.enroll_until = time.time() + minutes * 60
    state.enroll_by = who
    audit(action="enrollment_open", by=who, minutes=minutes)


def close_window(who: str) -> None:
    if window_remaining():
        audit(action="enrollment_close", by=who)
    state.enroll_until = 0.0


async def enrollment_watcher() -> None:
    """While the window is open, approve new browser pairings (not scope upgrades, not the CLI or other clients)."""
    while True:
        await asyncio.sleep(3)
        if not window_remaining():
            continue
        try:
            for p in (await list_devices())["pending"]:
                if p["is_browser"] and p["kind"] == "new pairing":
                    await approve(p["request_id"], f"enrollment window ({state.enroll_by})", automatic=True, req=p)
        except BridgeError as exc:
            print(json.dumps({"event": "enrollment_error", "detail": str(exc)}), flush=True)


async def gateway_token() -> str:
    return (await run("openclaw.gateway_token"))["stdout"].strip()
