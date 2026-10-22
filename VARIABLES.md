# AI Stack — Variables Reference

Every value you set or check before running the stack, grouped by file.

**Required** column:
- **Yes**: must be set; there is no usable default.
- **Check**: has a default that may be wrong for your machine.
- **Optional**: the default works; change it only if you want to.

> Example image tags show the **format** only. Look up the current arm64 / GB10-compatible tag in NGC, GHCR or Docker Hub before using them.

---

## Contents

- [`.env`](#env)
- [`secrets/`](#secrets)
- [`authelia/users.yml`](#autheliausersyml)
- [`authelia/configuration.yml`](#autheliaconfigurationyml)
- [`compose.yaml`](#composeyaml)
- [`caddy/Caddyfile`](#caddycaddyfile)
- [`litellm/config.yaml`](#litellmconfigyaml)
- [`model-runner/Dockerfile`](#model-runnerdockerfile)
- [`model-runner/llama-swap.yaml`](#model-runnerllama-swapyaml)
- [`comfyui/Dockerfile`](#comfyuidockerfile)
- [`comfyui/workflows/flux-schnell-api.json`](#comfyuiworkflowsflux-schnell-apijson)
- [`comfy-mcp/server.py`](#comfy-mcpserverpy)
- [`dashboard/app.py`](#dashboardapppy)
- [`openclaw/openclaw.snippet.json5`](#openclawopenclawsnippetjson5)
- [`scripts/init-secrets.sh`](#scriptsinit-secretssh)
- [`scripts/create-litellm-keys.sh`](#scriptscreate-litellm-keyssh)
- [`observability/prometheus/prometheus.yml`](#observabilityprometheusprometheusyml)
- [`observability/gpu-exporter/collect.sh`](#observabilitygpu-exportercollectsh)
- [`observability/loki/config.yaml`](#observabilitylokiconfigyaml)
- [`observability/tempo/config.yaml`](#observabilitytempoconfigyaml)
- [Files with nothing to set](#files-with-nothing-to-set)
- [Values that must match across files](#values-that-must-match-across-files)

---

## `.env`

Copy from `.env.example`. Docker Compose reads it. It holds no secrets.

### Host

| Variable | Description | Example value | Required |
|---|---|---|---|
| `PUBLIC_HOST` | Tailscale Funnel hostname. Used for Authelia cookie domain, ACL rules, redirect URLs and Grafana root URL | `gb10.tail1234.ts.net` | Yes |
| `DOCKER_BRIDGE_IP` | `docker0` address. LiteLLM `:4000` and Alloy OTLP `:4318` bind here so sandboxes can reach them as `host.openshell.internal` | `172.17.0.1` | Check (`ip -4 addr show docker0`) |
| `MODELS_DIR` | Host folder for model weights. `hf/` is mounted into model-runner, `comfy/` into ComfyUI | `/srv/models` | Check |
| `TZ` | Timezone for Authelia | `Europe/London` | Optional |

### Images & versions

| Variable | Description | Example value | Required |
|---|---|---|---|
| `VLLM_IMAGE` | Base image for model-runner (vLLM + llama-swap) | `nvcr.io/nvidia/vllm:26.09-py3` | Yes |
| `PYTORCH_IMAGE` | Base image for ComfyUI (keeps NVIDIA's CUDA torch) | `nvcr.io/nvidia/pytorch:26.09-py3` | Yes |
| `LLAMA_SWAP_VERSION` | llama-swap release number baked into model-runner | `265` | Yes |
| `COMFYUI_REF` | ComfyUI git tag or commit to build | `v0.42.1` | Yes |
| `LITELLM_IMAGE` | LiteLLM proxy image | `ghcr.io/berriai/litellm:v1.106.2` | Yes |
| `ALLOY_IMAGE` | Grafana Alloy collector | `grafana/alloy:v1.21.0` | Yes |
| `PROMETHEUS_IMAGE` | Prometheus (3.5.x is the LTS line) | `prom/prometheus:v3.5.5` | Yes |
| `LOKI_IMAGE` | Loki (3.x, to match the provided config) | `grafana/loki:3.7.9` | Yes |
| `TEMPO_IMAGE` | Tempo (2.x to match the provided single-binary config; 3.x changed the architecture) | `grafana/tempo:2.10.9` | Yes |
| `GRAFANA_IMAGE` | Grafana (`grafana/grafana` is the OSS edition; `grafana-oss` on Docker Hub stops at 13.0.x) | `grafana/grafana:13.2.4` | Yes |
| `NODE_EXPORTER_IMAGE` | Prometheus node exporter | `prom/node-exporter:v1.12.1` | Yes |
| `CADVISOR_IMAGE` | cAdvisor (a release that supports Docker 25+) | `ghcr.io/google/cadvisor:v0.60.6` | Yes |

### Behaviour

| Variable | Description | Example value | Required |
|---|---|---|---|
| `COMFY_IDLE_MINUTES` | Minutes without ComfyUI activity before the dashboard calls `/free` | `10` | Optional |
| `COMFY_DEFAULT_STEPS` | Default sampler steps for `generate_image` | `4` | Optional |
| `NEMOCLAW_SANDBOX` | Sandbox name used during `nemoclaw onboard`; the dashboard looks for a container containing this name | `my-assistant` | Check |

---

## `secrets/`

One value per file, no trailing newline. Git-ignored, `chmod 700`. `scripts/init-secrets.sh` creates them.

| Variable (file) | Description | Example value | Required |
|---|---|---|---|
| `authelia_jwt` | Authelia password-reset JWT secret | `9f2c…` (64 hex chars) | Generated |
| `authelia_session` | Authelia session encryption secret | `4be1…` (64 hex chars) | Generated |
| `authelia_storage_key` | Authelia SQLite storage encryption key | `c07a…` (64 hex chars) | Generated |
| `litellm_master_key` | LiteLLM admin key; also used by Prometheus to scrape `/llm/metrics` | `sk-3f9a…` (`sk-` + 48 hex) | Generated |
| `litellm_db_password` | Postgres password for the `litellm` user | `a81d…` (48 hex chars) | Generated |
| `grafana_admin_password` | Password for Grafana's built-in `admin` account (replaces the default `admin`/`admin`); read via `GF_SECURITY_ADMIN_PASSWORD__FILE`. Day-to-day access is through Authelia, so you rarely need it. Mode 644 so Grafana (uid 472) can read it | `a81d…` (48 hex chars) | Generated |
| `litellm.env` | Env file for LiteLLM: `LITELLM_MASTER_KEY=…` and `DATABASE_URL=postgresql://litellm:<pw>@litellm-db:5432/litellm` | see description | Generated |
| `hf_token` | Hugging Face token for model downloads | `hf_AbCdEf…` | **Yes** (you supply it) |
| `litellm_keys.json` | Virtual keys created by `create-litellm-keys.sh` (`openclaw-sandbox`, `laptop`, `scripts`) | JSON array | Generated after LiteLLM is up |

---

## `authelia/users.yml`

Copied from `users.yml.example`; git-ignored. Repeat the block for each user.

| Variable | Description | Example value | Required |
|---|---|---|---|
| `users.<username>` | Login name (YAML key) | `kiran` | Yes |
| `displayname` | Name shown in the UI and passed as `Remote-Name` | `Kiran` | Yes |
| `email` | Passed as `Remote-Email`. OpenClaw `trusted-proxy` uses it as the user identity | `kiran@example.com` | Yes |
| `password` | Argon2id hash (`docker run --rm -it authelia/authelia:4.39.28 authelia crypto hash generate argon2`) | `$argon2id$v=19$m=65536,t=3,p=4$…` | Yes |
| `groups` | `admins` = full access; `users` = `/openclaw` only | `[admins]` | Yes |

---

## `authelia/configuration.yml`

Templated from `PUBLIC_HOST` (`X_AUTHELIA_CONFIG_FILTERS=template`). Nothing to set unless you change policy.

| Variable | Description | Example value | Required |
|---|---|---|---|
| `{{ env "PUBLIC_HOST" }}` | Filled in from `.env` at startup | `gb10.tail1234.ts.net` | via `.env` |
| `session.expiration` | Maximum session length | `12h` | Optional |
| `session.inactivity` | Idle logout | `1h` | Optional |
| `regulation.max_retries` / `find_time` / `ban_time` | Brute-force lockout | `3` / `2m` / `30m` | Optional |
| `webauthn.display_name` | Passkey prompt label | `GB10 AI Stack` | Optional |
| `access_control.rules[].subject` | Which groups may reach which paths | `group:admins` | Optional |

---

## `compose.yaml`

Mostly filled in from `.env` (see above). These values are typed directly into the file.

| Variable | Description | Example value | Required |
|---|---|---|---|
| `GF_AUTH_PROXY_WHITELIST` (grafana) | Source IPs allowed to send `Remote-User`; must cover the Docker network gateways | `172.16.0.0/12, 127.0.0.1` | Check (Docker address pools) |
| `GF_USERS_AUTO_ASSIGN_ORG_ROLE` (grafana) | Role for auto-created Grafana users | `Admin` | Optional |
| `--storage.tsdb.retention.time` (prometheus) | Metric retention | `30d` | Optional |
| `XDG_CACHE_HOME` / `TRITON_CACHE_DIR` (model-runner) | Where vLLM keeps its `torch.compile` cache, FlashInfer autotune results and Triton kernels. On the `vllm_cache` volume so they survive container re-creation | `/cache`, `/cache/triton` | Optional |
| `CUDA_CACHE_PATH` / `CUDA_CACHE_MAXSIZE` (model-runner) | The driver's JIT cache. The GB10 (`sm_121`) JIT-compiles PTX on first use, which costs about 46 s of CUDA-graph capture per cold start without this cache. 4 GiB because the default 256 MiB evicts. To reset all caches: `docker volume rm ai-stack_vllm_cache` | `/cache/cuda`, `4294967296` | Optional |
| `INTERVAL_SECONDS` (gpu-exporter) | GPU sampling interval | `10` | Optional |
| Image tags not in `.env` | Pinned directly in `compose.yaml`: `caddy:2.11.7-alpine`, `authelia/authelia:4.39.28`, `postgres:17.11-alpine` (`postgres` major version must not change on an existing volume), `tecnativa/docker-socket-proxy:v0.5.0` | `caddy:2.11.7-alpine` | Optional (bump when updating) |

---

## `caddy/Caddyfile`

No variables. These ports are typed in and must match the published ports in `compose.yaml`.

| Variable | Description | Example value | Required |
|---|---|---|---|
| Listener | Caddy listen address; target of `tailscale funnel` | `127.0.0.1:9080` | Optional |
| Authelia upstream | forward-auth + `/auth` | `127.0.0.1:9091` | Must match compose |
| LiteLLM upstream | `/llm`, `/llm/v1` | `127.0.0.1:4000` | Must match compose |
| OpenClaw upstream | `/openclaw` (NemoClaw sandbox forward) | `127.0.0.1:18789` | Check (NemoClaw forward port) |
| Grafana upstream | `/grafana` | `127.0.0.1:3000` | Must match compose |
| ComfyUI upstream | `/comfy` | `127.0.0.1:8188` | Must match compose |
| Dashboard upstream | `/admin` | `127.0.0.1:9000` | Must match compose |
| `read_timeout` | Streaming timeout; covers model cold starts | `15m` | Optional |

---

## `litellm/config.yaml`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `LITELLM_MASTER_KEY` (env) | Admin key, from `secrets/litellm.env` | `sk-3f9a…` | Generated |
| `DATABASE_URL` (env) | Postgres DSN, from `secrets/litellm.env` | `postgresql://litellm:…@litellm-db:5432/litellm` | Generated |
| `model_list[].model_name` | Names clients request | `agent`, `qwen3.6-35b` | Optional |
| `litellm_params.model` | `openai/<served-model-name>` from llama-swap | `openai/qwen3.6-35b` | Must match llama-swap |
| `litellm_params.api_base` | llama-swap endpoint | `http://model-runner:8000/v1` | Optional |
| `timeout` / `stream_timeout` / `request_timeout` | Must exceed vLLM cold start | `900` | Optional |
| `mcp_servers.comfy_image.url` | comfy-mcp endpoint. Clients reach it through LiteLLM at `/llm/comfy_image/mcp`; tools are named `comfy_image-<tool>` | `http://comfy-mcp:9100/mcp` | Optional |
| `general_settings.trusted_proxy_ranges` | Proxy source ranges LiteLLM trusts for forwarded client IPs and login throttling (Caddy arrives from the Docker bridge) | `["127.0.0.1/32", "172.16.0.0/12"]` | Check (Docker address pools) |
| `router_settings.num_retries` | Retries per request | `1` | Optional |

---

## `model-runner/Dockerfile`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `VLLM_IMAGE` (build arg) | From `.env` | `nvcr.io/nvidia/vllm:26.09-py3` | via `.env` |
| `LLAMA_SWAP_VERSION` (build arg) | From `.env`; used in the release download URL | `265` | via `.env` |
| Release asset name | `llama-swap_<ver>_linux_arm64.tar.gz`; confirm on the releases page | `llama-swap_265_linux_arm64.tar.gz` | Check |

---

## `model-runner/llama-swap.yaml`

Set for the one model (`qwen3.6-35b`).

| Variable | Description | Example value | Required |
|---|---|---|---|
| `healthCheckTimeout` | Seconds to wait for a model to become healthy | `900` | Optional |
| Hugging Face model ID | First argument to `vllm serve` | `nvidia/Qwen3.6-35B-A3B-NVFP4` | Check |
| `--served-model-name` | Name exposed on `/v1/models` | `qwen3.6-35b` | Must match LiteLLM |
| `--port` + `proxy` | Fixed port per model (scraped by Prometheus) | `10001` / `http://127.0.0.1:10001` | Must match prometheus.yml |
| `--gpu-memory-utilization` | Share of unified memory vLLM reserves | `0.30` | Check |
| `--max-model-len` | Context length | `65536` | Optional |
| `--max-num-seqs` | Concurrent sequences | `4` | Optional |
| `--tool-call-parser` | vLLM tool-call parser for the model | `qwen3_coder` | **Check** (wrong value → empty `tool_calls`) |
| `--reasoning-parser` | vLLM reasoning parser | `qwen3` | Check |
| `--limit-mm-per-prompt` | Not set. The agent model accepts images; add this to cap images per request | — | Optional |
| `--otlp-traces-endpoint` | Where vLLM sends traces | `http://alloy:4317` | Optional |
| `ttl` | Idle seconds before the model is stopped | `1800` | Optional |
| `logToStdout` | Send vLLM output to the container log so Alloy ships it to Loki (applied at container start, not on hot reload) | `both` | Optional |

---

## `comfyui/Dockerfile`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `BASE_IMAGE` (build arg) | From `PYTORCH_IMAGE` in `.env` | `nvcr.io/nvidia/pytorch:26.09-py3` | via `.env` |
| `COMFYUI_REF` (build arg) | From `.env` | `v0.42.1` | via `.env` |

---

## `comfyui/workflows/flux-schnell-api.json`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `1.inputs.ckpt_name` | Checkpoint filename in `${MODELS_DIR}/comfy/checkpoints/`. One all-in-one file (model, text encoders, VAE); download it from `Comfy-Org/flux1-schnell` (Apache-2.0, not gated, 17.2 GB) | `flux1-schnell-fp8.safetensors` | **Check** |
| `5.inputs.sampler_name` | Sampler | `euler` | Optional |
| `5.inputs.scheduler` | Scheduler | `simple` | Optional |
| `5.inputs.cfg` | CFG scale (FLUX schnell uses 1.0) | `1.0` | Optional |
| `7.inputs.filename_prefix` | Output filename prefix | `mcp` | Optional |

---

## `comfy-mcp/server.py`

Environment variables (set in `compose.yaml`).

| Variable | Description | Example value | Required |
|---|---|---|---|
| `COMFY_URL` | ComfyUI base URL | `http://comfyui:8188` | Optional |
| `COMFY_WORKFLOW` | API-format workflow path | `/app/workflows/flux-schnell-api.json` | Optional |
| `COMFY_DEFAULT_STEPS` | Default steps (from `.env`) | `4` | via `.env` |
| `COMFY_TIMEOUT_SECONDS` | Max wait per image (not set in compose) | `600` | Optional |
| `COMFY_MAX_IMAGE_BYTES` | Size budget for the JPEG returned to the caller (not set in compose). The LiteLLM MCP gateway drops messages over about 1 MiB and base64 adds a third, so keep this under about 780000. The tool lowers the JPEG quality (90 down to 40) until the image fits; the full-quality PNG stays in ComfyUI's output folder | `700000` | Optional |
| `MCP_BIND` | Listen address for streamable HTTP | `0.0.0.0:9100` | Optional |

---

## `dashboard/app.py`

Environment variables (set in `compose.yaml`).

| Variable | Description | Example value | Required |
|---|---|---|---|
| `LLAMA_SWAP_URL` | llama-swap API | `http://model-runner:8000` | Optional |
| `COMFY_URL` | ComfyUI API | `http://comfyui:8188` | Optional |
| `COMFY_WORKFLOW` | Workflow used for "Warm" | `/app/workflows/flux-schnell-api.json` | Optional |
| `COMFY_IDLE_MINUTES` | Idle unload threshold (from `.env`) | `10` | via `.env` |
| `DOCKER_URL` | Read-only Docker API via socket proxy | `http://docker-socket-proxy:2375` | Optional |
| `PROMETHEUS_URL` | Memory / GPU queries | `http://prometheus:9090` | Optional |
| `ADMIN_GROUP` | Group required for Up/Down/Warm/Free | `admins` | Optional |
| `NEMOCLAW_SANDBOX` | Sandbox container name match (from `.env`) | `my-assistant` | via `.env` |

---

## `openclaw/openclaw.snippet.json5`

Applied inside the NemoClaw sandbox with `openclaw configure` or `openclaw config set`. **Not templated**, so edit it directly.

| Variable | Description | Example value | Required |
|---|---|---|---|
| `gateway.publicOrigin` | Public browser origin; must equal `https://` + `PUBLIC_HOST` | `https://gb10.tail1234.ts.net` | **Yes** |
| `gateway.controlUi.basePath` | Path prefix served by Caddy | `/openclaw` | Optional |
| `gateway.port` | Gateway port (NemoClaw forwards it to host) | `18789` | Check |
| `gateway.trustedProxies` | Proxy source IPs trusted for identity headers | `["127.0.0.1"]` | Optional |
| `gateway.auth.trustedProxy.userHeader` | Header holding the user identity | `remote-email` | Optional |
| `agents.defaults.*` | Not set here: `nemoclaw onboard` writes the model reference (enter `agent` as the model ID). Image input needs `NEMOCLAW_INFERENCE_INPUTS=text,image` at onboarding | — | — |
| `diagnostics.otel.endpoint` | OTLP/HTTP collector reachable from the sandbox | `http://host.openshell.internal:4318` | Optional |
| `diagnostics.otel.sampleRate` | Trace sampling ratio | `1.0` | Optional |

---

## `scripts/init-secrets.sh`

| Variable | Description | Example value | Required |
|---|---|---|---|
| Hugging Face token prompt | Typed in when the script runs; saved to `secrets/hf_token` | `hf_AbCdEf…` | Yes (can be filled in later) |

---

## `scripts/create-litellm-keys.sh`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `LITELLM_API` (env) | LiteLLM base URL including root path | `http://127.0.0.1:4000/llm` | Optional |
| `openclaw-sandbox` → `models`, `rpm_limit`, `object_permission.mcp_servers` | Key used by NemoClaw / the sandbox. MCP access is granted to every server in `litellm/config.yaml` (keys have none by default) | `["agent","qwen3.6-35b"]`, `60`, all servers | Optional |
| `laptop` → `rpm_limit`, `max_budget`, `budget_duration` | Personal API key limits | `30`, `50`, `30d` | Optional |
| `scripts` → `models`, `rpm_limit` | Automation key | `["agent"]`, `10` | Optional |

---

## `observability/prometheus/prometheus.yml`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `scrape_interval` | Global scrape interval | `15s` | Optional |
| `litellm.metrics_path` | Must include LiteLLM `SERVER_ROOT_PATH` | `/llm/metrics` | Optional |
| `litellm.authorization.credentials_file` | LiteLLM master key (Docker secret) | `/run/secrets/litellm_master_key` | Optional |
| `vllm-*.targets` | Fixed vLLM ports in model-runner | `model-runner:10001` | Must match llama-swap |

---

## `observability/gpu-exporter/collect.sh`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `INTERVAL_SECONDS` | Sampling interval (set in compose) | `10` | Optional |
| `TEXTFILE_DIR` | Output folder read by node-exporter | `/textfile` | Optional |

---

## `observability/loki/config.yaml`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `limits_config.retention_period` | Log retention | `720h` | Optional |

---

## `observability/tempo/config.yaml`

| Variable | Description | Example value | Required |
|---|---|---|---|
| `compactor.compaction.block_retention` | Trace retention | `336h` | Optional |
| `metrics_generator.processors` | Span metrics + service graph | `[service-graphs, span-metrics]` | Optional |

---

## Files with nothing to set

| File | Notes |
|---|---|
| `observability/alloy/config.alloy` | Internal service names only |
| `observability/grafana/provisioning/datasources/datasources.yaml` | Internal URLs; `$${__value.raw}` is a Grafana escape, not a variable |
| `observability/grafana/provisioning/dashboards/dashboards.yaml` | — |
| `observability/grafana/dashboards/gb10-overview.json` | — |
| `observability/gpu-exporter/Dockerfile` | `ubuntu:24.04` is a floating tag (pinning optional) |
| `comfy-mcp/Dockerfile`, `dashboard/Dockerfile` | `python:3.12-slim` is a floating tag (pinning optional) |
| `comfy-mcp/requirements.txt`, `dashboard/requirements.txt` | Version ranges capped below the next major |
| `.gitignore` | — |

---

## Values that must match across files

| Value | Files |
|---|---|
| `PUBLIC_HOST` | `.env`, `openclaw/openclaw.snippet.json5` (`publicOrigin`) |
| `NEMOCLAW_SANDBOX` | `.env`, the name entered in `nemoclaw onboard`, `compose.yaml` (passed to the dashboard, which matches it against container names) |
| `qwen3.6-35b` | `model-runner/llama-swap.yaml`, `litellm/config.yaml`, `scripts/create-litellm-keys.sh`, `observability/prometheus/prometheus.yml` (`model` label) |
| `agent` | `litellm/config.yaml`, `scripts/create-litellm-keys.sh`, `openclaw/openclaw.snippet.json5`, NemoClaw onboarding |
| Port `10001` | `model-runner/llama-swap.yaml`, `observability/prometheus/prometheus.yml` |
| `/llm` root path | `compose.yaml` (`SERVER_ROOT_PATH`), `caddy/Caddyfile`, `prometheus.yml`, `create-litellm-keys.sh`, NemoClaw provider URL |
| `admins` group | `authelia/users.yml`, `authelia/configuration.yml`, `compose.yaml` (`ADMIN_GROUP`) |
| Workflow node IDs `1`–`7` (`comfy-mcp` uses 1, 2, 3, 4, 5, 7; the dashboard warm-up uses 2, 4, 5) | `flux-schnell-api.json`, `comfy-mcp/server.py`, `dashboard/app.py` |
| Host ports 9091 · 4000 · 3000 · 8188 · 9000 | `compose.yaml`, `caddy/Caddyfile` |
| Caddy listener `127.0.0.1:9080` | `caddy/Caddyfile`, the `tailscale funnel` command |
| OpenClaw port `18789` | `caddy/Caddyfile` only; the sandbox forward is created by NemoClaw, not compose |
| Checkpoint filename | `flux-schnell-api.json`, file in `${MODELS_DIR}/comfy/checkpoints/` |
