# To verify

Things that were assumed or written from memory and have **not** been tested. Check them as the stack comes up, then tick them off.

Last updated: 2026-10-21 (after the compose.yaml review)

---

## Likely to matter on first start-up

- [ ] **Read-write `users.yml` mount.** `compose.yaml` mounts `./authelia/users.yml` read-write over the read-only `./authelia` directory. Authelia may fail to save a password change through a single-file bind mount. If it does, mount the directory read-write instead.
- [ ] **Prometheus reading the LiteLLM key.** `secrets/litellm_master_key` is mode 644 (and `scripts/init-secrets.sh` sets it) on the guess that Prometheus, running as `nobody`, cannot read a mode 600 file. Confirm the `litellm` scrape target is up.
- [x] **Login redirects / `X-Forwarded-Proto`.** The Caddyfile now forces `X-Forwarded-Proto https` on the Authelia sub-request (tested: Authelia sees `https` whether the client sends nothing, `http` or `https`). Still confirm on the real Funnel that the post-login redirect lands on `https://`.
- [x] **Caddy routing, gating, spoofing, path tricks, WebSocket.** Tested the Caddyfile with pinned Caddy 2.11.7 against mock upstreams and a mock Authelia: all protected paths redirect when unauthenticated; no `..`/encoded/odd-path form reached LiteLLM unauthenticated; `Remote-*` spoofing fails; a real WebSocket upgrade through `/openclaw` returns 101, carries `Remote-User`, echoes data and survives 20 s idle. Not tested: the real Tailscale Funnel in front, long streaming responses, and real OpenClaw.
- [ ] **Cookie on a `ts.net` host.** `ts.net` is on the public suffix list. The host is a subdomain of it, so it should be accepted; only a real login confirms it.
- [x] **Hugging Face gating.** Neither `nvidia/Qwen3.6-35B-A3B-NVFP4` nor `Qwen/Qwen3-VL-30B-A3B-Instruct` is gated or private; no token is needed. Both were downloaded (80 GB total, all 17 + 25 files with matching sizes) to `/srv/models/hf/hub`; the Qwen3-VL one is no longer used (see below).

## Versions chosen but never run

All 13 tags in `.env` were checked to exist with an arm64 build. None were pulled or started, and config compatibility was not tested.

- [ ] **Tempo `2.10.9`.** Stayed on 2.x because 3.x changed the architecture. Not tested whether `observability/tempo/config.yaml` works on 3.x.
- [ ] **LiteLLM `v1.106.2`.** Skipped the older `-stable` line (`v1.83.14-stable.patch.3`). Not checked whether Prometheus metrics or the MCP gateway need a paid licence in this version.
- [ ] **Grafana `13.2.4`** (`grafana/grafana`, not `grafana-oss`, which stops at 13.0.x). Not checked against the auth-proxy settings or `gb10-overview.json`.
- [ ] **OpenShell gateway `0.1.5`.** Not checked against OpenShell's upstream compose (`OPENSHELL_GRPC_ENDPOINT`, `/var/lib/openshell`).
- [ ] **cAdvisor `v0.60.6`** (`ghcr.io/google/cadvisor`). Assumed it supports Docker 29.
- [ ] **llama-swap `265`.** The `linux_arm64` asset exists; the `--watch-config` flag and config format were not checked against this version.

## Commands and behaviour written from memory

- [ ] **Credential-reset commands.** Run `authelia storage user --help` and confirm:
  ```
  docker compose exec authelia authelia storage user totp delete <username> --config /config/configuration.yml
  docker compose exec authelia authelia storage user webauthn delete <username> --all --config /config/configuration.yml
  ```
- [ ] **Recovery flow.** The identity-verification link being written to `/data/notification.txt`, and its short expiry.
- [ ] **Self-service password change** now that `users.yml` is writable (see the first item above).

## Open items from the design doc (§19)

- [ ] NemoClaw "reuse existing gateway" with a containerised OpenShell gateway.
- [ ] OpenClaw config (`basePath`, `trusted-proxy`, plugins) persisting inside a NemoClaw sandbox.
- [ ] The sandbox reaching `host.openshell.internal:4000` and `:4318` under the chosen policy.
- [x] LiteLLM `SERVER_ROOT_PATH=/llm`: API, `/llm/metrics/` and MCP work (see the LiteLLM tests below). The admin UI itself was not opened in a browser.
- [ ] Whether Qwen3.6-35B-A3B is multimodal (if so, the vision model can be dropped).
- [ ] vLLM `--tool-call-parser qwen3_coder` and `--reasoning-parser qwen3` being right for Qwen3.6.
- [ ] The llama-swap per-model unload endpoint used by the dashboard's Down button (returns `501` if absent).
- [ ] Tailscale Funnel's request header name, for the optional tailnet-only admin hardening.

## Checked with debug containers (compose.yaml review)

- [x] **GPU access.** `--gpus all` and compose `deploy…devices` both work on this host; `runtime: nvidia` does not (no NVIDIA runtime is registered in Docker). `gpu-exporter` now uses the shared `*gpu` block. Tested `nvidia-smi` and `collect.sh` from the built image; the real stack has not been started.
- [x] **Alloy through `docker-socket-proxy`.** Needs `NETWORKS: 1` on the proxy (Alloy's discovery calls `GET /networks`). With it, a minimal Alloy config tailed a test container's logs with no errors, and the proxy returned 403 for container creation.
- [ ] **Edited `observability/alloy/config.alloy` on the real stack.** Only its syntax (`alloy fmt`) and a minimal test config were run; confirm logs reach Loki (Grafana Explore, label `container`).
- [x] **Grafana built-in admin.** `admin:admin` worked over basic auth even with the login form disabled. Now `GF_SECURITY_ADMIN_PASSWORD__FILE` reads `secrets/grafana_admin_password`; in a debug container `admin:admin` gives 401, the secret gives 200, and a `Remote-User` header still signs in a proxy user. Not yet confirmed through Caddy and Authelia on the real stack. The password only applies when Grafana creates its database, so changing the secret later needs `grafana-cli admin reset-admin-password`.
- [ ] **cAdvisor** still sees `docker.sock` through its `/var/run` mount and is privileged. Accepted; documented in the design doc.

## Checked with debug containers (litellm/config.yaml review)

- [x] **LiteLLM `v1.106.2` with the repo config, Postgres 17.11 and the real `comfy-mcp` image** (mock model server): starts and migrates, no licence errors (Prometheus callback and MCP gateway both work); `agent`, `qwen3.6-35b`, `qwen3-vl-30b` all route, and `agent` reaches the upstream as `qwen3.6-35b` (matches `--served-model-name`); key allow-list, RPM cap and admin-endpoint denial are enforced.
- [x] **MCP gateway paths and permissions.** The working URL is `/llm/comfy_image/mcp`; `/llm/mcp/` fails (parsed as server `llm`). Tools are `comfy_image-generate_image` and `comfy_image-list_checkpoints`. Keys have no MCP access by default, so `create-litellm-keys.sh` now grants the configured servers to `openclaw-sandbox` (tested: sandbox key lists tools; `laptop` key is refused).
- [ ] **OpenClaw MCP client config.** Nothing in `openclaw/openclaw.snippet.json5` points OpenClaw at `http://host.openshell.internal:4000/llm/comfy_image/mcp` yet; confirm how OpenClaw/NemoClaw registers MCP servers and add it.
- [ ] **`trusted_proxy_ranges`.** Added (`127.0.0.1/32`, `172.16.0.0/12`); the start-up warning is gone. Not verified: that admin-UI login throttling now keys on the real client IP behind Caddy (the `client_ip` metric label still shows the bridge address).
- [ ] **Real model calls.** Only a mock upstream was used; tool-call and reasoning parsing against real vLLM output is untested.

## Checked with debug containers (model-runner/Dockerfile review)

- [x] **Image builds** (`docker compose build model-runner` with the pinned `.env`): `llama-swap v265` runs on arm64 with the flags in the ENTRYPOINT; the base image is vLLM `0.29.0` / torch `2.14.0a0` (NGC 26.09). `pip check` reports a `nvidia-cutlass-dsl` mismatch, but it is already in NVIDIA's base image, not caused by this Dockerfile. The base image already ships the same OpenTelemetry packages (1.44.x), so the Dockerfile's `pip install` step is a no-op. The ENTRYPOINT override skips NVIDIA's banner and GPU/driver/shm checks only.
- [x] **llama-swap behaviour** (tiny public model `Qwen/Qwen2.5-0.5B-Instruct`, same config structure): cold start on first request (about 30 to 45 s), `/running`, `GET /upstream/<id>/health` starts a stopped model (dashboard Up), `POST /api/models/unload/<id>` returns 200 and empties `/running` (dashboard Down; closes the doc's open item), and `ttl` unloads an idle model ("TTL of 120s reached"). vLLM `/health` and `/metrics` (373 `vllm:` series) work on the fixed port 10001. The `hermes` tool-call parser returned a proper `tool_calls` entry for the tiny model.
- [x] **FlashAttention on this GPU.** The tiny test model (head_dim 64) crashed with the default `FLASH_ATTN` backend (`No device code available for GPU ISA 121`); `--attention-backend TRITON_ATTN` fixed it. The **real Qwen3.6-35B-A3B NVFP4 works with the defaults** (still `FLASH_ATTN`, CUDA graphs captured, repo `llama-swap.yaml` unchanged), so no flag is needed for it.
- [x] **vLLM logs now reach the container log.** `logToStdout: both` added to `llama-swap.yaml`; with the repo config the real model's vLLM lines (`APIServer`, `EngineCore`) appear in `docker logs` within seconds of a cold start, next to llama-swap's own `[INFO]` lines. It only takes effect when the container starts, not on a hot config reload. Not yet seen in Loki on the real stack.
- [x] **Redundant `pip install` removed** from `model-runner/Dockerfile` (the base image already has OpenTelemetry 1.44.x); rebuilt image imports the OTLP exporters and vLLM reports tracing available. The real agent model cold-started and answered on the rebuilt image.
- [ ] **OTLP traces when Alloy is down.** vLLM keeps retrying `alloy:4317` and logs transient errors but starts fine; confirm traces appear in Tempo once Alloy is up.
- [x] **Real model, parsers and capabilities** (Qwen3.6-35B-A3B NVFP4 on the GB10, repo config): `qwen3_coder` returns a proper `tool_calls` entry; the `qwen3` reasoning parser puts thinking in a `reasoning` field (with `content: null` until thinking ends, so clients need a generous `max_tokens`); it **accepts images** (identified a red test square). First cold start 329 s (includes first-time compile while a download ran); decode about 72 tokens/s; about 47 GB of unified memory in use with the model loaded (74 GB still available); KV cache 443k tokens at the 0.30 setting.
- [x] **Qwen3-VL-30B dropped (decision).** Removed from `llama-swap.yaml` (also its group), `litellm/config.yaml`, `prometheus.yml` (`vllm-vision` job), `create-litellm-keys.sh`, `openclaw.snippet.json5` (`imageModel`), the Dockerfile `EXPOSE`, and the docs. Both LiteLLM entries now carry `supports_vision: true`; configs validated (llama-swap `-validate`: 1 model; `promtool`; LiteLLM started and routed an image request). The memory budget gains about 24 GB of headroom.
- [ ] **Real-image quality of the agent model.** Only a flat colour test image was tried. Check screenshots, charts and small text, and that image tokens fit in `--max-model-len 65536`. If quality is not good enough, the vision model can be re-added from git history.
- [ ] **Qwen3-VL weights still on disk.** About 62 GB in `/srv/models/hf/hub/models--Qwen--Qwen3-VL-30B-A3B-Instruct`; safe to delete if you will not use it (it was downloaded as your user, so a normal `rm -r` works).
- [ ] **`reasoning` vs `reasoning_content`.** vLLM returns the thinking text in `reasoning`. Check that LiteLLM passes it through and that OpenClaw reads that field name.

## Checked with debug containers (comfyui review)

- [x] **ComfyUI image builds and runs** (`docker compose build comfyui`, pinned `v0.42.1`, NVIDIA PyTorch 26.09): PyTorch is untouched by the requirements filter (same `2.14.0a0+nv26.09` as the vLLM image), CUDA works on the GB10, and ComfyUI reports `NVIDIA GB10` with DynamicVRAM enabled. `pip check` only lists packages from NVIDIA's base image. Mounting only `${MODELS_DIR}/comfy/checkpoints` over `/opt/ComfyUI/models` is fine: ComfyUI still knows every model category.
- [x] **FLUX checkpoint.** `flux1-schnell-fp8.safetensors` (17.2 GB) downloaded from `Comfy-Org/flux1-schnell` into `/srv/models/comfy/checkpoints`; size matches Hugging Face; the runbook now has the download command.
- [x] **comfy-mcp to ComfyUI end to end** (real `comfy-mcp` image, real model): `list_checkpoints` returns the checkpoint; `generate_image` returns a valid 768x768 PNG plus metadata, 11 s on the first call and about 5 s warm. The workflow node IDs match `comfy-mcp/server.py`. Not tested: the dashboard's Warm button and its tiny 256 px workflow.
- [x] **Idle unload.** `POST /free` (what the dashboard's idle watcher sends) released about 16 GB of available memory; the next generation reloaded the model from the page cache in 7 s. Reloading from cold disk will be slower.
- [x] **`/comfy/` behind Caddy** (real ComfyUI, repo Caddyfile, mock login): unauthenticated requests redirect; authenticated ones get the page (relative asset links), `/comfy/api/...`, generated images via both `/comfy/api/view` and `/comfy/view`, and a real WebSocket upgrade (101, first status frame). Frontend `1.55.18` builds its API and WS URLs from `location.pathname`, so the prefix is honoured; the only absolute path in the bundle is `/oauth/authorize` (cloud login, unused). **Not tested in a real browser**; open `/comfy/` once and run a workflow.
- [ ] **Pin the ComfyUI frontend.** The frontend comes with `comfyui-frontend-package` from ComfyUI's requirements, so it moves with `COMFYUI_REF`. Re-test `/comfy/` after every ComfyUI bump.
- [ ] **Unified-memory reporting.** ComfyUI showed only 0.8 GB "VRAM free" at start-up while 89 GB was page cache (after the downloads). Generation still worked and `/free` returned memory, but watch for ComfyUI falling back to low-VRAM mode when the cache is full.
- [ ] **Output ownership.** ComfyUI runs as root, so images in `./data/comfy-output` will be root-owned (you can still delete them: you own the folder).

## Checked with debug containers (comfy-mcp review)

- [x] **Real chain tested through the LiteLLM MCP gateway** (real ComfyUI + FLUX, real `comfy-mcp`, LiteLLM v1.106.2 + Postgres, sandbox key from the repo script): tools list, generation, clamping (`99999x40` becomes `2048x256`, `999` steps becomes `50`), serial queueing of concurrent calls (3.1 / 6.1 / 9.2 s), a bad checkpoint name and a `../../etc/passwd` checkpoint are rejected by ComfyUI with a clean tool error.
- [x] **Bug found and fixed: images over about 700 KB (PNG) failed through the gateway** (`MCPError: SSE stream ended without a response`; comfy-mcp logged `ClosedResourceError`). Threshold between 640 px (698 KB PNG, ok) and 704 px (788 KB, fails), i.e. a base64 message of about 1 MiB. The default 1024x1024 call failed every time. `comfy-mcp` now asks ComfyUI for a JPEG (`/view?preview=jpeg;<q>`, quality 90 stepping down to 40) inside `COMFY_MAX_IMAGE_BYTES` (default 700000). Retested: 1024 px = 329 KB, 1536 px = 420 KB, 2048 px = 686 KB, all ok via the gateway. The PNG stays in ComfyUI's output folder.
- [x] **Negative seed fixed.** `seed: -1` (which LLMs often send) was rejected by ComfyUI; negative or missing seeds are now random.
- [ ] **Limit on the OpenClaw side.** Not known whether OpenClaw/NemoClaw or the OpenShell proxy have their own size limits on tool results. Test a 1024 px image from the real agent.
- [ ] **Which component enforces the ~1 MiB limit** (LiteLLM's MCP client or the MCP SDK it uses) was not identified, so a LiteLLM upgrade may change it. Re-run the size test after bumping `LITELLM_IMAGE`.
- [ ] **Output folder growth.** Every generation saves a PNG (0.4 to 1.5 MB) to `./data/comfy-output` and nothing cleans it up.
- [ ] **Empty prompt** is accepted and generates an arbitrary image; add validation if that matters.

## Checked with debug containers (dashboard review)

- [x] **Dashboard against real dependencies** (built image behind the repo Caddyfile with a mock login; real llama-swap, ComfyUI, docker-socket-proxy, Prometheus, node-exporter, gpu-exporter): status shows models, ComfyUI state, memory (113 of 121.6 GiB), GPU (util, temp, power, collector age), and the container list. Unauthenticated requests redirect; the `users` group sees no buttons and gets 403 on Up, Down, Warm and Free; admins can use all four.
- [x] **Buttons and idle watcher.** Warm loads FLUX (free memory drops about 16 GiB); Free releases it; the idle watcher unloaded it at 66 s with `COMFY_IDLE_MINUTES=1` (it polls once a minute, so the real unload happens 10 to 11 minutes after the last job). Model Up goes to `starting`; Down during start returns 200 and the state becomes `stopped`. Invalid ids are rejected (400/404).
- [x] **Bug found and fixed: node-exporter's `cpufreq` collector hangs on the GB10.** Intermittent, but a hung scrape piles up (node-exporter then answers 503 above its concurrency cap) and Prometheus saw `context deadline exceeded`, so the dashboard and Grafana had no memory or GPU data. 49 collectors tested one by one; only `cpufreq` hung. 7 of 30 scrapes succeeded with it, 30 of 30 without. `--no-collector.cpufreq` is now in `compose.yaml`. Root cause (some cpufreq sysfs read on this firmware) was not identified; CPU frequency metrics are not available.
- [x] **htmx is now vendored.** `dashboard/static/htmx.min.js` (htmx 2.0.4, byte-identical to the file in the official npm package, 0BSD) is served by the dashboard; the admin page loads no external URL. Tested through Caddy: 200 with the right hash after login, 302 without. Not tested in a real browser; open `/admin/` once and use a button. Update procedure is in `dashboard/static/README.md`.
- [x] **Manual Free no longer flips back to `hot`.** `free_comfy` now records the latest history entry. Tested: after Warm then Free the state stayed `unloaded` for 120 s across several watcher polls, and a new Warm job still turned it `hot`.
- [x] **Down on an unknown model** now returns 404 `Unknown model '<id>'` (501 is kept only for a missing endpoint).
- [ ] **Smaller:** the Idle column is always "—" for LLM models; the container list shows every container on the host; the sign-out link `/auth/logout` serves Authelia's page (200), but ending the session was not verified.
- [ ] **First Prometheus scrapes of node-exporter timed out right after start-up** in the test (the same `cpufreq` hang); confirm the Grafana overview is populated once the stack runs with the new flag.

## Checked with debug containers (model-runner cache volume)

- [x] **Cold-start time of the agent model, measured** (real Qwen3.6-35B-A3B NVFP4, run as root like compose, fresh container each time unless noted): empty caches **332 s**; with the vLLM and Triton caches **about 250 s**; with the CUDA JIT cache added **201 s**. Reload inside the same container with everything warm: 184 s.
- [x] **Where the time goes (201 s):** weight loading about 130 s, other initialisation about 60 s, `torch.compile` 0.5 s (cached), CUDA-graph capture 1 s. Without the CUDA cache, graph capture took 46 to 49 s in every new container (the driver JIT-compiles PTX for `sm_121`).
- [x] **Cache settings added to `compose.yaml`:** `vllm_cache` volume at `/cache`; `XDG_CACHE_HOME`, `TRITON_CACHE_DIR`, `CUDA_CACHE_PATH`, `CUDA_CACHE_MAXSIZE` (4 GiB). The cache holds about 160 MB (`vllm` 46 MB, `triton` 61 MB, `cuda` 55 MB). `TORCHINDUCTOR_CACHE_DIR` stayed empty in the test, so it is not set.
- [x] **`--safetensors-load-strategy prefetch` does not help:** weight loading was 124 s with it and 123 to 130 s without, so it is not page-fault bound. Not tried: `eager`.
- [ ] **Why weight loading takes about 130 s** (roughly 190 MB/s for 21.8 GiB, with the page cache warm) is unexplained; it looks CPU-bound (NVFP4 weight processing) rather than disk-bound. Not investigated further.
- [ ] **Cache after upgrades.** vLLM keys its compile cache by version/config, so a vLLM bump compiles once more and leaves old entries; the CUDA cache evicts at 4 GiB. If a start misbehaves after an upgrade, `docker volume rm ai-stack_vllm_cache`.
- [ ] **ComfyUI** also loses its CUDA JIT cache when its container is re-created; not measured (its first generation took 11 s versus 5 s warm).
- [ ] **The test mounted the weights read-only.** The real compose mount is read-write and runs as root, so the model cache folder may gain root-owned lock files.

## Checked with debug containers (observability/*)

Ran prometheus, loki, tempo, alloy, grafana, docker-socket-proxy, node-exporter, gpu-exporter, cadvisor and litellm in a throwaway compose project (`-p obstest`, removed afterwards).

- [x] All configs load with no errors; Prometheus targets alloy, cadvisor, litellm, loki, node, prometheus, tempo are up (vllm-agent is down until the model is loaded, as designed).
- [x] OTLP/HTTP into Alloy: traces reach Tempo, logs reach Loki (label `service_name`), metrics reach Prometheus; Tempo span-metrics and service-graph series appear in Prometheus (after ~1 min).
- [x] Container logs reach Loki through the socket proxy (labels `container`, `service`).
- [x] LiteLLM's own traces reach Tempo (service `litellm`).
- [x] Grafana datasources Prometheus, Loki and Tempo report healthy; dashboard `GB10 · AI Stack Overview` is provisioned; proxy login via `Remote-User` works and no header gives 401.
- [x] Every dashboard query returns data except the vLLM ones (need a loaded model). The vLLM metric names (`vllm:num_requests_running`, `..._waiting`, `time_to_first_token_seconds`, `generation_tokens`) match the installed vLLM source.
- [ ] vLLM panels with a real loaded model.
- [ ] Loki derived field (TraceID link) clicked in the Grafana UI; the regex matches the log line format Alloy writes (`"traceid":"..."`).
- [ ] LiteLLM redirects `/llm/metrics` to `/llm/metrics/`; Prometheus follows it and the target is up, so the `metrics_path` tweak is optional.

## OpenClaw / NemoClaw: findings from the vendor docs (not run on this host)

Read from docs.openclaw.ai and docs.nvidia.com/nemoclaw (latest). Nothing below has been executed.

- [ ] **Containerised gateway is probably not supported.** NemoClaw's only external-gateway mode (`NEMOCLAW_GATEWAY_MANAGEMENT`, `externally-supervised`) accepts only a systemd-supervised process, with the endpoint on `127.0.0.1`/`[::1]` and the process inside the unit's cgroup. Our compose gateway is a container published on the docker0 address. Default mode is NemoClaw-managed. Needs a decision (see report).
- [ ] **Inference goes through OpenShell, not the sandbox.** The sandbox calls `https://inference.local/v1`; OpenShell forwards to the endpoint entered at onboarding and holds the key. A manually typed `host.openshell.internal` URL skips host-side probing. Private addresses are blocked unless listed in `NEMOCLAW_TRUSTED_PRIVATE_HOSTS`.
- [ ] **Snippet `agents.defaults.model.primary: "agent"` is probably wrong or redundant.** NemoClaw writes the model reference itself during onboarding. Check the generated config before keeping it.
- [ ] **Image input and reasoning are build-time settings:** `NEMOCLAW_INFERENCE_INPUTS=text,image` and `NEMOCLAW_REASONING=true` before `nemoclaw onboard` (non-interactive onboarding defaults to text only). Changing them needs `nemoclaw onboard --fresh --name <n> --recreate-sandbox`.
- [x] **openclaw.json persists.** It is authoritative after first launch; restart keeps it; rebuild restores the pre-rebuild copy. Edit inside the sandbox with `openclaw config set` / `openclaw configure`. NemoClaw does not lock it. OpenClaw config cannot widen the network policy.
- [ ] **Managed MCP does not fit our MCP URL.** `nemoclaw <sandbox> mcp add` needs an HTTPS URL, one bearer credential via `--env`, and rejects `host.openshell.internal`. Our plain-HTTP `host.openshell.internal:4000/llm/comfy_image/mcp` is not accepted. Also `/llm/comfy_image/mcp` currently sits behind Authelia in `Caddyfile` (`handle /llm*`), so a machine client could not use the public URL either. Request bodies are capped at 131072 bytes by the MCP policy.
- [x] Snippet keys all exist in the OpenClaw docs: `gateway.auth.rateLimit`, `trustedProxy.userHeader/allowLoopback`, `controlUi.basePath`, `publicOrigin`, `diagnostics.otel.*`, and the `plugins.allow/entries` form for diagnostics-otel (the plugin may need `openclaw plugins install @openclaw/diagnostics-otel`, which needs network access).
- [ ] The Control UI forward is created by NemoClaw (`nemoclaw onboard --control-ui-port`, default 18789). Not documented: bind address, and what source IP the gateway sees through the forward (matters for `trustedProxies`/`allowLoopback`).

### Decisions applied after reading those docs

- [x] **Gateway:** NemoClaw creates and manages it. Removed `openshell-gateway` from `compose.yaml`, `OPENSHELL_GATEWAY_IMAGE` and `DOCKER_GID` from `.env.example` (your own `.env` still has the two unused lines; harmless), the `openshell/` placeholder dir, and the dashboard's gateway probe (`app.py`, `status.html`).
- [x] **MCP route:** `caddy/Caddyfile` has a key-only `@mcp` route (`/llm/*/mcp`, `/llm/*/mcp/*`) that skips Authelia and strips `Remote-*`, like `/llm/v1/*`. Tested with real Caddy, LiteLLM and comfy-mcp: no key 401; `openclaw-sandbox` key lists both tools; `laptop` key 403; `Remote-User` spoof 400; `/llm/ui/` still gated. (Test stack and the keys it created were removed, so `scripts/create-litellm-keys.sh` must be run again on the real stack.)
- [x] **Snippet:** `agents` block removed; header says to apply with `openclaw config set` / `openclaw configure`.
- [ ] `nemoclaw onboard` accepting `http://host.openshell.internal:4000/llm/v1` (may need `NEMOCLAW_TRUSTED_PRIVATE_HOSTS=host.openshell.internal`).
- [ ] `nemoclaw my-assistant mcp add comfy_image --url https://<PUBLIC_HOST>/llm/comfy_image/mcp --env LITELLM_MCP_KEY` works through Funnel (hairpin from the sandbox to the public hostname), and the resulting tool names.
- [ ] Sandbox egress to `host.openshell.internal:4318` for OTLP (custom policy preset) and the diagnostics-otel plugin install.
- [ ] The MCP request-body cap (131072 bytes) is on requests only; tool results (JPEG, under 700 KB) are responses.

## Still to review in compose.yaml

- [ ] **Host folders.** `/srv/models` does not exist (`/srv` is root-owned). Create `hf/` and `comfy/checkpoints/` and chown them to yourself before starting. The ComfyUI mount hides the image's own `models/` subfolders.
- [x] **LiteLLM tracing.** Tested `ghcr.io/berriai/litellm:v1.106.2` (mock model, `callbacks: [prometheus, otel]`, `SERVER_ROOT_PATH=/llm`) against an HTTP sink. With `OTEL_ENDPOINT=http://host:4318` and with `.../v1/traces`, LiteLLM posts protobuf to `/v1/traces`, so the current compose value is right. Not yet seen reaching the real Alloy and Tempo.
- [ ] **`/llm/metrics` redirect.** Same test: `/llm/metrics` returns 307 to `/llm/metrics/`; `/llm/metrics/` returns 200 with the key (108 `litellm_` metrics) and 401 without it. Prometheus should follow the redirect; consider setting `metrics_path: /llm/metrics/` in `observability/prometheus/prometheus.yml`.
- [x] **LiteLLM requires a master key.** v1.106 refuses to start without one (`UnsafeMasterKeyError`). The stack sets it through `secrets/litellm.env`, so this is fine; just don't remove it.
- [x] **Tempo metrics generator.** Tested `grafana/tempo:2.10.9` with the repo's `tempo/config.yaml` and a real Prometheus (remote-write receiver on): the generator runs in single-binary mode; a client→server trace pair was stored (2 spans) and Prometheus received `traces_spanmetrics_*` and `traces_service_graph_*` with the edge `openclaw-gateway -> litellm`, which is what the Grafana Tempo datasource's service map reads. One harmless `failed to find segment for index` line at first WAL start. Real OpenClaw/LiteLLM/vLLM spans through Alloy are still untested.
- [ ] **node-exporter** reports the container's network stats, not the host's.
- [x] **Unpinned images.** Pinned in `compose.yaml` to arm64-capable tags: `caddy:2.11.7-alpine`, `authelia/authelia:4.39.28` (the version used for `config validate`), `postgres:17.11-alpine`, `tecnativa/docker-socket-proxy:v0.5.0` (same digest as the `latest` tested with Alloy). Caddy and Postgres 17.11 have not been started yet.

## Decided, but not yet written into the docs

- [ ] `VARIABLES.md` / `gb10-agent-stack.md`: the read-write `users.yml` mount, the admin-run Authelia recovery steps, `two_factor` kept, passkeys as a second factor only (no `enable_passkey_login`), no SMTP.
- [ ] `VARIABLES.md` `secrets/`: only the `secrets/` directory is `chmod 700` (files are 600, the master key 644); `hf_token` can be left empty.
