"""Temporary sudo for admins: the dashboard side. Talks to the root daemon gb10-elevated (host/gb10-elevated) over a Unix socket that only this
container's user can open. The dashboard decides nothing: the daemon checks again that the name is an enabled admin with a browser-terminal
account, and writes the audit log. Authelia's two-factor sign-in is the authentication."""

import asyncio
import json
import os
from collections.abc import AsyncIterator

SOCK = os.environ.get("ELEVATE_SOCK", "/run/gb10-elevate/web.sock")


class ElevateError(Exception):
    pass


async def _open(op: str, **fields):
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(SOCK), 5)
    except (OSError, asyncio.TimeoutError) as exc:
        raise ElevateError("the elevation service is not running on the machine (sudo bash host/elevate-setup.sh)") from exc
    writer.write(json.dumps({"op": op, **fields}).encode() + b"\n")
    await writer.drain()
    return reader, writer


async def call(op: str, **fields) -> dict:
    reader, writer = await _open(op, **fields)
    try:
        r = json.loads(await asyncio.wait_for(reader.readline(), 30) or b"{}")
    finally:
        writer.close()
    if not r.get("ok"):
        raise ElevateError(r.get("error") or "the elevation service gave no answer")
    return r


async def export(user: str, kind: str, sid: str | None = None) -> AsyncIterator[bytes]:
    """Yields the .tar.gz; raises ElevateError before the first byte when the daemon refuses."""
    reader, writer = await _open("export", user=user, kind=kind, id=sid)
    head = json.loads(await asyncio.wait_for(reader.readline(), 60) or b"{}")
    if not head.get("ok"):
        writer.close()
        raise ElevateError(head.get("error") or "export failed")

    async def body() -> AsyncIterator[bytes]:
        try:
            while chunk := await reader.read(65536):
                yield chunk
        finally:
            writer.close()
    return body()
