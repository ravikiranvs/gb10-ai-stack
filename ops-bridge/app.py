"""ops-bridge: lets containers run a short, declared list of operations on other containers through the Docker API.

Nothing here is specific to any application. Everything the bridge can do is an *action* in actions.yaml: a name, a target
container, a fixed command, and typed parameters. Callers are *clients* with their own secret and an allow-list of action
names. There is no way to send a command line: parameters are validated against a pattern and passed as separate arguments.
"""

import asyncio
import fnmatch
import hmac
import json
import logging
import os
import re
import struct
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import yaml
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse

CONFIG_PATH = Path(os.environ.get("BRIDGE_CONFIG", "/config/actions.yaml"))
DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
MAX_CONCURRENT = int(os.environ.get("BRIDGE_MAX_CONCURRENT", "4"))
DEFAULT_TIMEOUT = 30
DEFAULT_MAX_OUTPUT = 65536

NAME_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")
PLACEHOLDER_RE = re.compile(r"^\{([a-z][a-z0-9_]*)\}$")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

log = logging.getLogger("ops-bridge")


def audit(**fields) -> None:
    """One JSON line per call on stdout (Alloy ships it to Loki). Never put secrets or sensitive output in here."""
    print(json.dumps({"ts": round(time.time(), 3), "event": "audit", **fields}, separators=(",", ":")), flush=True)


# ─────────────────────────── configuration ───────────────────────────

class ConfigError(Exception):
    pass


def expand_env(value: str) -> str:
    """Replace ${VAR} with the environment value (only in target selectors, so shell scripts keep their own $)."""
    def sub(m):
        if m.group(1) not in os.environ:
            raise ConfigError(f"environment variable {m.group(1)} is not set")
        return os.environ[m.group(1)]
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", sub, value)


def load_config(path: Path) -> dict:
    raw = yaml.safe_load(path.read_text()) or {}
    clients, actions = {}, {}

    for cname, c in (raw.get("clients") or {}).items():
        if not NAME_RE.match(cname):
            raise ConfigError(f"client name {cname!r} is not valid")
        token_file = c.get("token_file")
        if not token_file:
            raise ConfigError(f"client {cname}: token_file is required")
        token = Path(token_file).read_text().strip()
        if len(token) < 24:
            raise ConfigError(f"client {cname}: the secret in {token_file} must be at least 24 characters")
        allow = c.get("allow") or []
        if not allow or not all(isinstance(a, str) for a in allow):
            raise ConfigError(f"client {cname}: allow must be a non-empty list of action names or globs")
        clients[cname] = {"token": token, "allow": allow}

    for aname, a in (raw.get("actions") or {}).items():
        if not NAME_RE.match(aname):
            raise ConfigError(f"action name {aname!r} is not valid")
        kind = a.get("kind", "exec")
        if kind not in ("exec", "restart", "logs"):
            raise ConfigError(f"action {aname}: unknown kind {kind!r}")
        target = a.get("target") or {}
        if bool(target.get("name")) == bool(target.get("label")):
            raise ConfigError(f"action {aname}: target needs exactly one of name (a regex) or label (key=value)")
        sel = {"name": expand_env(target["name"])} if target.get("name") else {"label": expand_env(target["label"])}
        if "name" in sel:
            re.compile(sel["name"])

        params = {}
        for pname, p in (a.get("params") or {}).items():
            if not re.match(r"^[a-z][a-z0-9_]*$", pname):
                raise ConfigError(f"action {aname}: parameter name {pname!r} is not valid")
            pattern = p.get("pattern")
            if not pattern:
                raise ConfigError(f"action {aname}: parameter {pname} needs a pattern")
            params[pname] = {"pattern": re.compile(pattern), "max_length": int(p.get("max_length", 256)),
                             "default": p.get("default")}

        action = {"kind": kind, "target": sel, "params": params, "description": a.get("description", ""),
                  "sensitive": bool(a.get("sensitive", False)), "timeout": int(a.get("timeout", DEFAULT_TIMEOUT)),
                  "max_output": int(a.get("max_output", DEFAULT_MAX_OUTPUT)), "output": a.get("output", "text")}
        if action["output"] not in ("text", "json"):
            raise ConfigError(f"action {aname}: output must be text or json")

        if kind == "exec":
            argv = a.get("argv")
            if not argv or not all(isinstance(x, str) for x in argv):
                raise ConfigError(f"action {aname}: argv must be a non-empty list of strings")
            used = set()
            for el in argv:
                m = PLACEHOLDER_RE.match(el)
                if m:
                    if m.group(1) not in params:
                        raise ConfigError(f"action {aname}: argv uses {{{m.group(1)}}} but no such parameter is declared")
                    used.add(m.group(1))
            if used != set(params):
                raise ConfigError(f"action {aname}: parameters {sorted(set(params) - used)} are declared but never used in argv")
            ex = a.get("exec") or {}
            for k in (ex.get("env") or {}):
                if not ENV_NAME_RE.match(k):
                    raise ConfigError(f"action {aname}: bad environment variable name {k!r}")
            for k, src in (ex.get("env_from_json_file") or {}).items():
                if not ENV_NAME_RE.match(k) or not src.get("file") or not src.get("key"):
                    raise ConfigError(f"action {aname}: env_from_json_file.{k} needs file and key")
            action["argv"] = argv
            action["exec"] = {"user": ex.get("user"), "run_as": ex.get("run_as"), "env": ex.get("env") or {},
                              "env_from_json_file": ex.get("env_from_json_file") or {},
                              "netns_of_process": (ex.get("netns_of_process") or {}).get("argv0")}
        elif params:
            raise ConfigError(f"action {aname}: only exec actions take parameters")
        if kind == "logs":
            action["tail"] = int(a.get("tail", 200))
        actions[aname] = action

    for cname, c in clients.items():
        for pat in c["allow"]:
            if not any(fnmatch.fnmatchcase(n, pat) for n in actions):
                raise ConfigError(f"client {cname}: allow pattern {pat!r} matches no action")
    return {"clients": clients, "actions": actions}


# ─────────────────────────── Docker API ───────────────────────────

# Runs inside the target container (python3 is needed there). It builds the final command from one JSON argument, so nothing is
# ever interpolated into a shell string. It can read env values from JSON files, enter the network namespace of a named
# process (needed for processes that live in a nested namespace, such as the OpenShell sandbox) and switch to another user.
WRAPPER = r"""
import json, os, pwd, sys
spec = json.loads(sys.argv[1])
env = dict(os.environ)
env.update(spec.get("env") or {})
for name, src in (spec.get("env_from_json_file") or {}).items():
    cur = json.load(open(src["file"]))
    for part in src["key"].split("."):
        cur = cur[part]
    env[name] = str(cur)
cmd = spec["cmd"]
uid = gid = None
if spec.get("run_as"):
    pw = pwd.getpwnam(spec["run_as"])
    uid, gid = pw.pw_uid, pw.pw_gid
ns = spec.get("netns_of_process")
if ns:
    pid = None
    me = os.getpid()
    for d in os.listdir("/proc"):
        if d.isdigit() and int(d) != me:
            try:
                argv0 = open(f"/proc/{d}/cmdline", "rb").read().split(b"\0")[0].decode(errors="replace")
            except OSError:
                continue
            if argv0 == ns:
                pid = d
                break
    if pid is None:
        sys.stderr.write(f"no process named {ns} in the target container\n")
        sys.exit(125)
    pre = ["nsenter", "-t", pid, "-n"]
    if uid is not None:
        pre += ["-S", str(uid), "-G", str(gid)]
    cmd = pre + ["--"] + cmd
elif uid is not None:
    os.setgroups([]); os.setgid(gid); os.setuid(uid)
os.execvpe(cmd[0], cmd, env)
"""


class Docker:
    def __init__(self) -> None:
        self.client = httpx.AsyncClient(transport=httpx.AsyncHTTPTransport(uds=DOCKER_SOCKET),
                                        base_url="http://docker", timeout=httpx.Timeout(10.0, read=None))

    async def resolve(self, target: dict) -> str:
        if "label" in target:
            filters = {"status": ["running"], "label": [target["label"]]}
        else:
            filters = {"status": ["running"]}
        r = await self.client.get("/containers/json", params={"filters": json.dumps(filters)})
        r.raise_for_status()
        found = []
        for c in r.json():
            names = [n.lstrip("/") for n in c.get("Names", [])]
            if "label" in target or any(re.search(target["name"], n) for n in names):
                found.append((c["Id"], names[0] if names else c["Id"][:12]))
        if len(found) != 1:
            raise HTTPException(409, f"target selects {len(found)} running containers, expected exactly 1")
        return found[0][0]

    @staticmethod
    def demux(data: bytes) -> tuple[bytes, bytes]:
        out, err, i = bytearray(), bytearray(), 0
        while i + 8 <= len(data):
            stream, size = data[i], struct.unpack(">I", data[i + 4:i + 8])[0]
            chunk = data[i + 8:i + 8 + size]
            (out if stream == 1 else err).extend(chunk)
            i += 8 + size
        return bytes(out), bytes(err)

    async def exec(self, cid: str, cmd: list[str], user: str | None, timeout: int, cap: int) -> dict:
        body = {"AttachStdout": True, "AttachStderr": True, "Tty": False, "Cmd": cmd}
        if user:
            body["User"] = user
        r = await self.client.post(f"/containers/{cid}/exec", json=body)
        r.raise_for_status()
        eid = r.json()["Id"]
        data = bytearray()
        async def run():
            async with self.client.stream("POST", f"/exec/{eid}/start", json={"Detach": False, "Tty": False}) as resp:
                resp.raise_for_status()
                async for chunk in resp.aiter_raw():
                    if len(data) < cap * 4:
                        data.extend(chunk)
        try:
            await asyncio.wait_for(run(), timeout)
        except asyncio.TimeoutError:
            raise HTTPException(504, f"the operation did not finish within {timeout}s")
        info = (await self.client.get(f"/exec/{eid}/json")).json()
        out, err = self.demux(bytes(data))
        return {"exit_code": info.get("ExitCode"), "stdout": out, "stderr": err}


# ─────────────────────────── request handling ───────────────────────────

STATE: dict = {}
SEM = asyncio.Semaphore(MAX_CONCURRENT)


@asynccontextmanager
async def lifespan(_: FastAPI):
    try:
        STATE["config"] = load_config(CONFIG_PATH)
    except (ConfigError, OSError, yaml.YAMLError, re.error) as exc:
        print(f"ops-bridge: configuration error: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
    STATE["docker"] = Docker()
    cfg = STATE["config"]
    audit(msg="started", clients=sorted(cfg["clients"]), actions=sorted(cfg["actions"]))
    yield
    await STATE["docker"].client.aclose()


app = FastAPI(title="ops-bridge", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)


def authenticate(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    presented = authorization[7:].strip().encode()
    match = None
    for name, c in STATE["config"]["clients"].items():   # compare against every client so timing does not reveal which exists
        if hmac.compare_digest(presented, c["token"].encode()):
            match = name
    if match is None:
        raise HTTPException(401, "unknown token")
    return match


def allowed(client: str, action: str) -> bool:
    return any(fnmatch.fnmatchcase(action, p) for p in STATE["config"]["clients"][client]["allow"])


def bind_params(action: dict, supplied: dict) -> dict:
    out = {}
    unknown = set(supplied) - set(action["params"])
    if unknown:
        raise HTTPException(422, f"unknown parameters: {sorted(unknown)}")
    for name, spec in action["params"].items():
        value = supplied.get(name, spec["default"])
        if not isinstance(value, str):
            raise HTTPException(422, f"parameter {name} is required and must be a string")
        if len(value) > spec["max_length"] or not spec["pattern"].fullmatch(value):
            raise HTTPException(422, f"parameter {name} does not match the allowed pattern")
        out[name] = value
    return out


def build_exec(action: dict, params: dict) -> tuple[list[str], str | None]:
    argv = [params[PLACEHOLDER_RE.match(el).group(1)] if PLACEHOLDER_RE.match(el) else el for el in action["argv"]]
    ex = action["exec"]
    if ex["run_as"] or ex["netns_of_process"] or ex["env_from_json_file"]:
        spec = {"cmd": argv, "env": ex["env"], "env_from_json_file": ex["env_from_json_file"],
                "run_as": ex["run_as"], "netns_of_process": ex["netns_of_process"]}
        return ["python3", "-c", WRAPPER, json.dumps(spec)], ex["user"]
    if ex["env"]:
        argv = ["env", *[f"{k}={v}" for k, v in ex["env"].items()], *argv]
    return argv, ex["user"]


def trim(raw: bytes, cap: int) -> tuple[str, bool]:
    return raw[:cap].decode(errors="replace"), len(raw) > cap


def extract_json(text: str):
    dec = json.JSONDecoder()
    for m in re.finditer(r"^[\[{]", text, re.M):
        try:
            return dec.raw_decode(text[m.start():])[0]
        except ValueError:
            continue
    return None


@app.get("/healthz")
async def healthz():
    return {"ok": True}


@app.get("/v1/actions")
async def list_actions(authorization: str | None = Header(default=None)):
    client = authenticate(authorization)
    out = {}
    for name, a in STATE["config"]["actions"].items():
        if allowed(client, name):
            out[name] = {"kind": a["kind"], "description": a["description"], "sensitive": a["sensitive"],
                         "params": {p: s["pattern"].pattern for p, s in a["params"].items()}}
    return {"client": client, "actions": out}


@app.post("/v1/actions/{name}")
async def run_action(name: str, body: dict | None = None, authorization: str | None = Header(default=None)):
    client = authenticate(authorization)
    action = STATE["config"]["actions"].get(name)
    if action is None or not allowed(client, name):
        # the same answer for "does not exist" and "not yours", so a client cannot probe the catalogue
        audit(client=client, action=name, result="denied")
        raise HTTPException(403, "unknown action or not allowed")
    started = time.monotonic()
    supplied = (body or {}).get("params") or {}
    try:
        if not isinstance(supplied, dict):
            raise HTTPException(422, "params must be an object")
        params = bind_params(action, supplied)
        async with SEM:
            docker: Docker = STATE["docker"]
            cid = await docker.resolve(action["target"])
            if action["kind"] == "exec":
                cmd, user = build_exec(action, params)
                res = await docker.exec(cid, cmd, user, action["timeout"], action["max_output"])
                stdout, t1 = trim(res["stdout"], action["max_output"])
                stderr, t2 = trim(res["stderr"], action["max_output"])
                result = {"ok": res["exit_code"] == 0, "exit_code": res["exit_code"], "stdout": stdout, "stderr": stderr,
                          "truncated": t1 or t2}
                if action["output"] == "json":
                    result["json"] = extract_json(stdout)
            elif action["kind"] == "restart":
                r = await docker.client.post(f"/containers/{cid}/restart", params={"t": 10})
                result = {"ok": r.status_code == 204, "exit_code": 0 if r.status_code == 204 else 1, "stdout": "", "stderr": "",
                          "truncated": False}
            else:
                r = await docker.client.get(f"/containers/{cid}/logs", params={"stdout": 1, "stderr": 1, "timestamps": 1,
                                                                                "tail": action["tail"]})
                out, err = Docker.demux(r.content)
                text, trunc = trim(out + err, action["max_output"])
                result = {"ok": r.status_code == 200, "exit_code": 0, "stdout": text, "stderr": "", "truncated": trunc}
    except HTTPException as exc:
        audit(client=client, action=name, result="error", status=exc.status_code, detail=exc.detail,
              ms=round((time.monotonic() - started) * 1000))
        raise
    result["duration_ms"] = round((time.monotonic() - started) * 1000)
    fields = {"client": client, "action": name, "result": "ok" if result["ok"] else "failed",
              "exit_code": result["exit_code"], "ms": result["duration_ms"]}
    if not action["sensitive"]:
        fields["params"] = params
    audit(**fields)
    return JSONResponse(result)
