# Variables reference

What you set, where, and which values must agree. Only settings you might change are listed; everything else is wired in `compose.yaml`. Image tags in `.env.example` were verified on this GB10 (arm64, CUDA 13, `sm_121`): bump them deliberately and retest.

## `.env`

Created from `.env.example` by `scripts/init-secrets.sh`. Holds no secrets. After editing: `docker compose up -d`.

| Variable | Meaning | Default / example |
|---|---|---|
| `PUBLIC_HOST` | **Set this.** Your Tailscale name, no scheme. Used for the Authelia cookie and rules, redirects, Grafana URL, OpenClaw origin | `gb10.tail1234.ts.net` |
| `DOCKER_BRIDGE_IP` | **Check.** What the sandbox sees as `host.openshell.internal`; LiteLLM `:4000` and Alloy `:4318` publish on it. Must equal the gateway of the `openshell-docker` network, known only after the first onboard (README step 5). Re-check after any recreate of that network and after a reboot | `172.17.0.1`, later `172.21.0.1` |
| `MODELS_DIR` | Model weights: `hf/` for vLLM, `comfy/` for ComfyUI | `/srv/models` |
| `TZ` | Timezone | `UTC` |
| `PORTAINER_IMAGE` | Portainer EE tag (arm64). Needs a license, entered in the UI | `portainer/portainer-ee:2.45.3` |
| `*_IMAGE`, `LLAMA_SWAP_VERSION`, `COMFYUI_REF` | Pinned versions | see `.env.example` |
| `COMFY_IDLE_MINUTES` | Idle time before the dashboard frees ComfyUI | `10` |
| `TTYD_UID`, `TTYD_GID` | uid/gid the browser-terminal container runs as. Must own `secrets/ssh_ca` (mode 600): the user that ran `init-secrets.sh` (`id -u`, `id -g`) | `1000` |
| `NOTEBOOK_MEM_LIMIT` | Memory cap for each person's notebook container, no swap (shared with the GPU on the GB10) | `16g` |
| `MINIO_IMAGE`, `MC_IMAGE` | MinIO (pgsty community fork) and its `mc` admin tool, pinned. Upstream's images are gone; bump deliberately and retest | `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` |
| `JUPYTERHUB_VERSION` | JupyterHub image tag and the `jupyterhub` package inside the notebook image. Keep both equal: rebuild `jupyterhub` and `notebook-image` together | `5.5.4` |
| `COMFY_DEFAULT_STEPS` | Sampler steps for `generate_image` | `4` |
| `NEMOCLAW_SANDBOX` | Sandbox name given to `nemoclaw onboard`; ops-bridge and the dashboard find its container (`openshell-default--<name>-<id>`) by it | `nemoclaw-assistant` |
| `SMTP_ADDRESS` | Empty = Authelia writes links to `/data/notification.txt`. Otherwise `smtp://host:587` (STARTTLS) or `submissions://host:465` (TLS); plaintext is refused | `smtp://smtp-relay.brevo.com:587` |
| `SMTP_USERNAME` | SMTP login (Brevo: the login under *SMTP & API*, not your account e-mail; Resend: `resend`) | `a1b2c3001@smtp-brevo.com` |
| `SMTP_SENDER` | From address; must be verified at the service. Same-domain sender and recipient on a freemail domain can be silently dropped | `auth@yourdomain.com` |

## `secrets/`

Created by `scripts/init-secrets.sh`, never overwritten; one value per file without trailing newline; git-ignored; folder mode 700.

| File | Meaning |
|---|---|
| `authelia_jwt`, `authelia_session`, `authelia_storage_key` | Authelia secrets (generated) |
| `litellm_master_key`, `litellm_db_password`, `litellm.env` | LiteLLM admin key, Postgres password, and the env file LiteLLM loads (generated). Master key is mode 644 so Prometheus can scrape |
| `grafana_admin_password` | Built-in Grafana `admin` (generated, mode 644); day-to-day access is through Authelia |
| `bridge_dashboard_token` | Dashboard's credential for ops-bridge (generated, mode 644) |
| `ssh_ca`, `ssh_ca.pub` | SSH certificate authority for the browser terminal: `ttyd/gb10-shell` signs one-minute certificates with the private key (mode 600, read by the ttyd container); the host's dedicated sshd trusts the public key (`TrustedUserCAKeys`). Anyone holding the private key can log in as any `gb10-users` account, never as admin (generated) |
| `bridge_jupyterhub_token` | JupyterHub's credential for ops-bridge; it may call only `notebook.*` (generated, mode 644) |
| `jupyterhub_cred_secret` | Held only by JupyterHub: each person's LiteLLM key and storage key are derived from it, so they are the same on every start. Rotating it changes everyone's keys (they are recreated at the next start) (generated, mode 644) |
| `minio_root_password`, `minio_oidc_secret`, `minio_oidc_client_hash`, `minio.env` | MinIO root account (`S3ROOT`), its OIDC client secret and the hash Authelia holds, and the env file that carries them to `minio` and `minio-mc` (generated) |
| `jupyterhub_oidc_secret`, `jupyterhub_oidc_client_hash` | JupyterHub's OIDC client secret and the PBKDF2 hash Authelia holds (generated) |
| `authelia_smtp_password` | SMTP password / API key. Empty unless SMTP is on. `read -rs k && printf '%s' "$k" > secrets/authelia_smtp_password` |
| `authelia_oidc_hmac`, `authelia_oidc_jwks_key` | Authelia OpenID Connect provider: HMAC secret and RSA signing key (generated) |
| `portainer_oidc_secret`, `portainer_oidc_client_hash` | Portainer's OIDC client secret (plain, used by `scripts/portainer-setup.sh`) and its PBKDF2 hash (in the Authelia config) (generated) |
| `grafana_oidc_secret`, `litellm_oidc_secret`, `*_oidc_client_hash` | OIDC client secrets for Grafana and LiteLLM and the PBKDF2 hashes Authelia holds for all three clients (generated; the LiteLLM secret is also appended to `litellm.env` as `GENERIC_CLIENT_SECRET`) |
| `portainer_admin_password` | Portainer's break-glass `admin` account (generated); day-to-day login is Authelia |
| `hf_token` | Hugging Face token; may be empty (models are not gated) |
| `litellm_keys.json` | Virtual keys from `scripts/create-litellm-keys.sh` (`openclaw-sandbox`, `laptop`, `scripts`) |

## Users (Authelia)

`authelia/users.yml` (git-ignored, copied from `users.yml.example`). Authelia watches it; changes apply without a restart. It is root-owned and in a read-only folder, so read and write it through the container (`sed -i` fails):

```bash
docker compose exec -T authelia cat /config/users.yml
docker compose exec -T authelia sh -c 'cat > /config/users.yml' < edited.yml
```

| Field | Meaning |
|---|---|
| `<username>` | Login name |
| `displayname`, `email` | Shown in the UI, passed to Grafana. The e-mail receives reset links |
| `password` | Argon2id hash: `docker run --rm -it authelia/authelia:4.39.28 authelia crypto hash generate argon2` |
| `groups` | `admins`: everything, including ComfyUI, the dashboard controls and *Temporary sudo*. `users`: the dashboard landing page (`/home/`, read-only status), `/openclaw`, `/connect`, Grafana (Viewer), Portainer and Jupyter notebooks (own containers), Storage (own bucket and `shared`) and the Terminal (own Linux account; created on the host for `admins` and `users` alike). `litellm`: LiteLLM UI SSO, in addition to `users` or `admins`; keep it to 5 people (LiteLLM's free SSO limit) |

Add people with `scripts/add-user.sh <username> <email> [users|admins] [display name]`: it creates the account with a random, never-shown password and rejects duplicates; the person sets their own via **Reset password**. Remove a person by deleting their block from the file and revoking their devices in the dashboard. Every protected path needs a second factor (TOTP and passkeys both work; passkeys are second-factor only). If someone loses all factors:

```bash
docker compose exec authelia authelia storage user totp delete <username> --config /config/configuration.yml
docker compose exec authelia authelia storage user webauthn delete <username> --all --config /config/configuration.yml
```

## Files you may change

| File | What to change |
|---|---|
| `authelia/configuration.yml` | Templated from `.env`. Session lengths, lockout, access rules (`group:admins` / `group:users` per path; `/llm` is `admins` + `litellm`; `/comfy` admins only), the OIDC clients (`portainer`, `grafana`, `jupyterhub`, `minio`, `litellm`) and their authorization policies. Notifier switches on `SMTP_ADDRESS` |
| `caddy/Caddyfile` | Routes. Listeners `127.0.0.1:9080` (Funnel target), `https://172.17.0.1:8443` (sandbox MCP; must equal `MCP_URL` in `nemoclaw-setup.sh`) `http://172.17.0.1:9081` (OIDC token/userinfo for Grafana, LiteLLM, Portainer, JupyterHub) and `https://<PUBLIC_HOST>` on `172.17.0.1:443` (OIDC discovery for MinIO, Caddy's internal CA); upstream ports must match `compose.yaml`. `/brand/*` and `/favicon.ico` serve `branding/` |
| `litellm/config.yaml` | Model names (`agent`, `qwen3.6-35b`, `whisper`, `kokoro`; aliases `whisper-1`, `tts-1`; the dashboard's *Models* tab reads this file), the `comfy_image` MCP server, 900 s timeouts (must exceed a vLLM cold start), `trusted_proxy_ranges` (Docker address pools) |
| `model-runner/llama-swap.yaml` | The vLLM command: model ID, `--served-model-name` (matches LiteLLM and Prometheus), fixed port `10001`, `--gpu-memory-utilization 0.30`, `--max-model-len 262144` (keep equal to OpenClaw's context window), `--tool-call-parser qwen3_coder` (wrong value = empty `tool_calls`), `ttl: 0` + `preload` (always loaded). Whisper on port `10002` with `ttl: 300` and the two `sm_121` attention flags; the `groups` keep it from evicting Qwen. Hot-reloads and restarts vLLM: 3 to 4 minutes |
| `comfyui/workflows/flux-schnell-api.json` | `ckpt_name` must exist in `${MODELS_DIR}/comfy/checkpoints/`. `comfy-mcp` and the dashboard warm-up address nodes `1`–`7` by ID |
| `ops-bridge/actions.yaml` | The complete allow-list of container actions, per client token. Validated at start-up; the bridge refuses to start on a mistake. Header of the file documents every option |
| `openclaw/openclaw.patch.json5` | Applied in the sandbox by `nemoclaw-setup.sh config` (`__PUBLIC_HOST__` filled from `.env`): public origin, base path `/openclaw`, allowed origins. `gateway.auth` stays unset on purpose |
| `jupyterhub/jupyterhub_config.py` | OIDC client, `admin_groups`, spawn timeouts, idle culler (`--timeout=3600`) |
| `jupyter/` | The notebook image: `Dockerfile` (packages, pinned LiteLLM library), `notebook-start` (per-person settings, example copy), `jupyter_server_config.py` (`frame-ancestors 'self'` for the Voilà panel), `examples/`. Rebuild with `docker compose --profile images build notebook-image` |
| `minio/init.sh`, `minio/policies/` | Run by `minio-mc` at start: the `shared` bucket and the `admins` / `users` policies that the OIDC `groups` claim selects |
| `ttyd/` | `gb10-shell` (signs the certificate, opens the SSH session), `shift-enter.js` (Shift+Enter for Claude Code) |
| `host/` | Root-owned host side, installed with `sudo bash host/setup.sh` and `sudo bash host/elevate-setup.sh`; see `host/README.md`. Installed settings: `/etc/gb10/accounts.env` (`GB10_MEM_MAX`, `GB10_TASKS_MAX`, `GB10_CPU_QUOTA`) and `/etc/gb10/elevate.env` (default and maximum minutes, `GB10_ELEVATE_KEEP_DAYS`) |
| `branding/` | Logo and favicon for Authelia, LiteLLM, Portainer, Grafana and the dashboard; regenerate the PNG/ICO files with `scripts/make-branding.py` (the SVGs are hand-written to match) |
| `observability/*` | Prometheus targets and retention (30 d; Tempo 14 d), Alloy pipeline, Grafana provisioning and board |

Container environment (in `compose.yaml`): `comfy-mcp` — `COMFY_PUBLIC_URL` (link returned to the agent), `COMFY_INLINE_IMAGE=false` (inline images become huge base64 in OpenClaw's context), `COMFY_MAX_IMAGE_BYTES`, `COMFY_TIMEOUT_SECONDS`. Dashboard — `ADMIN_GROUP`, `USER_GROUP`, `BRIDGE_URL`, `OPENCLAW_ENROLL_MINUTES` (enrollment window, default 10); it mounts `/run/gb10-elevate` for the sudo daemon's socket. JupyterHub — `NOTEBOOK_NETWORK` (`ai-stack_notebooks`). ops-bridge — `BRIDGE_MAX_CONCURRENT` (4). Model-runner — cache paths on the `vllm_cache` volume (reset: `docker volume rm ai-stack_vllm_cache`).

## Scripts

| Script | Use |
|---|---|
| `init-secrets.sh` | First run: secrets, `.env`, `users.yml`, `data/` |
| `portainer-setup.sh` | `config`: Portainer environment, regular-user restrictions, `users` team, OAuth settings (re-runnable). `sso` / `local`: switch login between Authelia and Portainer accounts. Needs the license added in the UI first |
| `create-litellm-keys.sh` | After LiteLLM is up. `LITELLM_API` overrides the URL. Edit the three key definitions for other limits; MCP access goes to `openclaw-sandbox` only |
| `add-user.sh` | See Users |
| `make-branding.py` | Regenerates `branding/logo.png`, `favicon.ico` and the Grafana icon PNGs (needs Pillow and DejaVu Sans Mono Bold) |
| `nemoclaw-setup.sh` | `install`, `ca`, `onboard`, `mcp`, `config [--dry-run]`, `notes`; reads `.env` and `secrets/litellm_keys.json`, never prints keys. `onboard` sets build-time options (text+image input, reasoning, Caddy CA); change them only by running `onboard` again |

## Values that must match

| Value | Where |
|---|---|
| `PUBLIC_HOST` | `.env` only; everything else derives from it |
| `NEMOCLAW_SANDBOX` | `.env` → `nemoclaw-setup.sh`, ops-bridge, dashboard |
| `whisper` / `kokoro` | `litellm/config.yaml`, `llama-swap.yaml` (`whisper-large-v3-turbo`), the notebook key's model list in `ops-bridge/actions.yaml` |
| `qwen3.6-35b` / `agent` | `llama-swap.yaml`, `litellm/config.yaml`, `create-litellm-keys.sh`, `prometheus.yml` (label), `nemoclaw-setup.sh` (`NEMOCLAW_MODEL=agent`) |
| Ports `10001` (Qwen), `10002` (Whisper) | `llama-swap.yaml`, `prometheus.yml` |
| `/llm` root path | `compose.yaml` (`SERVER_ROOT_PATH`), Caddyfile, `prometheus.yml`, `create-litellm-keys.sh`, NemoClaw provider URL |
| `admins` / `users` groups | `users.yml`, `authelia/configuration.yml`, `compose.yaml` (`ADMIN_GROUP`, `USER_GROUP`) |
| `/connect` | Caddyfile route, Authelia rule, `dashboard/app.py` |
| `bridge_dashboard_token` | `actions.yaml` `clients.dashboard.token_file`, ops-bridge and dashboard secrets |
| `bridge_jupyterhub_token` | `actions.yaml` `clients.jupyterhub.token_file`, ops-bridge and jupyterhub secrets |
| `NOTEBOOK_MEM_LIMIT` | `.env` → ops-bridge (`templates.notebook.memory`) |
| `jupyterhub_cred_secret` | jupyterhub secrets; its derivations are in `jupyterhub/bridge_spawner.py` |
| `minio.env` | `minio` and `minio-mc` (`env_file`) |
| `ssh_ca` | ttyd secret; `ssh_ca.pub` is for the host's sshd (`host/`) |
| `TTYD_UID`, `TTYD_GID` | `.env` → `ttyd` (`user:`) |
| `MINIO_IMAGE`, `MC_IMAGE` | `.env` → `minio`, `minio-mc` |
| Host ports 9091, 4000, 3000, 8000, 8188, 9000, 9001, 9010, 9080, 18789 | `compose.yaml` and Caddyfile (`18789` is the sandbox forward NemoClaw creates) |
| `DOCKER_BRIDGE_IP` | `.env` = `openshell-docker` gateway = `host.openshell.internal` inside the sandbox |
| OIDC clients `portainer`, `grafana`, `litellm`, `jupyterhub`, `minio` | `authelia/configuration.yml` (client ids, redirect URIs, `token_endpoint_auth_method`), `compose.yaml` (Grafana, LiteLLM, MinIO env), `jupyterhub/jupyterhub_config.py`, `scripts/portainer-setup.sh`. Redirects: `/portainer/`, `/grafana/login/generic_oauth`, `/llm/sso/callback`, `/jupyter/hub/oauth_callback`, `/s3/oauth_callback` |
| OIDC token listener `172.17.0.1:9081` | Caddyfile, `compose.yaml` (Grafana, LiteLLM), `jupyterhub_config.py`, `scripts/portainer-setup.sh` |
| MinIO OIDC alias `<PUBLIC_HOST>` → `172.17.0.1:443` | Caddyfile (last site block), `compose.yaml` (`minio` `extra_hosts`, `data/caddy-root.crt`) |
| Dashboard uid `10001` | `dashboard/Dockerfile` (`USER app`), owner of `/run/gb10-elevate/web.sock` set by `host/elevate-setup.sh` |
| Account uid range 20000-29999 | `host/sync-accounts.sh`, `host/gb10-users.nft`, `host/gb10-elevated`, the auditd rule `host/gb10-elevate.audit.rules` |
| `--max-model-len` = OpenClaw context window | `llama-swap.yaml`, `scripts/nemoclaw-setup.sh` (`NEMOCLAW_CONTEXT_WINDOW`), and the live `contextWindow` in the sandbox's `openclaw.json` (`openclaw config patch`; the onboard value only applies to a fresh onboard) |
| `litellm` group | `users.yml`, the `litellm` OIDC authorization policy and the `/llm` rule in `authelia/configuration.yml`; at most 5 members (LiteLLM's free SSO limit) |
| MCP listener `172.17.0.1:8443` | Caddyfile, `nemoclaw-setup.sh` (`MCP_URL`, `--trusted-private-host`) |
| Caddy root CA | `caddy_data` volume → `data/caddy-root.crt` → baked into the sandbox at onboard |
| Checkpoint filename | workflow JSON and the file in `${MODELS_DIR}/comfy/checkpoints/` |
