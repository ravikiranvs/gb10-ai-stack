"""GB10 AI stack admin dashboard: status + model up/down + ComfyUI idle unloader."""

import asyncio
import json
import logging
import os
import random
import re
import time
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import BackgroundTasks, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

LLAMA_SWAP_URL = os.environ.get("LLAMA_SWAP_URL", "http://model-runner:8000")
COMFY_URL = os.environ.get("COMFY_URL", "http://comfyui:8188")
COMFY_WORKFLOW = Path(os.environ.get("COMFY_WORKFLOW", "/app/workflows/flux-schnell-api.json"))
COMFY_IDLE_SECONDS = int(os.environ.get("COMFY_IDLE_MINUTES", "10")) * 60
DOCKER_URL = os.environ.get("DOCKER_URL", "http://docker-socket-proxy:2375")
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")
ADMIN_GROUP = os.environ.get("ADMIN_GROUP", "admins")
NEMOCLAW_SANDBOX = os.environ.get("NEMOCLAW_SANDBOX", "my-assistant")

MODEL_ID = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
log = logging.getLogger("dashboard")


class ComfyIdleState:
    last_activity = time.monotonic()
    last_history_id: str | None = None
    freed = True


comfy_state = ComfyIdleState()


# ─────────────────────────── helpers ───────────────────────────

async def get_json(client: httpx.AsyncClient, url: str, **kwargs):
    try:
        r = await client.get(url, timeout=5, **kwargs)
        r.raise_for_status()
        return r.json()
    except (httpx.HTTPError, ValueError):
        return None


async def prom_scalar(client: httpx.AsyncClient, query: str) -> float | None:
    data = await get_json(client, f"{PROMETHEUS_URL}/api/v1/query", params={"query": query})
    try:
        return float(data["data"]["result"][0]["value"][1])
    except (TypeError, KeyError, IndexError, ValueError):
        return None


def identity(request: Request) -> dict:
    user = request.headers.get("Remote-User")
    if not user:
        raise HTTPException(401, "Missing identity (request did not pass through Authelia)")
    groups = [g.strip() for g in request.headers.get("Remote-Groups", "").split(",") if g.strip()]
    return {"user": user, "groups": groups, "admin": ADMIN_GROUP in groups}


def require_admin(request: Request) -> dict:
    who = identity(request)
    if not who["admin"]:
        raise HTTPException(403, f"Requires group '{ADMIN_GROUP}'")
    return who


def tiny_workflow() -> dict:
    wf = json.loads(COMFY_WORKFLOW.read_text())
    wf["2"]["inputs"]["text"] = "warmup"
    wf["4"]["inputs"].update(width=256, height=256)
    wf["5"]["inputs"].update(steps=1, seed=random.randint(0, 2**32 - 1))
    return wf


# ─────────────────────────── status ───────────────────────────

async def collect_status() -> dict:
    async with httpx.AsyncClient() as c:
        (models, running, comfy_queue, comfy_stats, containers,
         mem_avail, mem_total, gpu_util, gpu_temp, gpu_power, gpu_age) = await asyncio.gather(
            get_json(c, f"{LLAMA_SWAP_URL}/v1/models"),
            get_json(c, f"{LLAMA_SWAP_URL}/running"),
            get_json(c, f"{COMFY_URL}/queue"),
            get_json(c, f"{COMFY_URL}/system_stats"),
            get_json(c, f"{DOCKER_URL}/containers/json", params={"all": "1"}),
            prom_scalar(c, "node_memory_MemAvailable_bytes"),
            prom_scalar(c, "node_memory_MemTotal_bytes"),
            prom_scalar(c, "gb10_gpu_utilization_percent"),
            prom_scalar(c, "gb10_gpu_temperature_celsius"),
            prom_scalar(c, "gb10_gpu_power_watts"),
            prom_scalar(c, "time() - gb10_gpu_collector_timestamp_seconds"),
        )

    run_state = {r.get("model"): r.get("state", "ready") for r in (running or {}).get("running", [])}
    llm = [
        {"id": m["id"], "name": m.get("name") or m["id"], "state": run_state.get(m["id"], "stopped")}
        for m in (models or {}).get("data", [])
    ]

    comfy_busy = bool(comfy_queue and (comfy_queue.get("queue_running") or comfy_queue.get("queue_pending")))
    idle_for = int(time.monotonic() - comfy_state.last_activity)
    image = {
        "reachable": comfy_stats is not None,
        "state": "busy" if comfy_busy else ("unloaded" if comfy_state.freed else "hot"),
        "idle_seconds": idle_for,
        "idle_limit_seconds": COMFY_IDLE_SECONDS,
    }

    services = sorted(
        (
            {
                "name": (ct.get("Names") or ["?"])[0].lstrip("/"),
                "state": ct.get("State"),
                "status": ct.get("Status"),
                "image": ct.get("Image"),
            }
            for ct in (containers or [])
        ),
        key=lambda s: s["name"],
    )
    sandbox = next((s for s in services if NEMOCLAW_SANDBOX in s["name"]), None)

    gib = 1024 ** 3
    return {
        "models": llm,
        "model_runner_reachable": models is not None,
        "image": image,
        "services": services,
        "docker_reachable": containers is not None,
        "sandbox": sandbox,
        "memory": {
            "available_gib": round(mem_avail / gib, 1) if mem_avail else None,
            "total_gib": round(mem_total / gib, 1) if mem_total else None,
            "used_pct": round(100 * (1 - mem_avail / mem_total), 1) if mem_avail and mem_total else None,
        },
        "gpu": {
            "util_pct": gpu_util,
            "temp_c": gpu_temp,
            "power_w": gpu_power,
            "collector_age_s": round(gpu_age) if gpu_age is not None else None,
        },
    }


# ─────────────────────────── background ───────────────────────────

async def free_comfy(client: httpx.AsyncClient) -> None:
    r = await client.post(f"{COMFY_URL}/free", json={"unload_models": True, "free_memory": True}, timeout=30)
    r.raise_for_status()
    # Jobs finished before this point are handled: don't let the idle watcher count them as new activity and flip the state back to "hot".
    history = await get_json(client, f"{COMFY_URL}/history", params={"max_items": "1"})
    if history:
        comfy_state.last_history_id = next(iter(history), comfy_state.last_history_id)
    comfy_state.freed = True


async def comfy_idle_watcher() -> None:
    async with httpx.AsyncClient() as c:
        while True:
            try:
                queue = await get_json(c, f"{COMFY_URL}/queue")
                history = await get_json(c, f"{COMFY_URL}/history", params={"max_items": "1"})
                now = time.monotonic()
                latest = next(iter(history), None) if history else None
                busy = bool(queue and (queue.get("queue_running") or queue.get("queue_pending")))
                if busy or (latest and latest != comfy_state.last_history_id):
                    comfy_state.last_history_id = latest
                    comfy_state.last_activity = now
                    comfy_state.freed = False
                elif not comfy_state.freed and now - comfy_state.last_activity >= COMFY_IDLE_SECONDS:
                    await free_comfy(c)
                    log.info("ComfyUI idle for %ss, models freed", COMFY_IDLE_SECONDS)
            except Exception:
                log.exception("ComfyUI idle watcher iteration failed")
            await asyncio.sleep(60)


async def start_model(model_id: str) -> None:
    async with httpx.AsyncClient() as c:
        try:
            await c.get(f"{LLAMA_SWAP_URL}/upstream/{model_id}/health", timeout=900)
        except httpx.HTTPError:
            log.exception("Starting %s failed", model_id)


async def warm_comfy() -> None:
    async with httpx.AsyncClient() as c:
        try:
            await c.post(f"{COMFY_URL}/prompt", json={"prompt": tiny_workflow()}, timeout=30)
            comfy_state.freed = False
            comfy_state.last_activity = time.monotonic()
        except httpx.HTTPError:
            log.exception("ComfyUI warm-up failed")


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(comfy_idle_watcher())
    yield
    task.cancel()


app = FastAPI(title="GB10 AI Stack", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")
templates = Jinja2Templates(directory=Path(__file__).parent / "templates")


# ─────────────────────────── routes ───────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(request, "index.html", {"who": identity(request)})


@app.get("/partials/status", response_class=HTMLResponse)
async def status_partial(request: Request):
    who = identity(request)
    return templates.TemplateResponse(request, "partials/status.html", {"who": who, "s": await collect_status()})


@app.get("/api/status")
async def api_status(request: Request):
    identity(request)
    return JSONResponse(await collect_status())


@app.post("/api/models/{model_id}/up", response_class=HTMLResponse)
async def model_up(model_id: str, request: Request, tasks: BackgroundTasks):
    require_admin(request)
    if not MODEL_ID.match(model_id):
        raise HTTPException(400, "Invalid model id")
    tasks.add_task(start_model, model_id)
    return await status_partial(request)


@app.post("/api/models/{model_id}/down", response_class=HTMLResponse)
async def model_down(model_id: str, request: Request):
    require_admin(request)
    if not MODEL_ID.match(model_id):
        raise HTTPException(400, "Invalid model id")
    async with httpx.AsyncClient() as c:
        r = await c.post(f"{LLAMA_SWAP_URL}/api/models/unload/{model_id}", timeout=60)
    if r.status_code == 404:
        raise HTTPException(404, f"Unknown model '{model_id}'")
    if r.status_code == 405:
        raise HTTPException(501, "This llama-swap version has no per-model unload endpoint")
    if r.status_code >= 400:
        raise HTTPException(502, f"llama-swap returned {r.status_code}")
    return await status_partial(request)


@app.post("/api/image/warm", response_class=HTMLResponse)
async def image_warm(request: Request, tasks: BackgroundTasks):
    require_admin(request)
    tasks.add_task(warm_comfy)
    return await status_partial(request)


@app.post("/api/image/free", response_class=HTMLResponse)
async def image_free(request: Request):
    require_admin(request)
    async with httpx.AsyncClient() as c:
        try:
            await free_comfy(c)
        except httpx.HTTPError as exc:
            raise HTTPException(502, f"ComfyUI /free failed: {exc}") from exc
    return await status_partial(request)


@app.get("/healthz")
async def healthz():
    return {"ok": True}
