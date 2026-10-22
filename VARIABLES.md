# AI Stack — Variables Reference

Every value you set or check before running the stack, grouped by file.

**Required** column:
- **Yes**: must be set; there is no usable default.
- **Check**: has a default that may be wrong for your machine.
- **Optional**: the default works; change it only if you want to.

> The image tags in `.env.example` are the ones that were verified on this GB10 (arm64, CUDA 13, `sm_121`). Bump them deliberately and re-test; do not switch to `latest`.

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
- [`ops-bridge/actions.yaml`](#ops-bridgeactionsyaml)
- [`openclaw/openclaw.patch.json5`](#openclawopenclawpatchjson5)
- [`scripts/init-secrets.sh`](#scriptsinit-secretssh)
- [`scripts/create-litellm-keys.sh`](#scriptscreate-litellm-keyssh)
- [`scripts/add-user.sh`](#scriptsadd-usersh)
- [`scripts/nemoclaw-setup.sh`](#scriptsnemoclaw-setupsh)
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
| `DOCKER_BRIDGE_IP` | The address the OpenShell sandbox sees as `host.openshell.internal`. LiteLLM `:4000` and Alloy OTLP `:4318` publish on it. It is the **gateway of the `openshell-docker` network that NemoClaw creates** (not `docker0`), so it is only known after the first onboarding: start with `172.17.0.1`, then set it to the output of `docker network inspect openshell-docker --format '{{(index .IPAM.Config 0).Gateway}}'` (here `172.21.0.1`) and run `docker compose up -d litellm alloy`. Re-check it if that network is ever recreated, and after a reboot (see `TO-VERIFY.md`) | `172.21.0.1` | **Check** |
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
| `NEMOCLAW_SANDBOX` | Sandbox name used by `scripts/nemoclaw-setup.sh` / `nemoclaw onboard`; the dashboard looks for a container whose name contains it (`openshell-default--<name>-<id>`) | `nemoclaw-assistant` | Check |

### E-mail (Authelia)

Leave `SMTP_ADDRESS` empty and Authelia writes reset and enrolment links to a file instead (`docker compose exec authelia cat /data/notification.txt`). Set it and they are e-mailed. The SMTP password or API key goes in `secrets/authelia_smtp_password`, never in `.env`. After changing any of these: `docker compose up -d authelia`.

| Variable | Description | Example value | Required |
|---|---|---|---|
| `SMTP_ADDRESS` | Mail server. `smtp://host:587` uses STARTTLS; `submissions://host:465` uses implicit TLS. Authelia refuses to log in over plaintext | `smtp://smtp-relay.brevo.com:587` | Optional |
| `SMTP_USERNAME` | SMTP login. For Brevo it is the login shown under *SMTP & API* (not your account e-mail); for Resend it is `resend` | `a1b2c3001@smtp-brevo.com` | With `SMTP_ADDRESS` |
| `SMTP_SENDER` | From address. Must be one the service has verified (Brevo: *Senders*; a domain service: an address on the verified domain). Mail from a personal address (Gmail, Proton) can land in spam, and a Proton sender mailing a Proton recipient is silently dropped (Brevo still says "Delivered"); use another recipient address or a domain you own | `you@example.com` | With `SMTP_ADDRESS` |

---

## `secrets/`

One value per file, no trailing newline. Git-ignored. The folder is `chmod 700` and the files are mode 600, except `litellm_master_key` and `grafana_admin_password`, which are 644 because Prometheus (user `nobody`) and Grafana (uid 472) read them as Docker secrets; the 700 folder keeps other host users out. `scripts/init-secrets.sh` creates them and never overwrites an existing file.

| Variable (file) | Description | Example value | Required |
|---|---|---|---|
| `authelia_jwt` | Authelia password-reset JWT secret | `9f2c…` (64 hex chars) | Generated |
| `authelia_session` | Authelia session encryption secret | `4be1…` (64 hex chars) | Generated |
| `authelia_storage_key` | Authelia SQLite storage encryption key | `c07a…` (64 hex chars) | Generated |
| `litellm_master_key` | LiteLLM admin key; also used by Prometheus to scrape `/llm/metrics` | `sk-3f9a…` (`sk-` + 48 hex) | Generated |
| `litellm_db_password` | Postgres password for the `litellm` user | `a81d…` (48 hex chars) | Generated |
| `grafana_admin_password` | Password for Grafana's built-in `admin` account (replaces the default `admin`/`admin`); read via `GF_SECURITY_ADMIN_PASSWORD__FILE`. Day-to-day access is through Authelia, so you rarely need it. Mode 644 so Grafana (uid 472) can read it | `a81d…` (48 hex chars) | Generated |
| `authelia_smtp_password` | SMTP password or API key (for Brevo, an *SMTP key*). Empty by default, which is correct while `SMTP_ADDRESS` is unset. Write it without a trailing newline: `read -rs k && printf '%s' "$k" > secrets/authelia_smtp_password` | `xsmtpsib-…` | Only for SMTP |
| `bridge_dashboard_token` | The admin dashboard's credential for `ops-bridge` (the bridge compares it in constant time). Mode 644 so the dashboard container can read it as a Docker secret | `9f2c…` (64 hex chars) | Generated |
| `litellm.env` | Env file for LiteLLM: `LITELLM_MASTER_KEY=…` and `DATABASE_URL=postgresql://litellm:<pw>@litellm-db:5432/litellm` | see description | Generated |
| `hf_token` | Hugging Face token for model downloads. The file must exist (compose mounts it), but it can be empty: the models in use are not gated | `hf_AbCdEf…` | Optional (you supply it) |
| `litellm_keys.json` | Virtual keys created by `create-litellm-keys.sh` (`openclaw-sandbox`, `laptop`, `scripts`) | JSON array | Generated after LiteLLM is up |

---

## `authelia/users.yml`

Copied from `users.yml.example`; git-ignored. Repeat the block for each user.

| Variable | Description | Example value | Required |
|---|---|---|---|
| `users.<username>` | Login name (YAML key) | `kiran` | Yes |
| `displayname` | Name shown in the UI and passed as `Remote-Name` | `Kiran` | Yes |
| `email` | Passed as `Remote-Email` (Grafana signs the user up with it) | `kiran@example.com` | Yes |
| `password` | Argon2id hash (`docker run --rm -it authelia/authelia:4.39.28 authelia crypto hash generate argon2`) | `$argon2id$v=19$m=65536,t=3,p=4$…` | Yes |
| `groups` | `admins` = full access; `users` = `/openclaw` and `/connect` only | `[admins]` | Yes |

Add people with `scripts/add-user.sh` rather than editing this file by hand (see below). Authelia watches the file (`watch: true`), so new users and edits (for example a changed `email`) take effect immediately. `sed -i` fails on it (read-only folder); write it back with `cat > /config/users.yml` through the container. The file is owned by root (Authelia rewrites it), so read it with `docker compose exec authelia cat /config/users.yml`.

`compose.yaml` mounts this file **read-write**, so Authelia can save password changes. Every user needs a second factor (`two_factor` on every protected path): **TOTP** (authenticator app) and **passkeys** (WebAuthn) both work, and passkeys are second-factor only (`enable_passkey_login` is not set). E-mail is optional (see `.env` → E-mail); without it Authelia's notifier writes links to `/data/notification.txt`.

**Recovery when a user loses their devices.** The admin does this on the server; nothing is emailed.

1. Remove the lost second factors:
   ```bash
   docker compose exec authelia authelia storage user totp delete <username> --config /config/configuration.yml
   docker compose exec authelia authelia storage user webauthn delete <username> --all --config /config/configuration.yml
   ```
2. The user signs in with their password and enrols a new TOTP app or passkey. The identity-verification link for that is e-mailed (or, without SMTP, written to `/data/notification.txt`: `docker compose exec authelia cat /data/notification.txt`; give it to the user).
3. A forgotten password: the user presses **Reset password** on the sign-in page and gets a link (e-mail, or the notification file without SMTP). Admin fallback: generate a new hash (command above) and replace `password` in `users.yml`.

Enrol at least two second factors per user (for example a passkey on each device plus TOTP) to avoid needing this.

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
| `access_control.rules[].policy` | `two_factor` on every protected path (decision: keep, with both TOTP and passkeys) | `two_factor` | Optional |
| `notifier` | Chosen by templating: `smtp` when `SMTP_ADDRESS` is set (password read from the `authelia_smtp_password` secret), otherwise `filesystem` | see `.env` → E-mail | via `.env` |
| `notifier.filesystem.filename` | Where links go when SMTP is not configured | `/data/notification.txt` | Optional |
| `authentication_backend.file.watch` | Reload `users.yml` when it changes, so `add-user.sh` needs no restart | `true` | Optional |
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
| `ops-bridge` service | Generic, allow-listed command bridge (see `ops-bridge/actions.yaml`). Has the Docker socket mounted read-write (it must `docker exec`), so it is isolated: internal `ai` network only, no published port, read-only root, all capabilities dropped, a bearer token per client. Only the dashboard reaches it | `http://ops-bridge:9200` | Keep |
| `USER_GROUP` / `PUBLIC_HOST` / `BRIDGE_URL` (admin-dashboard) | Group allowed to use `/connect`; the host used in the sign-in link; the bridge address | `users`, from `.env`, `http://ops-bridge:9200` | Optional |
| `SMTP_ADDRESS` / `SMTP_USERNAME` / `SMTP_SENDER` (authelia) | Passed from `.env` (empty by default) | — | via `.env` |
| `caddy_data` volume (caddy) | Caddy's local CA and the certificate for the sandbox MCP listener. Keep it: the sandbox is built to trust this CA's root, so losing the volume means a new root and a sandbox re-onboard | `caddy_data:/data` | Keep |
| Image tags not in `.env` | Pinned directly in `compose.yaml`: `caddy:2.11.7-alpine`, `authelia/authelia:4.39.28`, `postgres:17.11-alpine` (`postgres` major version must not change on an existing volume), `tecnativa/docker-socket-proxy:v0.5.0` | `caddy:2.11.7-alpine` | Optional (bump when updating) |

---

## `caddy/Caddyfile`

No variables. These ports are typed in and must match the published ports in `compose.yaml`.

| Variable | Description | Example value | Required |
|---|---|---|---|
| Listener | Caddy listen address; target of `tailscale funnel` | `127.0.0.1:9080` | Optional |
| MCP listener | Second site: HTTPS (`tls internal`, certificate for the IP) on the `docker0` address, serving only `/llm/*/mcp` key-only to LiteLLM. It exists because NemoClaw's managed MCP needs HTTPS and cannot use `host.openshell.internal` or the Funnel hostname (containers cannot reach the tailnet address). Not published through Funnel | `https://172.17.0.1:8443` | Check (`ip -4 addr show docker0`; must equal `MCP_URL` in `scripts/nemoclaw-setup.sh`) |
| `/connect` | Admin dashboard route that redirects a signed-in `admins`/`users` member to OpenClaw with the gateway token in the URL fragment (Authelia rule `^/connect$`, `two_factor`) | `127.0.0.1:9000` | Must match compose |
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
| `--max-model-len` | Context length. Keep it equal to OpenClaw's model context window (NemoClaw defaults to `131072`, set by `NEMOCLAW_CONTEXT_WINDOW` at onboarding). The KV cache held 557,530 tokens at 0.30, so 131072 fits at 4 sequences | `131072` | Optional |
| `--max-num-seqs` | Concurrent sequences | `4` | Optional |
| `--tool-call-parser` | vLLM tool-call parser for the model | `qwen3_coder` | **Check** (wrong value → empty `tool_calls`) |
| `--reasoning-parser` | vLLM reasoning parser | `qwen3` | Check |
| `--limit-mm-per-prompt` | Not set. The agent model accepts images; add this to cap images per request | — | Optional |
| `--otlp-traces-endpoint` | Where vLLM sends traces | `http://alloy:4317` | Optional |
| `ttl` | Idle seconds before the model is stopped. `0` = never unload: the agent is meant to be always on, and a cold start (about 200 s) breaks OpenClaw requests | `0` | Optional |
| `hooks.on_startup.preload` | Models llama-swap loads when the container starts, so the agent is ready about 3 minutes after boot without a first request | `[qwen3.6-35b]` | Optional |
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
| `COMFY_PUBLIC_URL` | Browser-reachable base of ComfyUI (Caddy serves it at `/comfy`, behind Authelia). `generate_image` returns a link and a ready-made markdown image to the agent instead of image bytes, because OpenClaw passes tool-result images to the model as base64 text (a 256 px image already costs tens of thousands of tokens and overflows the context). | `https://${PUBLIC_HOST}/comfy` | Optional |
| `COMFY_INLINE_IMAGE` | `true` makes `generate_image` also return the JPEG inline (for clients that render image content). Keep `false` for OpenClaw: it passes the image to the model as base64 text and fills the context | `false` | Optional |
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
| `NEMOCLAW_SANDBOX` | Sandbox container name match (from `.env`) | `nemoclaw-assistant` | via `.env` |
| `USER_GROUP` | Group allowed to use `/connect` (admins always can) | `users` | Optional |
| `PUBLIC_HOST` | Host used to build the `/openclaw/#token=…` redirect and the sign-in link (from `.env`) | `gb10.tail1234.ts.net` | via `.env` |
| `BRIDGE_URL` | ops-bridge address; the bearer token is read from `/run/secrets/bridge_dashboard_token` | `http://ops-bridge:9200` | Optional |
| `OPENCLAW_ENROLL_MINUTES` | Length of the "Open for N min" enrollment window (see below) | `10` | Optional |

**Devices card and `/connect`.** The admin page has an *OpenClaw devices* card (admins only) that lists pending pairing requests and paired browsers, with Approve, Reject and Revoke buttons. *Revoke* invalidates the device's token and removes it from the list. *Open for 10 min* opens an enrollment window in which new browser pairings are approved automatically; scope upgrades and CLI requests never are. `https://<PUBLIC_HOST>/connect` (admins and `users`, after Authelia) redirects to `/openclaw/#token=<gateway token>`; the Control UI stores the token and then removes it from the address bar. Approved browsers are labelled after the person who opened `/connect` just before the request (only when exactly one did within 10 minutes; Funnel hides the real client IP). The gateway token is shared, so per-user control is Authelia group membership plus per-device revoke. The audit lines (`source: dashboard.devices`) never contain the token.

---

## `ops-bridge/actions.yaml`

The only file to edit when a container needs to run a command for another container. The bridge validates it at start-up and refuses to start on a mistake. It is a generic service: nothing in it is specific to OpenClaw except the actions listed here.

| Variable | Description | Example value | Required |
|---|---|---|---|
| `clients.<name>.token_file` | Docker secret holding that client's bearer token | `/run/secrets/bridge_dashboard_token` | Yes |
| `clients.<name>.allow` | Action names (globs allowed) this client may call. An action that exists but is not allowed gets the same 403 as one that does not exist | `["openclaw.devices.*", "openclaw.gateway_token"]` | Yes |
| `actions.<name>.kind` | `exec` (run a command in a container), `restart`, or `logs` | `exec` | Yes |
| `actions.<name>.target` | Container selected by `name` regex or `label`; must match exactly one running container (otherwise 409) | `{name: "--${NEMOCLAW_SANDBOX}-"}` | Yes |
| `actions.<name>.params` | Allowed parameters, each with a `pattern` (full match) and optional `default`. Anything else is rejected (422) | `device_id: {pattern: "[0-9a-f]{64}"}` | Optional |
| `actions.<name>.argv` | Command as a list; `{param}` is replaced only as a whole element, so a value can never become a shell fragment or an extra flag | `[openclaw, devices, revoke, --device, "{device_id}"]` | For `exec` |
| `actions.<name>.exec` | `user`, `run_as`, `env`, `env_from_json_file`, `netns_of_process` (see the header of the file). The OpenClaw actions use it to enter the gateway's network namespace as the sandbox user and read the token from `openclaw.json` | `*openclaw_cli` | Optional |
| `actions.<name>.sensitive` | Log no parameters or output (used by `openclaw.gateway_token`) | `true` | Optional |
| `timeout`, `max_output` | Per-action limits (defaults: 30 s, 64 KiB) | `30` | Optional |

API: `GET /healthz`, `GET /v1/actions`, `POST /v1/actions/<name>` with `{"params": {…}}`; every call is logged as an audit line. At most 4 run at once. The bridge runs as root on purpose (it needs the Docker socket and `docker exec -u root`), which is why it is only reachable on the internal network with a token.

---

## `openclaw/openclaw.patch.json5`

Template applied inside the sandbox by `scripts/nemoclaw-setup.sh config` (`openclaw config patch --stdin`; it substitutes `__PUBLIC_HOST__` from `.env`, so there is nothing to edit). `openclaw.json` is authoritative after first launch, survives restarts, and `nemoclaw rebuild` restores it; re-run the script after `onboard --fresh --recreate-sandbox`, which resets it.

| Variable | Description | Example value | Required |
|---|---|---|---|
| `gateway.publicOrigin` | Public browser origin | `https://gb10.tail1234.ts.net` | via `.env` |
| `gateway.controlUi.basePath` | Path prefix Caddy serves the Control UI under | `/openclaw` | Optional |
| `gateway.controlUi.allowedOrigins` | Browser origins the gateway accepts (NemoClaw sets only `http://127.0.0.1:18789`; the public HTTPS origin must be added) | `["http://127.0.0.1:18789", "https://…"]` | via `.env` |
| `gateway.auth` | **Not set, on purpose.** NemoClaw's start script rewrites the gateway token at every container start, and OpenClaw refuses `trusted-proxy` auth while a token exists, so single sign-on into OpenClaw is not possible with NemoClaw 0.0.137 (tried: the sandbox then fails to start). Authelia gates the URL; the browser also needs the gateway token and a paired device | — | — |
| `agents.defaults.*` | Not set: `nemoclaw onboard` writes the model reference | — | — |
| `diagnostics.otel` | Not set yet. Sending OpenClaw telemetry to Alloy needs a sandbox network rule for `host.openshell.internal:4318`; see `TODO.md` | — | — |

**Optional, security trade-off.** To skip the per-browser device pairing, the Control UI can be told not to require it: `openclaw config patch` with `{ gateway: { controlUi: { dangerouslyDisableDeviceAuth: true } } }` inside the sandbox. OpenClaw's docs call this an emergency-only setting. Without it, approve each new browser with `openclaw devices approve <request-id> --token …` in a sandbox shell.

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

## `scripts/add-user.sh`

`scripts/add-user.sh <username> <email> [users|admins] [display name]`

Adds an Authelia account with a random password that is hashed immediately and never shown; the person sets their own with **Reset password** on the sign-in page. Rejects duplicate usernames and e-mail addresses. It reads and appends to `users.yml` through the Authelia container (the file is root-owned) and prints the next steps for the current notifier (e-mail or notification file). Removing a user: delete their block from `users.yml` with `docker compose exec authelia` and, for their OpenClaw browsers, press Revoke in the dashboard.

| Argument | Description | Example value | Required |
|---|---|---|---|
| `username` | 2-32 chars: lower-case letters, digits, `.` `_` `-`; starts with a letter | `asha` | Yes |
| `email` | Where the reset link is sent | `asha@example.com` | Yes |
| `group` | `users` (OpenClaw via `/connect`) or `admins` (everything) | `users` | Optional (default `users`) |
| display name | Shown in Authelia and Grafana | `Asha` | Optional (default: username) |

---

## `scripts/nemoclaw-setup.sh`

Repeats, as one script, the commands that were run by hand for NemoClaw. Run the subcommands in this order (the full procedure is §17 of `gb10-agent-stack.md`). It reads `NEMOCLAW_SANDBOX` and `PUBLIC_HOST` from `.env` and the sandbox key from `secrets/litellm_keys.json`; keys are passed through environment variables and never printed.

| Subcommand | What it does | Needs |
|---|---|---|
| `install` | Installs the NemoClaw CLI with `http.version=HTTP/1.1` (GitHub drops HTTP/2 clones from this host) and `NEMOCLAW_NO_EXPRESS=1` (skips the DGX Spark "managed vLLM" menu). Retries 3 times. The installer then stops at its own onboarding because no NVIDIA CDI spec exists; that is expected | Internet |
| `ca` | Copies Caddy's root CA to `data/caddy-root.crt` | Caddy running |
| `onboard` | `nemoclaw onboard --fresh --recreate-sandbox --non-interactive --no-gpu` with the provider (`custom`, LiteLLM `http://host.openshell.internal:4000/llm/v1`, model `agent`), `NEMOCLAW_INFERENCE_INPUTS=text,image`, `NEMOCLAW_REASONING=true` and `NEMOCLAW_CORPORATE_CA_BUNDLE` (all build-time: change them later only by re-running this) | LiteLLM up, keys, `ca` |
| `mcp` | `nemoclaw <sandbox> mcp add comfy_image --url https://172.17.0.1:8443/llm/comfy_image/mcp --trusted-private-host 172.17.0.1` with the sandbox key stored in OpenShell | sandbox up |
| `config` | Applies `openclaw/openclaw.patch.json5` in the sandbox (`--dry-run` validates only) | sandbox up |
| `notes` | Adds a note to the agent's workspace `AGENTS.md` (*Tools → Local notes*): use the `comfy_image-generate_image` tool for images, paste the returned `markdown`, never invent the URL. Idempotent. Needed because OpenClaw hides MCP tools until the agent searches for them | sandbox up |

> The script was assembled from commands that each ran successfully on this host; it has not been executed end to end on a clean machine. See `TO-VERIFY.md`.

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
| `PUBLIC_HOST` | `.env` (the OpenClaw patch and Authelia/Grafana/ComfyUI links are derived from it) |
| `NEMOCLAW_SANDBOX` | `.env` → `scripts/nemoclaw-setup.sh` (the name given to NemoClaw), `compose.yaml` (passed to the dashboard, which matches it against container names) |
| `qwen3.6-35b` | `model-runner/llama-swap.yaml`, `litellm/config.yaml`, `scripts/create-litellm-keys.sh`, `observability/prometheus/prometheus.yml` (`model` label) |
| `agent` | `litellm/config.yaml`, `scripts/create-litellm-keys.sh`, `scripts/nemoclaw-setup.sh` (`NEMOCLAW_MODEL`) |
| Port `10001` | `model-runner/llama-swap.yaml`, `observability/prometheus/prometheus.yml` |
| `/llm` root path | `compose.yaml` (`SERVER_ROOT_PATH`), `caddy/Caddyfile`, `prometheus.yml`, `create-litellm-keys.sh`, NemoClaw provider URL |
| `bridge_dashboard_token` | `secrets/` → mounted into `ops-bridge` (checked against `actions.yaml` `clients.dashboard.token_file`) and `admin-dashboard` |
| `/connect` | `caddy/Caddyfile` route, `authelia/configuration.yml` rule `^/connect$`, `dashboard/app.py` route |
| `users` group | `authelia/users.yml`, `compose.yaml` (`USER_GROUP`) |
| `admins` group | `authelia/users.yml`, `authelia/configuration.yml`, `compose.yaml` (`ADMIN_GROUP`) |
| Workflow node IDs `1`–`7` (`comfy-mcp` uses 1, 2, 3, 4, 5, 7; the dashboard warm-up uses 2, 4, 5) | `flux-schnell-api.json`, `comfy-mcp/server.py`, `dashboard/app.py` |
| Host ports 9091 · 4000 · 3000 · 8188 · 9000 | `compose.yaml`, `caddy/Caddyfile` |
| Caddy listener `127.0.0.1:9080` | `caddy/Caddyfile`, the `tailscale funnel` command |
| MCP listener `172.17.0.1:8443` | `caddy/Caddyfile` (`https://172.17.0.1:8443`), `scripts/nemoclaw-setup.sh` (`MCP_URL`, `--trusted-private-host`) |
| `DOCKER_BRIDGE_IP` | `.env` = the `openshell-docker` network gateway = what the sandbox resolves `host.openshell.internal` to (check with `docker exec <sandbox> getent hosts host.openshell.internal`) |
| Caddy root CA | `caddy_data` volume → `data/caddy-root.crt` → `NEMOCLAW_CORPORATE_CA_BUNDLE` baked into the sandbox at onboarding |
| OpenClaw port `18789` | `caddy/Caddyfile` only; the sandbox forward is created by NemoClaw, not compose |
| Checkpoint filename | `flux-schnell-api.json`, file in `${MODELS_DIR}/comfy/checkpoints/` |
