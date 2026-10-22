# GB10 Agent Stack — v2

> **NemoClaw · OpenClaw · OpenShell** on a single **NVIDIA GB10** (DGX Spark class · 128 GB unified memory · arm64 · DGX OS / Ubuntu 24.04).
> **One public HTTPS port** via Tailscale Funnel → **one reverse proxy** → **path-based routing** → **every route authenticated**.
> Everything that runs as a service is a **container**.

---

## Table of contents

1. [What changed from v1](#1-what-changed-from-v1)
2. [At a glance](#2-at-a-glance)
3. [Architecture](#3-architecture)
4. [Path routing (single port)](#4-path-routing-single-port)
5. [Authentication](#5-authentication)
6. [LLM gateway](#6-llm-gateway)
7. [Containerisation decisions](#7-containerisation-decisions)
8. [Container inventory & networks](#8-container-inventory--networks)
9. [Monitoring & observability](#9-monitoring--observability)
10. [Memory budget](#10-memory-budget)
11. [Model lifecycle (scale-to-zero)](#11-model-lifecycle-scale-to-zero)
12. [Request flows](#12-request-flows)
13. [Configuration](#13-configuration)
14. [Admin dashboard](#14-admin-dashboard)
15. [MCPs & Skills](#15-mcps--skills)
16. [Security model](#16-security-model)
17. [Bring-up runbook](#17-bring-up-runbook)
18. [Verification checklist](#18-verification-checklist)
19. [Open items to verify](#19-open-items-to-verify)

---

## 1. What changed from v1

| Area | v1 | **v2** |
|---|---|---|
| Exposure | Tailnet-only, 3 ports | **Public via Tailscale Funnel, single port 443** |
| Routing | Mixed ports + paths | **Pure path-based** behind Caddy |
| Auth | Tailscale identity headers | **Authelia SSO + 2FA** (forward-auth) for humans, **LiteLLM virtual keys** for machines. OpenClaw additionally needs its own gateway token (SSO into OpenClaw is not possible with NemoClaw 0.0.137, §5) |
| Model API | llama-swap exposed directly | **LiteLLM gateway** → llama-swap → vLLM |
| llama-swap | Host systemd, spawning `docker run` | **Container** — llama-swap baked into the vLLM image, spawns `vllm serve` as child processes |
| Dashboard | Host systemd | **Container** + read-only docker-socket-proxy |
| OpenShell gateway | Host process | **Created and managed by NemoClaw** (not in compose; NemoClaw supports an external gateway only under systemd on `127.0.0.1`) |
| Monitoring | none | **Grafana · Prometheus · Loki · Tempo · Alloy** + GB10-aware GPU exporter + OpenClaw/LiteLLM/vLLM OTel traces |

---

## 2. At a glance

| Layer | Choice | Notes |
|---|---|---|
| Ingress / TLS | **Tailscale Funnel** `:443` | Public HTTPS on `gb10.<tailnet>.ts.net`; TLS terminated by Tailscale |
| Reverse proxy | **Caddy** `127.0.0.1:9080` | Plain HTTP, path routing, forward-auth |
| Identity | **Authelia** | File users, TOTP / WebAuthn (passkeys), brute-force regulation, default-deny ACL |
| LLM gateway | **LiteLLM Proxy** + Postgres | Virtual keys, budgets, rate limits, fallbacks, Prometheus + OTel, MCP gateway |
| Model runner | **llama-swap + vLLM** (one container) | Spawns/kills `vllm serve` per model on demand |
| Agent LLM | `nvidia/Qwen3.6-35B-A3B-NVFP4` | NVIDIA's DGX Spark default for OpenClaw. Kept loaded (`ttl: 0` + preload at start), 131072-token context |
| Vision | The agent model itself (Qwen3.6-35B-A3B is natively multimodal; there is no separate vision model) | Tested: accepts images |
| Image gen | **ComfyUI** + FLUX.1-schnell (fp8 checkpoint), **comfy-mcp** | The agent gets a link to the picture, not the bytes (§15) |
| Agent | **OpenClaw** in an **OpenShell** sandbox, onboarded by **NemoClaw** | |
| Admin | **admin-dashboard** (FastAPI + HTMX) | Status, Up/Down, idle unloader |
| Observability | **Alloy → Prometheus / Loki / Tempo → Grafana** | GPU via `nvidia-smi` textfile (DCGM is broken on GB10) |

---

## 3. Architecture

```mermaid
flowchart TB
    INET["Internet clients<br/>browser · phone · API scripts"]

    subgraph HOST["GB10 host · DGX OS · arm64 · 128 GB unified"]
        direction TB

        TSD["tailscaled · Funnel :443<br/>TLS termination"]

        subgraph EDGE["Edge"]
            CADDY["caddy · host network<br/>127.0.0.1:9080<br/>path router + forward_auth"]
            AUTH["authelia<br/>/auth · SSO + 2FA"]
        end

        subgraph APPS["Apps"]
            DASH["admin-dashboard<br/>/admin"]
            GRAF["grafana<br/>/grafana"]
            COMFY["comfyui<br/>/comfy"]
            OC["OpenClaw Control UI<br/>/openclaw · gateway token<br/>sandbox forward :18789"]
        end

        subgraph GW["LLM gateway"]
            LITE["litellm<br/>/llm · /llm/v1<br/>keys · budgets · MCP gateway"]
            PG[("litellm-db<br/>postgres")]
        end

        subgraph MODELS["Model runner · single container"]
            LS["llama-swap :8000"]
            VA["vllm serve · agent<br/>:10001"]
        end

        subgraph IMG["Image generation"]
            CMCP["comfy-mcp :9100"]
        end

        subgraph AGENT["Agent runtime"]
            OSG["OpenShell gateway<br/>NemoClaw-managed"]
            SBX["OpenShell sandbox<br/>OpenClaw · Landlock · seccomp · netns"]
        end

        subgraph OBS["Observability"]
            ALLOY["alloy<br/>OTLP :4317/:4318 · docker logs"]
            PROM["prometheus"]
            LOKI["loki"]
            TEMPO["tempo"]
            EXP["node-exporter · cadvisor<br/>gpu-exporter"]
        end
    end

    INET -- "HTTPS :443" --> TSD
    TSD -- "HTTP" --> CADDY
    CADDY -. "forward_auth" .-> AUTH
    CADDY --> DASH
    CADDY --> GRAF
    CADDY --> COMFY
    CADDY --> OC
    CADDY -- "/llm/v1 · Bearer key" --> LITE

    OC --- SBX
    OSG -- "creates / polices" --> SBX
    SBX -- "inference · via OpenShell · virtual key" --> LITE
    SBX -- "MCP · HTTPS 172.17.0.1:8443" --> CADDY
    CADDY -- "/llm/*/mcp · key-only" --> LITE
    LITE --> PG
    LITE -- "OpenAI API" --> LS
    LITE -- "MCP" --> CMCP
    LS -- "spawn · proxy · ttl kill" --> VA
    CMCP --> COMFY

    DASH --> LS
    DASH --> COMFY

    SBX -- "OTLP" --> ALLOY
    LITE -- "OTLP" --> ALLOY
    VA -- "OTLP" --> ALLOY
    ALLOY --> PROM
    ALLOY --> LOKI
    ALLOY --> TEMPO
    EXP --> PROM
    PROM -- "scrape /metrics" --> LITE
    PROM -- "scrape /metrics" --> VA
    GRAF --> PROM
    GRAF --> LOKI
    GRAF --> TEMPO

    classDef inet fill:#111827,stroke:#f9fafb,color:#f9fafb,stroke-width:2px
    classDef edge fill:#0f172a,stroke:#38bdf8,color:#e0f2fe,stroke-width:2px
    classDef app fill:#1e1b4b,stroke:#a78bfa,color:#ede9fe,stroke-width:2px
    classDef gw fill:#3b0764,stroke:#e879f9,color:#fae8ff,stroke-width:2px
    classDef model fill:#431407,stroke:#fb923c,color:#ffedd5,stroke-width:2px
    classDef agent fill:#052e16,stroke:#4ade80,color:#dcfce7,stroke-width:2px
    classDef obs fill:#082f49,stroke:#22d3ee,color:#cffafe,stroke-width:2px

    class INET inet
    class TSD,CADDY,AUTH edge
    class DASH,GRAF,COMFY,OC app
    class LITE,PG gw
    class LS,VA,CMCP model
    class OSG,SBX agent
    class ALLOY,PROM,LOKI,TEMPO,EXP obs
```

---

## 4. Path routing (single port)

**Public URL:** `https://gb10.<tailnet>.ts.net` (Funnel `:443` → Caddy `127.0.0.1:9080`)

| Path | Upstream | Auth | Prefix handling | Sub-path support |
|---|---|---|---|---|
| `/` and any unmatched path | 302 redirect → `/admin/` | — | — | — |
| `/auth/*` | authelia `127.0.0.1:9091` | public (login portal) | kept · `server.address: …/auth` | native |
| `/admin/*` | admin-dashboard `127.0.0.1:9000` | Authelia · `admins` · 2FA | stripped · `uvicorn --root-path /admin` | native |
| `/openclaw/*` | OpenClaw `127.0.0.1:18789` (NemoClaw port forward) | Authelia · 2FA, then the OpenClaw **gateway token** + a paired device | kept · `gateway.controlUi.basePath: "/openclaw"` | native |
| `/llm/v1/*` | litellm `127.0.0.1:4000` | **LiteLLM virtual key** (Bearer); Authelia rule is `bypass`, Caddy strips `Remote-*` | kept · `SERVER_ROOT_PATH=/llm` | native |
| `/llm/<server>/mcp` | **not public.** On the public site it falls under `/llm*` (Authelia). The sandbox uses Caddy's second listener `https://172.17.0.1:8443/llm/<server>/mcp`: **LiteLLM virtual key** (Bearer, per-key MCP grants), Caddy strips `Remote-*`, everything else on that port is 404 | key | kept | native |
| `/llm/*` (UI) | litellm `127.0.0.1:4000` | Authelia · `admins` · 2FA + LiteLLM login | kept | native |
| `/grafana/*` | grafana `127.0.0.1:3000` | Authelia · `admins` → Grafana auth-proxy | kept · `serve_from_sub_path = true` | native |
| `/comfy/*` | comfyui `127.0.0.1:8188` | Authelia · `admins` · 2FA | stripped | **fragile** — see note |

```mermaid
flowchart LR
    F["Funnel :443"] --> C{"Caddy<br/>127.0.0.1:9080"}
    C -- "/auth" --> A["authelia"]
    C -- "/admin" --> FA1(["forward_auth"]) --> D["dashboard"]
    C -- "/openclaw" --> FA2(["forward_auth"]) --> O["openclaw"]
    C -- "/llm/v1" --> K(["Bearer key"]) --> L["litellm"]
    C -- "/llm" --> FA3(["forward_auth"]) --> L
    C -- "/grafana" --> FA4(["forward_auth"]) --> G["grafana"]
    C -- "/comfy" --> FA5(["forward_auth"]) --> CU["comfyui"]

    classDef r fill:#0f172a,stroke:#38bdf8,color:#e0f2fe,stroke-width:2px
    classDef a fill:#7c2d12,stroke:#fdba74,color:#ffedd5
    classDef s fill:#1e1b4b,stroke:#a78bfa,color:#ede9fe
    class F,C r
    class FA1,FA2,FA3,FA4,FA5,K a
    class A,D,O,L,G,CU s
```

> **ComfyUI under `/comfy/`:** ComfyUI has open issues where parts of the frontend build absolute URLs (`/api/view`, `/view`) and some frontend releases break sub-path routing entirely. Mitigations, in order:
> 1. Pin a ComfyUI frontend version you have tested under `/comfy/`.
> 2. Keep image generation agent-driven (OpenClaw → MCP → ComfyUI) and treat the ComfyUI UI as a power-user tool.
> 3. If it keeps breaking, expose it on Funnel `:8443` or keep it tailnet-only — the only exception to the single-port rule.

---

## 5. Authentication

### Model

| Client type | Mechanism | Where enforced |
|---|---|---|
| Humans (browser) | **Authelia** session cookie, password + **TOTP / WebAuthn** | Caddy `forward_auth` on every UI path |
| OpenClaw UI | Authelia (password + 2FA) gates the URL; the browser then presents the OpenClaw **gateway token** (once per browser) and needs a **paired device** | Caddy + OpenClaw gateway |
| Grafana | Authelia → `Remote-User` header → Grafana **auth.proxy** | Caddy + Grafana |
| API scripts / laptop | **LiteLLM virtual key** (`Authorization: Bearer sk-…`) | LiteLLM |
| OpenClaw sandbox → models/MCP | LiteLLM virtual key (`openclaw-sandbox`) held in the **OpenShell credential store** (never in the sandbox); inference goes sandbox → `inference.local` → OpenShell → LiteLLM, MCP goes through the OpenShell MCP proxy to Caddy's bridge listener | OpenShell + Caddy + LiteLLM |
| Internal service ↔ service | Docker network isolation, no host publish | Docker |

### Login flow

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant F as Tailscale Funnel
    participant C as Caddy
    participant A as Authelia
    participant S as Upstream app

    U->>F: GET /grafana/
    F->>C: HTTP 127.0.0.1:9080
    C->>A: forward_auth /auth/api/authz/forward-auth
    A-->>C: 302 → /auth/?rd=...
    C-->>U: redirect to login
    U->>C: POST /auth/ credentials + TOTP or passkey
    C->>A: proxied
    A-->>U: Set-Cookie authelia_session · redirect back
    U->>C: GET /grafana/ with cookie
    C->>A: forward_auth
    A-->>C: 200 · Remote-User · Remote-Groups · Remote-Email
    C->>S: request + identity headers
    S-->>U: page
```

### OpenClaw login (token mode)

NemoClaw's start script writes the gateway token into `openclaw.json` every time the sandbox container starts, and OpenClaw refuses `trusted-proxy` auth while a token exists. So Authelia SSO cannot sign you into OpenClaw (this was tried: the container then exits at start). What works:

1. Sign in through Authelia, open `https://<PUBLIC_HOST>/openclaw/`.
2. Paste the gateway token (`nemoclaw <sandbox> dashboard-url --quiet` prints a URL containing `token=…`; treat it like a password), or open the URL with `#token=…` on the public host.
3. The first connection from a browser creates a pairing request. Approve it in a sandbox shell (`nemoclaw <sandbox> connect`): `openclaw devices list`, then `openclaw devices approve <request-id> --token "$TOKEN"` (read the token with `read -rs TOKEN`; `openclaw gateway auth-token --show` refuses to print into a captured variable). The CLI's own `operator.admin` scope upgrade has to be approved first. Or turn the check off (`VARIABLES.md`, `openclaw/openclaw.patch.json5`: `dangerouslyDisableDeviceAuth`, a security trade-off).

### Groups & policy

| Group | Access |
|---|---|
| `admins` | Everything (`/admin`, `/grafana`, `/comfy`, `/llm` UI, `/openclaw`) |
| `users` | `/openclaw` only (`two_factor`) |
| everyone else | **deny** (`default_policy: deny`) |

Session: 12 h expiry, 1 h inactivity; cookie scoped to `PUBLIC_HOST`; the notifier writes to a file in `/data` (no SMTP), so TOTP/WebAuthn enrolment links are read from `notification.txt`. Both TOTP and passkeys are accepted as the second factor (passkeys are second-factor only; `enable_passkey_login` is not set), and `users.yml` is mounted read-write so password changes can be saved. Grafana auto-signs-up proxy users with the **Admin** org role (only `admins` can reach it) and trusts the proxy header only from `172.16.0.0/12` and `127.0.0.1`.

**Recovery (admin, on the server; no email).** If a user loses every second factor, delete them and let the user re-enrol:

```bash
docker compose exec authelia authelia storage user totp delete <username> --config /config/configuration.yml
docker compose exec authelia authelia storage user webauthn delete <username> --all --config /config/configuration.yml
```

The user then signs in with their password and enrols again; the verification link is in `/data/notification.txt` inside the Authelia container (`docker compose exec authelia cat /data/notification.txt`). A forgotten password is reset by writing a new argon2 hash into `authelia/users.yml`. Users should enrol two second factors so this stays rare.

---

## 6. LLM gateway

**LiteLLM Proxy** sits between every consumer and the local models.

| Capability | Use here |
|---|---|
| OpenAI-compatible API | Single base URL `https://gb10…/llm/v1` for everything |
| Virtual keys | `openclaw-sandbox` (agent, qwen3.6-35b · 60 RPM), `laptop` (any model · 30 RPM · $50 / 30 d), `scripts` (`agent` only · 10 RPM) — created by `scripts/create-litellm-keys.sh` |
| Budgets & rate limits | RPM caps on all three keys, a budget on `laptop`; protects the box from runaway agents |
| Model aliases & retries | `agent` → `qwen3.6-35b`; `num_retries: 1`; `drop_params: true`. **No fallbacks are configured** (a cloud fallback would be an addition) |
| Timeouts | 900 s to cover vLLM cold starts |
| Observability | Prometheus `/metrics` (latency, TTFT, tokens, spend per key) + **OTel traces** |
| **MCP gateway** | Fronts `comfy-mcp` (`comfy_image`, the only MCP server configured). With `SERVER_ROOT_PATH=/llm` the MCP URL is `/llm/comfy_image/mcp` (not `/llm/mcp/`, which LiteLLM reads as a server named `llm`); the sandbox reaches it through Caddy's HTTPS listener on `172.17.0.1:8443`; tools are named `<server>-<tool>`, e.g. `comfy_image-generate_image`. Keys have **no** MCP access by default; `create-litellm-keys.sh` grants all configured servers to `openclaw-sandbox` only |
| Admin UI | `/llm/ui` — keys, usage, logs (served under `SERVER_ROOT_PATH=/llm`; master key and DB URL come from `secrets/litellm.env`) |

```mermaid
flowchart LR
    OC["OpenClaw sandbox<br/>key: openclaw-sandbox"] --> L
    LP["Laptop / scripts<br/>key: laptop · scripts"] --> L
    L["LiteLLM<br/>auth · budgets · routing<br/>retries · timeouts"]
    L -- "agent / qwen3.6-35b" --> LS["llama-swap"]
    L -- "MCP comfy_image" --> M["comfy-mcp"]
    L -. "not configured" .-> CLOUD["Cloud provider"]
    L --> PG[("postgres<br/>keys · spend")]

    classDef g fill:#3b0764,stroke:#e879f9,color:#fae8ff,stroke-width:2px
    classDef n fill:#1e1b4b,stroke:#a78bfa,color:#ede9fe
    class L,PG g
    class OC,LP,LS,M,CLOUD n
```

---

## 7. Containerisation decisions

| Component | Containerised? | How | Caveats |
|---|---|---|---|
| **llama-swap** | **Yes** | Custom image `FROM nvcr.io/nvidia/vllm` + llama-swap binary. llama-swap spawns `vllm serve` **as child processes** inside the same container | No docker socket needed. Container stays up (tiny); models come and go. `ipc: host`; HF token via Docker secret; `--watch-config` reloads `llama-swap.yaml` |
| **admin-dashboard** | **Yes** | `python:3.12-slim` (no `openshell` CLI); Docker status via **read-only** `docker-socket-proxy` (`CONTAINERS=1 INFO=1 NETWORKS=1 POST=0`) | Can't call host `nemoclaw`; it only checks that the sandbox container is running |
| **OpenShell gateway** | **No — created by NemoClaw** | Started and managed by `nemoclaw onboard` on the host. NemoClaw's external-gateway mode accepts only a systemd-supervised process on `127.0.0.1`, which does not fit a compose container | Sandboxes reach LiteLLM and Alloy through `host.openshell.internal`, which resolves to the gateway of the `openshell-docker` network NemoClaw creates (`172.21.0.1` here, **not** `docker0`); that is `DOCKER_BRIDGE_IP` in `.env` |
| **OpenClaw sandbox** | Already a container | Created by OpenShell, not by compose | Lifecycle via `nemoclaw` / `openshell` |
| **NemoClaw** | **No — host CLI** | Onboarding & lifecycle commands; not a daemon. Creates the OpenShell gateway and the sandbox | Its docs name the inference and MCP variables used in 13.2 |
| **tailscaled** | Host (recommended) | Funnel to host-loopback Caddy | Can be containerised with `network_mode: host` if desired |

### Why llama-swap inside the vLLM image

```mermaid
flowchart LR
    subgraph A["Option A · rejected"]
        LSA["llama-swap container"] -- "docker.sock" --> DA["docker run vllm-*<br/>sibling containers"]
    end
    subgraph B["Option B · chosen"]
        LSB["model-runner container<br/>llama-swap PID 1"] -- "fork / SIGTERM" --> VB["vllm serve<br/>child processes"]
    end

    classDef bad fill:#450a0a,stroke:#f87171,color:#fee2e2
    classDef good fill:#052e16,stroke:#4ade80,color:#dcfce7
    class LSA,DA bad
    class LSB,VB good
```

| | A · sibling containers | **B · child processes** |
|---|---|---|
| Docker socket | Required (root-equivalent) | **Not required** |
| Cold start | Container create + vLLM load | vLLM load only |
| Memory freed on idle | Yes | Yes (process exit) |
| Mix vLLM + llama.cpp | Easy | Add `llama-server` binary to the image |

---

## 8. Container inventory & networks

### Inventory

| # | Service | Image (arm64) | Host publish | Docker net | Lifecycle |
|---|---|---|---|---|---|
| 1 | caddy | `caddy:2.11.7-alpine` | `127.0.0.1:9080` (host network); `172.17.0.1:8443` (HTTPS MCP listener for the sandbox) | host | always |
| 2 | authelia | `authelia/authelia:4.39.28` | `127.0.0.1:9091` | `ai` | always |
| 3 | litellm | `ghcr.io/berriai/litellm:<pinned>` | `127.0.0.1:4000`, `${DOCKER_BRIDGE_IP}:4000` | `ai`, `obs` | always |
| 4 | litellm-db | `postgres:17.11-alpine` | — | `ai` | always |
| 5 | model-runner | built: `nvcr.io/nvidia/vllm:<TAG>` + llama-swap | — | `ai`, `obs` | always · agent model preloaded, never unloaded (`ttl: 0`) |
| 6 | comfyui | built: `nvcr.io/nvidia/pytorch:<TAG>-py3` | `127.0.0.1:8188` | `ai` | always · **weights on demand** |
| 7 | comfy-mcp | built: `python:3.12-slim` | — | `ai` | always |
| 8 | *(OpenShell gateway)* | created by `nemoclaw onboard`, not by compose | host-managed | — | always |
| 9 | *(OpenClaw sandbox)* | NemoClaw blueprint | `127.0.0.1:18789` (forward) | OpenShell-managed | always |
| 10 | admin-dashboard | built: `python:3.12-slim` | `127.0.0.1:9000` | `ai`, `obs` | always |
| 11 | docker-socket-proxy | `tecnativa/docker-socket-proxy:v0.5.0` (the only service that mounts `docker.sock`, besides cAdvisor; used by admin-dashboard and Alloy) | — | `ai` | always |
| 12 | alloy | `grafana/alloy:<pinned>` | `${DOCKER_BRIDGE_IP}:4318` (OTLP/HTTP for the sandbox) | `obs`, `ai` | always |
| 13 | prometheus | `prom/prometheus:<pinned>` | — | `obs`, `ai` | always |
| 14 | loki | `grafana/loki:<pinned>` | — | `obs` | always |
| 15 | tempo | `grafana/tempo:<pinned>` | — | `obs` | always |
| 16 | grafana | `grafana/grafana:<pinned>` (the OSS edition) | `127.0.0.1:3000` | `obs` | always |
| 17 | node-exporter | `prom/node-exporter:<pinned>` | — | `obs` | always |
| 18 | cadvisor | `ghcr.io/google/cadvisor:<pinned ≥ Docker 25 support>` | — | `obs` | always · **privileged** |
| 19 | gpu-exporter | built: `ubuntu:24.04` + `nvidia-smi` loop (GPU via the shared `deploy…devices` block, same as model-runner and comfyui) | — | none (`network_mode: none`; shares the `textfile` volume) | always |

> **Two bridge addresses are involved.** `${DOCKER_BRIDGE_IP}` (`172.21.0.1` here) is the gateway of NemoClaw's `openshell-docker` network: what the sandbox sees as `host.openshell.internal`, where LiteLLM `:4000` and Alloy `:4318` publish. `172.17.0.1` (`docker0`, always present) is where Caddy's HTTPS MCP listener binds (`caddy/Caddyfile`, `scripts/nemoclaw-setup.sh`). Neither is reachable from outside the host. `DOCKER_BRIDGE_IP` is only known after NemoClaw has created its network: start with `172.17.0.1`, switch after the first onboarding (§17 step 8).

### Networks & exposure

```mermaid
flowchart TB
    subgraph PUB["Reachable from Internet"]
        FUN["Funnel :443 → 127.0.0.1:9080"]
    end
    subgraph LO["Host loopback 127.0.0.1"]
        L1["9080 caddy"]
        L2["9091 authelia"]
        L3["4000 litellm"]
        L4["9000 dashboard"]
        L5["3000 grafana"]
        L6["8188 comfyui"]
        L7["18789 openclaw"]
    end
    subgraph BR["Sandbox-reachable bridge addresses"]
        B1["DOCKER_BRIDGE_IP 172.21.0.1 · 4000 litellm"]
        B3["DOCKER_BRIDGE_IP · 4318 alloy OTLP/HTTP"]
        B2["docker0 172.17.0.1 · 8443 caddy HTTPS MCP"]
    end
    subgraph INT["Internal only · docker networks ai / obs"]
        I1["model-runner :8000 · :10001"]
        I2["comfy-mcp :9100"]
        I3["litellm-db :5432"]
        I4["prometheus · loki · tempo · alloy :4317"]
        I5["exporters · socket-proxy"]
    end
    FUN --> L1

    classDef p fill:#450a0a,stroke:#f87171,color:#fee2e2,stroke-width:2px
    classDef l fill:#0f172a,stroke:#38bdf8,color:#e0f2fe
    classDef b fill:#052e16,stroke:#4ade80,color:#dcfce7
    classDef i fill:#1f2937,stroke:#9ca3af,color:#f3f4f6
    class FUN p
    class L1,L2,L3,L4,L5,L6,L7 l
    class B1,B2,B3 b
    class I1,I2,I3,I4,I5 i
```

---

## 9. Monitoring & observability

### Stack

| Signal | Source | Collector | Store | View |
|---|---|---|---|---|
| **GPU** (util, temp, power, clocks) | `nvidia-smi` → textfile | node-exporter | Prometheus | Grafana |
| **Unified memory** | `/proc/meminfo` (`MemAvailable`, swap) | node-exporter | Prometheus | Grafana |
| Host CPU / disk / net | kernel | node-exporter | Prometheus | Grafana |
| Container CPU / mem | cgroups | cAdvisor | Prometheus | Grafana |
| **vLLM** (running/waiting reqs, KV-cache %, TTFT, TPOT, tokens/s) | `vllm serve` `/metrics` on `:10001` | Prometheus scrape | Prometheus | Grafana (vLLM dashboard) |
| vLLM traces | `--otlp-traces-endpoint` | Alloy | Tempo | Grafana |
| **LiteLLM** (requests, latency, TTFT, tokens, spend per key/model, failures) | `/llm/metrics` (Prometheus authenticates with the master key) + OTel callback (OTLP/HTTP → `alloy:4318`) | Prometheus + Alloy | Prometheus + Tempo | Grafana |
| **OpenClaw traces** (run, model call, tool exec, skill, message flow) | `diagnostics-otel` plugin, OTLP/HTTP. **Not enabled yet** (needs a sandbox network rule for `host.openshell.internal:4318`; `TODO.md`) | Alloy | Tempo | Grafana |
| OpenClaw metrics (tokens, cost, run duration, tool usage, queues) | `diagnostics-otel` (not enabled yet) | Alloy → remote-write | Prometheus | Grafana |
| Logs (all containers) | Docker API via `docker-socket-proxy` (`tcp://docker-socket-proxy:2375`) | Alloy | Loki (labels `container`, `service`) | Grafana |
| Model up/down state | `up{job="vllm-*"}` (scrape fails when scaled to zero) | Prometheus | Prometheus | Grafana + dashboard |

### Topology

```mermaid
flowchart LR
    subgraph SRC["Sources"]
        OCX["OpenClaw<br/>diagnostics-otel"]
        LTX["LiteLLM<br/>otel + /metrics"]
        VLX["vLLM<br/>OTLP + /metrics"]
        DCK["Docker logs"]
        NE["node-exporter<br/>+ gpu textfile"]
        CAD["cAdvisor"]
    end

    AL["Grafana Alloy<br/>OTLP gRPC :4317 · HTTP :4318<br/>batch · docker log tail"]
    PR["Prometheus<br/>remote-write receiver"]
    LK["Loki"]
    TP["Tempo<br/>+ metrics-generator"]
    GF["Grafana /grafana"]

    OCX -- "traces · metrics · logs" --> AL
    LTX -- "traces" --> AL
    VLX -- "traces" --> AL
    DCK --> AL
    AL -- "metrics" --> PR
    AL -- "logs" --> LK
    AL -- "traces" --> TP
    TP -- "span metrics · service graph" --> PR
    PR -- "scrape" --> LTX
    PR -- "scrape" --> VLX
    PR -- "scrape" --> NE
    PR -- "scrape" --> CAD
    GF --> PR
    GF --> LK
    GF --> TP

    classDef s fill:#1e1b4b,stroke:#a78bfa,color:#ede9fe
    classDef c fill:#082f49,stroke:#22d3ee,color:#cffafe,stroke-width:2px
    classDef v fill:#422006,stroke:#facc15,color:#fef9c3,stroke-width:2px
    class OCX,LTX,VLX,DCK,NE,CAD s
    class AL,PR,LK,TP c
    class GF v
```

### End-to-end trace

OpenClaw sends a W3C `traceparent` on provider calls → LiteLLM continues the trace → vLLM continues it. One Tempo trace shows:

```text
openclaw.run ─────────────────────────────────────────────────────────── 14.2 s
├─ openclaw.context.assembly ──── 0.1 s
├─ openclaw.model.call ─────────────────────────────── 9.8 s
│  └─ litellm.request (qwen3.6-35b, key=openclaw-sandbox) ── 9.7 s
│     └─ vllm.llm_request ── ttft 0.42 s · 612 out tokens ── 9.6 s
├─ openclaw.tool.execution  generate_image ─────── 4.1 s
│  └─ litellm.mcp.call comfy_image-generate_image ── 4.0 s
└─ openclaw.model.call ─ 0.2 s
```

### GPU on GB10 — why not DCGM

`dcgm-exporter` does not work properly on GB10 unified memory, and NVML returns `N/A` for many memory fields. Use:

- `nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,clocks.sm` → `gpu.prom` textfile every 10 s (`gb10_gpu_*` metrics; fields that return `N/A` are exported as `NaN`)
- `/proc/meminfo` `MemAvailable` + `SwapFree` for real allocatable memory (NVIDIA's own guidance for UMA)
- `gb10_gpu_collector_timestamp_seconds` and `gb10_gpu_up` so a dead collector doesn't look like a healthy idle GPU (the overview board has a collector-age panel; no alert rule is provisioned yet)

Reference implementation worth reading: `cadaverine/dgx-spark-observability` (GB10 quirks documented).

### Grafana dashboards

Provisioned: **GB10 · AI Stack Overview** (`gb10-overview.json`, folder *AI Stack*) with rows *Host · GB10* (unified memory, GPU util/temp/power, collector age, memory/swap, top-10 container memory), *Models* (up/down, vLLM running/waiting, p95 TTFT, tokens/s) and *Gateway · LiteLLM* (requests/s by key, failures/s). Datasources link traces ↔ logs ↔ metrics.

| Dashboard | Status |
|---|---|
| **GB10 Host + vLLM + LiteLLM basics** | **Shipped** as the single overview board above |
| **vLLM** (full) | Not shipped — import upstream vLLM Grafana JSON |
| **LiteLLM** (full) | Not shipped — import upstream LiteLLM Grafana JSON |
| **OpenClaw** | Not shipped — build from exported metric names (tokens, cost, run duration, tool usage) |
| **Traces** | Grafana Explore → Tempo (service graph via metrics-generator) |
| **Logs** | Grafana Explore → Loki, label `container` |

### Suggested alerts (Grafana alerting — **not provisioned**; create them in Grafana)

| Alert | Condition |
|---|---|
| Memory pressure | `MemAvailable < 12 GB` for 5 m |
| Swap thrash | `rate(pswpin) > X` for 5 m |
| GPU collector stale | textfile mtime > 60 s |
| GPU hot | temp > 85 °C for 5 m |
| Model stuck starting | llama-swap starting > 15 m |
| LiteLLM errors | 5xx rate > 5 % for 5 m |
| Auth brute force | Authelia regulation bans > 0 |

---

## 10. Memory budget

```mermaid
pie showData title Unified memory · 128 GB · all services hot
    "Agent LLM · vLLM @ 0.30" : 36
    "Image gen · FLUX schnell fp8 + T5" : 24
    "OS · Docker · sandbox · page cache" : 14
    "Gateway · auth · observability" : 6
    "Headroom" : 48
```

| Service | Setting | Approx. |
|---|---|---|
| vllm agent | `--gpu-memory-utilization 0.30 --max-model-len 131072 --max-num-seqs 4` | ~36 GB |
| comfyui | FLUX.1-schnell fp8 + T5-XXL fp8 | ~20–25 GB hot · ~1 GB after `/free` |
| litellm + postgres + authelia + caddy | — | ~1.5 GB |
| prometheus + loki + tempo + grafana + alloy + exporters | Prometheus/Loki 30 d, Tempo 14 d retention | ~4–5 GB |

> Keep **Σ gpu-memory-utilization × 121 GB + ComfyUI peak + 20 GB < 115 GB**.

---

## 11. Model lifecycle (scale-to-zero)

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Stopped
    Stopped --> Starting: request via LiteLLM<br/>or dashboard Up
    Starting --> Ready: /health 200
    Starting --> Stopped: healthCheckTimeout 900 s
    Ready --> Ready: requests reset idle timer
    Ready --> Stopped: idle ≥ ttl → SIGTERM child<br/>or dashboard Down
```

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Unloaded
    Unloaded --> Loading: job queued<br/>or dashboard Warm
    Loading --> Hot: weights resident
    Hot --> Hot: jobs
    Hot --> Unloaded: idle ≥ 10 min → POST /free<br/>or dashboard Free
```

> llama-swap runs a single model (the agent), which also handles image input. ComfyUI is separate and is freed by the dashboard's idle watcher.
>
> **Do not start a ComfyUI generation while the agent model is loading** (container start, or editing `llama-swap.yaml`, which hot-reloads and restarts vLLM). vLLM sizes its KV cache by measuring memory during start-up, and ComfyUI loading FLUX (17 GB) at the same moment made it compute a negative cache and fail (`No available memory for the cache blocks`). Free ComfyUI (`POST /free`, or the dashboard's Free) and reload.

| Model | Owner | Idle policy | Cold start |
|---|---|---|---|
| Agent LLM | llama-swap (in model-runner) | `ttl: 0` (never unloads) + `hooks.on_startup.preload`, so it is loaded about 3 minutes after the container starts. Down/Up in the dashboard still work | measured: **~330 s** the very first time (empty caches), **~200 s** after that, even in a brand-new container (~130 s of it is loading the 23.5 GB of weights) |
| Image gen | dashboard idle watcher (polls every 60 s) | `COMFY_IDLE_MINUTES` (10) → `/free` | ~20–60 s |

---

## 12. Request flows

### 12.1 Agent chat (cold start, fully traced)

```mermaid
sequenceDiagram
    autonumber
    actor U as You
    participant C as Caddy + Authelia
    participant OC as OpenClaw sandbox
    participant OS as OpenShell proxy
    participant L as LiteLLM
    participant LS as llama-swap
    participant V as vllm agent
    participant T as Alloy → Tempo

    U->>C: wss /openclaw · Authelia cookie
    C->>OC: proxied · gateway token from the browser
    OC->>OS: POST https://inference.local/v1/chat/completions
    OS->>L: inject Bearer openclaw-sandbox key
    L->>LS: POST /v1/chat/completions
    alt model stopped
        LS->>V: fork vllm serve
        loop until /health 200
            LS->>V: GET /health
        end
    end
    LS->>V: proxy
    V-->>L: stream tokens + tool_calls
    L-->>OC: stream
    OC-->>U: reply
    OC--)T: openclaw.* spans
    L--)T: litellm span
    V--)T: vllm span
```

### 12.2 Image generation via LiteLLM MCP gateway

```mermaid
sequenceDiagram
    autonumber
    participant OC as OpenClaw sandbox
    participant P as OpenShell MCP proxy
    participant K as Caddy 172.17.0.1:8443
    participant L as LiteLLM MCP gateway
    participant M as comfy-mcp
    participant C as ComfyUI
    participant D as Dashboard watcher

    OC->>P: MCP tools/call comfy_image-generate_image
    P->>K: HTTPS /llm/comfy_image/mcp · key injected · Caddy CA verified
    K->>L: proxy · Remote-* stripped
    L->>M: forward
    M->>C: POST /prompt
    loop poll
        M->>C: GET /history/id
    end
    M-->>L: text: image_url + markdown + settings (no image bytes)
    L-->>OC: result
    Note over OC: the agent puts the markdown in its reply;<br/>the browser loads https://PUBLIC_HOST/comfy/view?… through Authelia
    D->>C: GET /queue every 60 s
    Note over D,C: empty ≥ 10 min → POST /free
```

### 12.3 External API client

```mermaid
sequenceDiagram
    autonumber
    participant S as Script / laptop
    participant F as Funnel
    participant C as Caddy
    participant L as LiteLLM
    participant LS as llama-swap

    S->>F: POST https://gb10…/llm/v1/chat/completions · Bearer sk-laptop
    F->>C: HTTP
    C->>C: strip Remote-* headers · no forward_auth
    C->>L: proxy · stream
    L->>L: key valid · budget ok · model allowed
    L->>LS: forward
    LS-->>S: streamed response
```

---

## 13. Configuration

All files live at the repository root. Clone it anywhere on the GB10 (the compose project name is fixed to `ai-stack` in `compose.yaml`, so volume names such as `ai-stack_vllm_cache` do not depend on the folder).

### 13.1 Project files

```text
.                                        # repo root = /srv/ai-stack on the host
├── gb10-agent-stack.md                  # this document
├── VARIABLES.md                         # every value to set/check, per file
├── compose.yaml                         # 17 services (the OpenShell gateway and the OpenClaw sandbox are created by NemoClaw)
├── README.md                            # start here: what this is, how to bring it up, where everything is
├── TO-VERIFY.md                         # what was tested, what was assumed, what is still open
├── TODO.md                              # planned work
├── .env.example                         # copy → .env (no secrets; the image tags are the verified ones)
├── .gitignore                           # .env, secrets/*, authelia/users.yml, data/
├── scripts/
│   ├── init-secrets.sh                  # generates secrets/, .env, users.yml (never overwrites)
│   ├── create-litellm-keys.sh           # openclaw-sandbox · laptop · scripts keys → secrets/litellm_keys.json
│   └── nemoclaw-setup.sh                # install · ca · onboard · mcp · config (the NemoClaw/OpenClaw steps)
├── secrets/                             # git-ignored · chmod 700 · authelia_{jwt,session,storage_key}, litellm_master_key,
│                                        #   litellm_db_password, grafana_admin_password, litellm.env, hf_token, litellm_keys.json
├── data/                                # git-ignored: comfy-output/ (ComfyUI images), caddy-root.crt (exported by nemoclaw-setup.sh ca)
├── caddy/Caddyfile
├── authelia/
│   ├── configuration.yml                # templated with PUBLIC_HOST
│   └── users.yml.example                # one `admin` user in group `admins` (copy to users.yml, change the name and hash); add `users`-group accounts yourself
├── litellm/config.yaml
├── model-runner/
│   ├── Dockerfile                       # vLLM image + llama-swap (arm64 release asset); the image already ships the OpenTelemetry libs
│   └── llama-swap.yaml
├── comfyui/
│   ├── Dockerfile                       # NVIDIA PyTorch base, keeps CUDA torch
│   └── workflows/flux-schnell-api.json  # API-format FLUX schnell workflow
├── comfy-mcp/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── server.py                        # tools: generate_image · list_checkpoints
├── dashboard/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py                           # FastAPI · status · Up/Down · ComfyUI idle unloader
│   ├── templates/{index.html, partials/status.html}
│   └── static/htmx.min.js               # vendored htmx 2.0.4 (no third-party script is loaded); see static/README.md
├── openclaw/openclaw.patch.json5        # gateway public origin / base path, applied in the sandbox by nemoclaw-setup.sh config
└── observability/
    ├── alloy/config.alloy
    ├── prometheus/prometheus.yml
    ├── loki/config.yaml
    ├── tempo/config.yaml
    ├── grafana/
    │   ├── provisioning/datasources/datasources.yaml   # Prometheus · Loki · Tempo (trace↔log↔metric links)
    │   ├── provisioning/dashboards/dashboards.yaml
    │   └── dashboards/gb10-overview.json               # the only dashboard shipped
    └── gpu-exporter/{Dockerfile, collect.sh}
```

| File | Purpose | Key settings |
|---|---|---|
| [`compose.yaml`](compose.yaml) | Every service, network, volume, secret | Caddy `network_mode: host`; LiteLLM + Alloy OTLP also published on `${DOCKER_BRIDGE_IP}` for sandboxes |
| [`.env.example`](.env.example) | Host + pinned image tags | `PUBLIC_HOST`, `DOCKER_BRIDGE_IP`, `MODELS_DIR`, all `*_IMAGE` |
| [`caddy/Caddyfile`](caddy/Caddyfile) | Single-port path router + the sandbox MCP listener | `forward_auth` → Authelia; `/llm/v1` key-only + `Remote-*` stripped; 15 min streaming timeouts; HSTS/nosniff headers; unmatched paths → `/admin/`. Second site `https://172.17.0.1:8443` (`tls internal`) serving only `/llm/*/mcp` to the sandbox |
| [`authelia/configuration.yml`](authelia/configuration.yml) | SSO + 2FA | `default_policy: deny`; `/llm/v1` bypass; `admins` vs `users`; session 12 h / 1 h idle; regulation 3 / 2 m / 30 m |
| [`litellm/config.yaml`](litellm/config.yaml) | LLM + MCP gateway | `agent` alias; 900 s timeouts; `num_retries: 1`; `comfy_image` MCP; `prometheus` + `otel` callbacks; `trusted_proxy_ranges` |
| [`model-runner/llama-swap.yaml`](model-runner/llama-swap.yaml) | The agent model under llama-swap | Fixed port 10001; `gpu-memory-utilization` 0.30; `max-model-len` 131072; `ttl: 0` + startup preload; `logToStdout: both` |
| [`comfy-mcp/server.py`](comfy-mcp/server.py) | ComfyUI → MCP | Streamable HTTP on `:9100/mcp`; returns text with an `image_url`, ready-made `markdown` and the settings, **not** image bytes (OpenClaw turns inline images into base64 text and overflows its context). `COMFY_INLINE_IMAGE=true` adds a size-budgeted JPEG for clients that render it |
| [`dashboard/app.py`](dashboard/app.py) | Admin UI | Any `Remote-User` can read status; `Remote-Groups ∋ admins` required for mutations; idle watcher calls ComfyUI `/free` |
| [`openclaw/openclaw.patch.json5`](openclaw/openclaw.patch.json5) | OpenClaw gateway | `basePath: /openclaw`, `publicOrigin`, `allowedOrigins`; no `auth` block (token mode is NemoClaw's) and no `agents` block (NemoClaw writes the model reference); applied with `openclaw config patch` by `scripts/nemoclaw-setup.sh config` |
| [`scripts/nemoclaw-setup.sh`](scripts/nemoclaw-setup.sh) | NemoClaw steps | `install`, `ca`, `onboard`, `mcp`, `config`; see 13.2 |
| [`observability/…`](observability/) | Metrics, logs, traces | Alloy OTLP → Prometheus / Loki / Tempo; Tempo span metrics; GB10 textfile GPU exporter |

### 13.2 NemoClaw onboarding

`scripts/nemoclaw-setup.sh onboard` runs `nemoclaw onboard` non-interactively with the values below. The interactive wizard asks the same things, but on a DGX Spark it first offers a managed-vLLM shortcut that would start a second copy of the model: avoid it (`NEMOCLAW_NO_EXPRESS=1`, and the non-interactive path never shows it).

| Setting | Value | Why |
|---|---|---|
| Gateway | NemoClaw creates and manages it (do not set `NEMOCLAW_GATEWAY_MANAGEMENT`) | Its external-gateway mode only accepts a systemd-supervised process on `127.0.0.1`, not a container |
| Provider | `NEMOCLAW_PROVIDER=custom`, "Other OpenAI-compatible endpoint" | Our model sits behind LiteLLM |
| Endpoint | `NEMOCLAW_ENDPOINT_URL=http://host.openshell.internal:4000/llm/v1`, key = `openclaw-sandbox` | The name only resolves inside the sandbox, so onboarding skips probing it (`NEMOCLAW_TRUSTED_PRIVATE_HOSTS=host.openshell.internal`). The key goes into the OpenShell provider store; the sandbox sees only a placeholder |
| Model | `agent` | LiteLLM alias for `qwen3.6-35b` |
| Image input / reasoning | `NEMOCLAW_INFERENCE_INPUTS=text,image`, `NEMOCLAW_REASONING=true` | **Build-time.** Non-interactive onboarding defaults to text only. Changing them needs `onboard --fresh --recreate-sandbox` |
| Context window | NemoClaw default `131072` (`NEMOCLAW_CONTEXT_WINDOW`) | Must match `--max-model-len` in `llama-swap.yaml` |
| Sandbox name | `NEMOCLAW_SANDBOX` from `.env` (`nemoclaw-assistant`) | The dashboard finds the container by it |
| GPU | `--no-gpu` (`NEMOCLAW_SANDBOX_GPU=0`) | The sandbox needs none; this host has no NVIDIA CDI spec, which NemoClaw's preflight otherwise insists on |
| Policy tier | `balanced`, no web search | Inference needs no sandbox rule (it goes through `inference.local`) |
| Trusted CA | `NEMOCLAW_CORPORATE_CA_BUNDLE=data/caddy-root.crt` | So the OpenShell MCP proxy trusts Caddy's certificate on `172.17.0.1:8443`. **Build-time and honoured only by a fresh onboard** (`rebuild` ignores it) |

After onboarding: `scripts/nemoclaw-setup.sh mcp` runs `nemoclaw <sandbox> mcp add comfy_image --url https://172.17.0.1:8443/llm/comfy_image/mcp --env LITELLM_MCP_KEY --trusted-private-host 172.17.0.1`. Managed MCP accepts only HTTPS, rejects `host.openshell.internal` and loopback, and treats the Funnel hostname as a private address (it resolves to the tailnet IP, which containers cannot reach). Then `scripts/nemoclaw-setup.sh config` applies the OpenClaw patch.

### 13.3 Tailscale Funnel

```bash
sudo tailscale funnel --bg http://127.0.0.1:9080     # public :443 → Caddy
tailscale funnel status

# to take the stack off the public internet again
tailscale funnel --https=443 off
```

The tailnet policy must grant the node the `funnel` node attribute.

---

## 14. Admin dashboard

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│  GB10 · AI Stack                     you (admins)  ● Funnel  ● Authelia  [⎋] │
├──────────────────────────────────────────────────────────────────────────────┤
│  Unified memory ███████████████████░░░░░░░░░░░░  71 / 128 GB  GPU 18% · 54°C │
├──────────────────────────┬───────────┬─────────┬────────────┬───────────────┤
│ Model                    │ State     │ Memory  │ Idle / TTL │ Actions       │
├──────────────────────────┼───────────┼─────────┼────────────┼───────────────┤
│ Agent · Qwen3.6 35B      │ ● Ready   │ 36 GB   │ 4m / 30m   │ [Down]        │
│ Image · FLUX schnell     │ ◐ Idle    │ 1 GB    │ 7m / 10m   │ [Warm] [Free] │
├──────────────────────────┴───────────┴─────────┴────────────┴───────────────┤
│ Services                                                                     │
│  ● caddy  ● authelia  ● litellm  ● litellm-db  ● model-runner  ● comfyui     │
│  ● comfy-mcp  ● sandbox:nemoclaw-assistant  ● openclaw                       │
│  ● prometheus  ● loki  ● tempo  ● grafana  ● alloy  ● gpu-exporter (8s ago)  │
├──────────────────────────────────────────────────────────────────────────────┤
│ Quick links:  /openclaw   /llm/ui   /grafana   /comfy                        │
└──────────────────────────────────────────────────────────────────────────────┘
```

| Method | Path (under `/admin`) | Action |
|---|---|---|
| `GET` | `/` | HTML (HTMX polls `/partials/status` every 5 s) |
| `GET` | `/api/status` | Aggregated JSON |
| `POST` | `/api/models/{id}/up` | llama-swap `GET /upstream/{id}/health` (triggers start) |
| `POST` | `/api/models/{id}/down` | llama-swap `POST /api/models/unload/{id}` (`404` for an unknown model; `501` only if llama-swap lacks the endpoint, which v265 does not) |
| `POST` | `/api/image/warm` | Queue a 1-step 256 px workflow (also resets the idle timer) |
| `POST` | `/api/image/free` | ComfyUI `POST /free {"unload_models": true, "free_memory": true}` |
| `GET` | `/healthz` | Liveness |

| Data | Source |
|---|---|
| Model list / state | llama-swap `/v1/models` + `/running` |
| Image model | ComfyUI `/system_stats`, `/queue`, `/history` (idle watcher) |
| Containers | docker-socket-proxy `GET /containers/json` |
| Sandbox / OpenClaw | Container whose name contains `NEMOCLAW_SANDBOX` |
| Memory / GPU | Prometheus (`node_memory_MemAvailable_bytes`, `gb10_gpu_*`) |

**AuthZ:** read routes need a `Remote-User` header (401 otherwise); every mutating route requires `admins ∈ Remote-Groups` (403 otherwise). Model IDs are regex-validated before being passed to llama-swap.

---

## 15. MCPs & Skills

| Name | Type | Purpose | Path | In this repo? |
|---|---|---|---|---|
| **comfy_image** | MCP via LiteLLM gateway | `comfy_image-generate_image` (prompt, size, steps, seed, checkpoint → text with `image_url` + `markdown`), `comfy_image-list_checkpoints` | sandbox → OpenShell MCP proxy → `https://172.17.0.1:8443/llm/comfy_image/mcp` (Caddy, key-only) → LiteLLM → comfy-mcp | **Yes** (`comfy-mcp/`, `litellm/config.yaml`, `caddy/Caddyfile`) |
| **image understanding** | Agent model | Qwen3.6-35B-A3B accepts images directly, so there is no separate image model or vision skill | sandbox → LiteLLM | n/a (no `imageModel` set) |
| **web-search** | NemoClaw managed | Brave search | policy allow-list | Not enabled (`NEMOCLAW_WEB_SEARCH_PROVIDER=none`) |
| **github** | MCP via LiteLLM gateway | Issues, PRs, code search | sandbox → LiteLLM → GitHub MCP | No — needs an `mcp_servers` entry |
| **filesystem** | OpenClaw built-in | Sandbox workspace only | Landlock | n/a |
| **stack-ops** *(optional)* | Skill | Read-only status from `/admin/api/status` | dashboard | No |


**How the agent uses it.** OpenClaw's progressive tool disclosure hides MCP tools until the agent searches its catalog, so the agent's workspace `AGENTS.md` (section *Tools → Local notes*) tells it to use `comfy_image-generate_image` for images, to paste the returned `markdown` as is, and never to download, decode or invent the image URL. That note lives in the sandbox (not in this repo) and has to be re-added after a fresh onboard; the text is in `TO-VERIFY.md`. The OpenShell MCP policy only allows JSON-RPC bodies, so the `DELETE` that closes an MCP session is rejected (`policy_denied`): harmless noise.

---

## 16. Security model

```mermaid
flowchart LR
    subgraph Z0["Zone 0 · Internet"]
        I["Anyone"]
    end
    subgraph Z1["Zone 1 · Edge"]
        E["Funnel → Caddy<br/>Authelia 2FA · LiteLLM keys"]
    end
    subgraph Z2["Zone 2 · Host loopback / docker nets"]
        H["apps · gateway · models<br/>observability"]
    end
    subgraph Z3["Zone 3 · OpenShell sandbox"]
        S["OpenClaw<br/>Landlock · seccomp · netns"]
    end
    I -- "HTTPS :443 only" --> E
    E -- "authenticated" --> H
    S -- "L7 proxy · allow-list · creds injected" --> H

    classDef z0 fill:#450a0a,stroke:#f87171,color:#fee2e2,stroke-width:2px
    classDef z1 fill:#0f172a,stroke:#38bdf8,color:#e0f2fe,stroke-width:2px
    classDef z2 fill:#1e1b4b,stroke:#a78bfa,color:#ede9fe,stroke-width:2px
    classDef z3 fill:#052e16,stroke:#4ade80,color:#dcfce7,stroke-width:2px
    class I z0
    class E z1
    class H z2
    class S z3
```

| Control | Setting |
|---|---|
| Public surface | **Only** Funnel `:443`. Compose publishes only to `127.0.0.1` or `${DOCKER_BRIDGE_IP}` (litellm, alloy :4318); Caddy binds `127.0.0.1:9080`. Host firewall default-deny inbound |
| Human auth | Authelia, **two_factor** on every UI path, `default_policy: deny`, regulation 3 tries / 30 min ban |
| Machine auth | LiteLLM virtual keys with model allow-lists, RPM caps, budgets |
| Header spoofing | `forward_auth copy_headers` overwrites; `/llm/v1` and the MCP listener strip `Remote-*` |
| Sandbox | NemoClaw Balanced policy. Inference only through `inference.local` (OpenShell holds the key). MCP only to `172.17.0.1:8443`, restricted to MCP methods, with a certificate verified against Caddy's CA. Telemetry egress is not configured yet |
| OpenClaw access | Authelia + 2FA in front; the gateway token and device pairing behind it (§5). `dangerouslyDisableDeviceAuth` is optional and weakens the second check |
| Caddy CA | Caddy's local root signs the MCP listener's certificate; its key is in the `caddy_data` volume. The sandbox is built to trust that root, so protect the volume like a secret |
| Docker socket | **rw:** none in compose (the NemoClaw-managed gateway uses it on the host). `docker-socket-proxy` mounts it `:ro`, but a read-only mount of a Unix socket does **not** restrict API calls; the restriction is the proxy's allow-list (`CONTAINERS`, `INFO`, `NETWORKS`; `POST=0`). `admin-dashboard` and `alloy` reach Docker only through the proxy and have no socket mount. `cadvisor` mounts `/var/run` (which contains `docker.sock`) and runs **privileged** with `/`, `/sys`, `/var/lib/docker` mounted, so treat it as root-equivalent. Nothing public has socket access |
| Secrets | Docker secrets / `secrets/` `chmod 700`; never in `.env`, never in the sandbox. LiteLLM reads its master key and DB URL from `secrets/litellm.env` (`env_file`); Prometheus gets the master key as a Docker secret to scrape `/llm/metrics` |
| Optional hardening | Use Tailscale's Funnel request header to restrict `/admin`, `/grafana`, `/llm` UI to **tailnet-only** while `/openclaw` and `/llm/v1` stay public. To take everything off the internet: `tailscale funnel --https=443 off` |
| Updates | Pin all image tags; Renovate/diun for update notices; never auto-pull `latest` |

---

## 17. Bring-up runbook

Everything below was done on this machine, in this order. Run the commands from the repository root.

```mermaid
flowchart LR
    A["1 · Host<br/>Docker · GPU · Tailscale<br/>/srv/models"] --> B["2 · Secrets<br/>.env · users"]
    B --> C["3 · Weights"]
    C --> D["4 · Core stack<br/>+ LiteLLM keys"]
    D --> E["5 · Observability<br/>edge · dashboard"]
    E --> F["6 · Funnel<br/>+ first login"]
    F --> G["7 · NemoClaw<br/>install · CA"]
    G --> H["8 · Onboard<br/>+ bridge address"]
    H --> I["9 · MCP + OpenClaw<br/>config · agent note"]
    I --> J["10 · OpenClaw login"]

    classDef s fill:#0b1220,stroke:#38bdf8,color:#e0f2fe,stroke-width:2px
    class A,B,C,D,E,F,G,H,I,J s
```

### 1 · Host prerequisites

- DGX Spark class machine (GB10, arm64) on DGX OS / Ubuntu 24.04, NVIDIA driver working (`nvidia-smi`).
- Docker (29.x was used) with GPU support: `docker run --rm --gpus all ubuntu:24.04 nvidia-smi` must work. The compose files request GPUs with `deploy.resources.reservations.devices`; no `nvidia` runtime has to be registered (`runtime: nvidia` does **not** work on this host).
- Your user is in the `docker` group.
- Tailscale installed and logged in, HTTPS certificates and Funnel enabled for the tailnet, and the tailnet policy grants this node the `funnel` attribute.
- Outbound internet: GitHub (flaky from this host; `nemoclaw-setup.sh install` works around it), Docker Hub, NGC (`nvcr.io`), GHCR, Hugging Face, npm.
- Model folders: `sudo mkdir -p /srv/models/{hf,comfy/checkpoints} && sudo chown -R "$USER" /srv/models`

### 2 · Secrets, `.env`, users

```bash
bash scripts/init-secrets.sh        # asks for a Hugging Face token (may be empty); creates secrets/, data/, .env, authelia/users.yml
$EDITOR .env                        # set PUBLIC_HOST (your *.ts.net name); leave DOCKER_BRIDGE_IP=172.17.0.1 for now
$EDITOR authelia/users.yml          # your login name, e-mail, group `admins`, and a password hash:
docker run --rm -it authelia/authelia:4.39.28 authelia crypto hash generate argon2
```

### 3 · Model weights

```bash
# model-runner sets HF_HOME=/models/hf (= ${MODELS_DIR}/hf), so vLLM reads ${MODELS_DIR}/hf/hub. The repo is not gated (23.5 GB).
# Download from the built image as your own user so the files are not root-owned:
docker compose build model-runner
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e HF_HOME=/models/hf \
  -v /srv/models/hf:/models/hf --entrypoint hf ai-stack-model-runner download nvidia/Qwen3.6-35B-A3B-NVFP4

# image model: one all-in-one FLUX checkpoint (Apache-2.0, not gated, 17.2 GB)
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e HF_HOME=/tmp/hf -v /srv/models/comfy:/models/comfy \
  --entrypoint hf ai-stack-model-runner download Comfy-Org/flux1-schnell flux1-schnell-fp8.safetensors \
  --local-dir /models/comfy/checkpoints
rm -rf /srv/models/comfy/checkpoints/.cache
```

### 4 · Core stack and LiteLLM keys

```bash
docker compose up -d --build authelia litellm-db litellm model-runner comfyui comfy-mcp
bash scripts/create-litellm-keys.sh      # → secrets/litellm_keys.json (openclaw-sandbox · laptop · scripts)
```

`model-runner` starts loading the agent model straight away (preload). The very first start takes about 6 minutes (caches are empty), later ones about 3 to 4. Check `docker compose exec -T model-runner curl -s localhost:8000/running` for `"state":"ready"`. **Do not generate images while it is loading** (§11).

### 5 · Observability, edge, dashboard

```bash
docker compose up -d --build alloy prometheus loki tempo grafana node-exporter cadvisor gpu-exporter docker-socket-proxy caddy admin-dashboard
```

### 6 · Funnel and first login

```bash
sudo tailscale funnel --bg http://127.0.0.1:9080 && tailscale funnel status   # off again: tailscale funnel --https=443 off
```

Open `https://<PUBLIC_HOST>/` from any device: Authelia login → it asks for a second factor. There is no e-mail: read the one-time code or enrolment link on the server with `docker compose exec authelia cat /data/notification.txt`, then register a TOTP app and/or a passkey (register two). Browsing `http://127.0.0.1:9080` directly gives a 400: Authelia only accepts your `*.ts.net` host.

### 7 · NemoClaw: install and trust Caddy's CA

```bash
scripts/nemoclaw-setup.sh install    # NemoClaw CLI (Node 22 through nvm); ends with a CDI warning, which is expected
scripts/nemoclaw-setup.sh ca         # data/caddy-root.crt, the root that signs the MCP listener (Caddy must be running)
```

### 8 · Onboard, then fix the bridge address

```bash
scripts/nemoclaw-setup.sh onboard    # 3 to 8 minutes: gateway, sandbox image, inference route, smoke test
```

On a first run this ends with `Compatible endpoint sandbox smoke check failed … inference.local returned transient HTTP 503`. That is expected: `host.openshell.internal` is the gateway of the new `openshell-docker` network, and LiteLLM is still published on `172.17.0.1`. Fix it and resume:

```bash
GW=$(docker network inspect openshell-docker --format '{{(index .IPAM.Config 0).Gateway}}'); echo "$GW"   # 172.21.0.1 here
sed -i "s/^DOCKER_BRIDGE_IP=.*/DOCKER_BRIDGE_IP=$GW/" .env
docker compose up -d litellm alloy
nemoclaw onboard --resume            # the smoke test sends a real chat request; the model must be loaded or it times out (exit 28)
```

Success ends with "OpenClaw is ready". The script warns whenever `.env` and the network disagree.

### 9 · MCP, OpenClaw config, agent note

```bash
scripts/nemoclaw-setup.sh mcp        # registers comfy_image over https://172.17.0.1:8443 (ends "credential resolution verified … HTTP 200")
scripts/nemoclaw-setup.sh config     # gateway public origin / base path (add --dry-run first if you like)
scripts/nemoclaw-setup.sh notes      # tells the agent to use the tool and show the returned markdown
```

If `mcp` says "found non-prefix partial state", an earlier attempt left pieces behind: `nemoclaw <sandbox> mcp remove comfy_image`, delete the leftover provider shown by `openshell provider list` (`openshell provider delete <name>`), and run it again.

### 10 · OpenClaw login

1. `nemoclaw <sandbox> dashboard-url --quiet` prints a URL containing `token=…` (a password; do not share it).
2. Open `https://<PUBLIC_HOST>/openclaw/`, sign in through Authelia, paste the token and press Connect.
3. If it says "Device pairing required", approve the browser in a sandbox shell (`nemoclaw <sandbox> connect`), see §5. The CLI needs `--token`, so read the token with `read -rs TOKEN` after running `openclaw gateway auth-token --show` (it refuses to print into `$(...)`).
4. Start a fresh chat and ask: "Generate an image of a red bicycle." The reply should contain a picture served from `https://<PUBLIC_HOST>/comfy/view?…` (your logged-in browser loads it through Authelia). The first image loads FLUX and takes a minute or two.

### Operating notes

- **Rebuild vs re-onboard.** `nemoclaw <sandbox> rebuild` keeps the workspace and `openclaw.json` but replays the recorded settings; build-time settings (image input, reasoning, context window, the trusted CA) change only with `scripts/nemoclaw-setup.sh onboard` (`--fresh --recreate-sandbox`). That resets the OpenClaw config and the MCP registration: afterwards re-run `mcp`, `config` and `notes`, and expect a new gateway token.
- **Never switch the gateway to `trusted-proxy` auth.** NemoClaw re-adds its token at every container start, so the sandbox container then exits at start (`trusted-proxy and token auth are mutually exclusive`) and OpenShell marks it `Error`; recovery is to fix the config file in the stopped container (`docker cp`) and `docker start` it, or to re-onboard. Back up `~/.nemoclaw/rebuild-backups` before experiments.
- **Reloading the model** (editing `llama-swap.yaml`, restarting `model-runner`) takes 3 to 4 minutes; OpenClaw requests and image generation wait or fail meanwhile.
- **Admin access recovery** (lost second factor, forgotten password): §5.
- **Everything off the internet:** `tailscale funnel --https=443 off`.

---

## 18. Verification checklist

- [ ] `ss -tlnp` — no `0.0.0.0` listeners except `tailscaled`; bridge listeners only on `172.17.0.1` (Caddy `:8443`) and `${DOCKER_BRIDGE_IP}` (LiteLLM `:4000`, Alloy `:4318`)
- [ ] From an **off-tailnet** device: `https://<PUBLIC_HOST>/` → Authelia login → 2FA → dashboard
- [ ] `/grafana`, `/comfy`, `/llm/ui`, `/openclaw` all redirect to `/auth` when logged out; `/llm/comfy_image/mcp` on the public host does too
- [ ] A `users`-group account can open `/openclaw` but gets `403` on `/admin`
- [ ] `curl /llm/v1/models` without key → `401`; with `laptop` key → model list
- [ ] Sending a forged `Remote-User` header to `/llm/v1` or a protected path has no effect
- [ ] Prometheus targets are up (`vllm-agent` is up while the model is loaded)
- [ ] From the sandbox network, `https://172.17.0.1:8443/llm/comfy_image/mcp`: no key → `401`, `openclaw-sandbox` key → `200`, `laptop` key → `403`, any other path → `404`, certificate verifies against `data/caddy-root.crt`
- [ ] `nemoclaw <sandbox> status` shows Phase `Ready`; `nemoclaw <sandbox> mcp status comfy_image` shows everything ready
- [ ] OpenClaw chat answers; the LiteLLM usage shows the `openclaw-sandbox` key
- [ ] "Generate an image …" returns a markdown image from `/comfy/view?…`, and the context does not overflow
- [ ] Grafana GB10 Host board shows GPU util/temp/power and the collector staleness panel is green
- [ ] Authelia bans an IP after 3 failed logins

---

## 19. Open items

The detailed log (what was tested on this host, with results) is `TO-VERIFY.md`; planned work is `TODO.md`. Still open:

| Item | Why it matters |
|---|---|
| OpenClaw telemetry (`diagnostics-otel`) needs a sandbox network rule for `host.openshell.internal:4318` | No OpenClaw spans/metrics in Tempo/Prometheus yet |
| Behaviour after a **host reboot** (NemoClaw gateway user service, the sandbox, the `172.17.0.1` and `${DOCKER_BRIDGE_IP}` binds, model preload) | `${DOCKER_BRIDGE_IP}` belongs to a network NemoClaw creates; if Docker starts the containers first they retry (`restart: unless-stopped`) but this was not tested |
| `scripts/nemoclaw-setup.sh` end to end on a clean machine | Each command was run by hand; the script itself was only exercised for `ca`, `config --dry-run`, `notes` and syntax |
| Real-browser checks of `/comfy/` and the dashboard, Funnel's real forwarded headers, that sign-out ends the Authelia session | Listed in `TO-VERIFY.md` |
| Tailscale Funnel request header name for tailnet-only admin hardening | Optional hardening |

Resolved during bring-up: the OpenShell gateway is NemoClaw-managed (no container); the model is multimodal (no vision model); the llama-swap arm64 asset and unload endpoint (v265); the OpenClaw SSO route (`trusted-proxy`) does not work with NemoClaw 0.0.137, so OpenClaw uses its gateway token; MCP goes over HTTPS on `172.17.0.1:8443`.

---

<sub>NVIDIA GB10 · DGX OS · NemoClaw · OpenShell · OpenClaw · vLLM · llama-swap · LiteLLM · ComfyUI · Caddy · Authelia · Tailscale Funnel · Grafana · Prometheus · Loki · Tempo · Alloy</sub>
