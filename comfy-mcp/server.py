"""MCP server exposing ComfyUI image generation over streamable HTTP."""

import asyncio
import json
import os
import random
import time
import uuid
from pathlib import Path

import httpx
from mcp.server.fastmcp import FastMCP, Image

COMFY_URL = os.environ.get("COMFY_URL", "http://comfyui:8188")
WORKFLOW_PATH = Path(os.environ.get("COMFY_WORKFLOW", "/app/workflows/flux-schnell-api.json"))
DEFAULT_STEPS = int(os.environ.get("COMFY_DEFAULT_STEPS", "4"))
TIMEOUT_SECONDS = int(os.environ.get("COMFY_TIMEOUT_SECONDS", "600"))
HOST, PORT = os.environ.get("MCP_BIND", "0.0.0.0:9100").rsplit(":", 1)

# Node ids in the API-format workflow
NODE_CHECKPOINT, NODE_POSITIVE, NODE_NEGATIVE, NODE_LATENT, NODE_SAMPLER, NODE_SAVE = "1", "2", "3", "4", "5", "7"

mcp = FastMCP("comfy-image", host=HOST, port=int(PORT))


def _dimension(value: int) -> int:
    return max(256, min(2048, value // 16 * 16))


def build_workflow(prompt: str, negative: str, width: int, height: int, steps: int, seed: int,
                   checkpoint: str | None) -> dict:
    wf = json.loads(WORKFLOW_PATH.read_text())
    wf[NODE_POSITIVE]["inputs"]["text"] = prompt
    wf[NODE_NEGATIVE]["inputs"]["text"] = negative
    wf[NODE_LATENT]["inputs"].update(width=_dimension(width), height=_dimension(height))
    wf[NODE_SAMPLER]["inputs"].update(steps=max(1, min(50, steps)), seed=seed)
    if checkpoint:
        wf[NODE_CHECKPOINT]["inputs"]["ckpt_name"] = checkpoint
    return wf


async def run_workflow(wf: dict) -> bytes:
    async with httpx.AsyncClient(base_url=COMFY_URL, timeout=30) as client:
        r = await client.post("/prompt", json={"prompt": wf, "client_id": str(uuid.uuid4())})
        if r.status_code >= 400:
            raise RuntimeError(f"ComfyUI rejected workflow: {r.text[:500]}")
        prompt_id = r.json()["prompt_id"]

        deadline = time.monotonic() + TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            history = (await client.get(f"/history/{prompt_id}")).json()
            entry = history.get(prompt_id)
            if entry:
                status = entry.get("status", {})
                if status.get("status_str") == "error":
                    raise RuntimeError(f"ComfyUI execution failed: {json.dumps(status.get('messages', []))[:500]}")
                images = entry.get("outputs", {}).get(NODE_SAVE, {}).get("images", [])
                if images:
                    img = images[0]
                    view = await client.get("/view", params={
                        "filename": img["filename"],
                        "subfolder": img.get("subfolder", ""),
                        "type": img.get("type", "output"),
                    })
                    view.raise_for_status()
                    return view.content
                if status.get("completed"):
                    raise RuntimeError("Workflow completed without an image output")
            await asyncio.sleep(1)
    raise TimeoutError(f"Image generation exceeded {TIMEOUT_SECONDS}s")


@mcp.tool()
async def generate_image(prompt: str, negative: str = "", width: int = 1024, height: int = 1024,
                         steps: int | None = None, seed: int | None = None,
                         checkpoint: str | None = None) -> list:
    """Generate an image from a text prompt with the local ComfyUI FLUX workflow.

    Args:
        prompt: What to draw.
        negative: Things to avoid (often ignored by FLUX schnell).
        width: Output width in pixels (256-2048, rounded to a multiple of 16).
        height: Output height in pixels (256-2048, rounded to a multiple of 16).
        steps: Sampler steps (default from COMFY_DEFAULT_STEPS).
        seed: Random seed for reproducibility.
        checkpoint: Optional checkpoint filename from list_checkpoints.
    """
    seed = seed if seed is not None else random.randint(0, 2**32 - 1)
    wf = build_workflow(prompt, negative, width, height, steps or DEFAULT_STEPS, seed, checkpoint)
    started = time.monotonic()
    png = await run_workflow(wf)
    meta = {
        "seed": seed,
        "width": wf[NODE_LATENT]["inputs"]["width"],
        "height": wf[NODE_LATENT]["inputs"]["height"],
        "steps": wf[NODE_SAMPLER]["inputs"]["steps"],
        "elapsed_s": round(time.monotonic() - started, 2),
    }
    return [Image(data=png, format="png"), json.dumps(meta)]


@mcp.tool()
async def list_checkpoints() -> list[str]:
    """List checkpoint files available to ComfyUI."""
    async with httpx.AsyncClient(base_url=COMFY_URL, timeout=10) as client:
        r = await client.get("/models/checkpoints")
        r.raise_for_status()
        return r.json()


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
