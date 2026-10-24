# GB10 AI stack

A self-hosted AI agent stack for one NVIDIA GB10 (DGX Spark class, arm64, Ubuntu 24.04). Everything is Docker Compose except NemoClaw, a host CLI that creates the OpenShell sandbox the OpenClaw agent runs in.

- **Agent model:** Qwen3.6-35B-A3B (NVFP4) on vLLM, behind llama-swap and LiteLLM (OpenAI API, virtual keys, MCP gateway).
- **Images:** FLUX schnell on ComfyUI, exposed to the agent as an MCP tool.
- **Agent:** OpenClaw in a NemoClaw/OpenShell sandbox.
- **Access:** one public HTTPS port (Tailscale Funnel) → Caddy → Authelia (password + TOTP/passkey), which is also the single sign-on provider for Portainer, Grafana and LiteLLM.
- **Ops:** admin dashboard, Portainer (containers for admins; private containers for users), Grafana/Prometheus/Loki/Tempo, `ops-bridge` for allow-listed container actions.

| Doc | Read it for |
|---|---|
| this file | Bring-up, daily operations, troubleshooting |
| [`gb10-agent-stack.md`](gb10-agent-stack.md) | How it fits together: routing, auth, security, model lifecycle |
| [`VARIABLES.md`](VARIABLES.md) | Every setting, and which values must match across files |
| [`TO-VERIFY.md`](TO-VERIFY.md) / [`TODO.md`](TODO.md) | What was tested, what is open / planned work |

## Requirements

- GB10 host, NVIDIA driver working, Docker 29 with GPU support (`docker run --rm --gpus all ubuntu:24.04 nvidia-smi`), your user in the `docker` group.
- Tailscale logged in, HTTPS certificates and Funnel enabled for the tailnet.
- Internet access to Docker Hub, `nvcr.io`, GHCR, Hugging Face, GitHub, npm. About 100 GB of disk for models.
- `sudo mkdir -p /srv/models/{hf,comfy/checkpoints} && sudo chown -R "$USER" /srv/models`

## Bring-up

Run from the repository root. A full first run takes about an hour, mostly downloads and builds.

**1. Secrets and config**
```bash
bash scripts/init-secrets.sh                 # secrets/, data/, .env, authelia/users.yml (asks for an optional HF token)
$EDITOR .env                                 # set PUBLIC_HOST (your *.ts.net name); leave DOCKER_BRIDGE_IP for now
docker run --rm -it authelia/authelia:4.39.28 authelia crypto hash generate argon2   # paste the hash into authelia/users.yml
$EDITOR authelia/users.yml                   # your login, e-mail, group `admins`, the hash
```

**2. Model weights** (neither model is gated)
```bash
docker compose build model-runner
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e HF_HOME=/models/hf -v /srv/models/hf:/models/hf \
  --entrypoint hf ai-stack-model-runner download nvidia/Qwen3.6-35B-A3B-NVFP4
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e HF_HOME=/tmp/hf -v /srv/models/comfy:/models/comfy \
  --entrypoint hf ai-stack-model-runner download Comfy-Org/flux1-schnell flux1-schnell-fp8.safetensors --local-dir /models/comfy/checkpoints
rm -rf /srv/models/comfy/checkpoints/.cache
```

**3. Start the stack**
```bash
docker compose up -d --build authelia litellm-db litellm model-runner comfyui comfy-mcp
bash scripts/create-litellm-keys.sh          # → secrets/litellm_keys.json: openclaw-sandbox, laptop, scripts
docker compose up -d --build alloy prometheus loki tempo grafana node-exporter cadvisor gpu-exporter docker-socket-proxy ops-bridge caddy admin-dashboard portainer jupyterhub kokoro minio minio-mc
docker compose --profile images build notebook-image   # the per-user JupyterLab image (about 38 GB, mostly NVIDIA's PyTorch base); the Hub starts people's containers from it
```
`model-runner` loads the agent model at start: about 6 minutes the first time, 3 to 4 after. Ready when `docker compose exec -T model-runner curl -s localhost:8000/running` shows `"state":"ready"`. **Do not generate images while it loads** (vLLM sizes its cache from free memory; FLUX loading at the same time makes it fail).

**4. Go public and sign in**
```bash
sudo tailscale funnel --bg http://127.0.0.1:9080        # off again: tailscale funnel --https=443 off
```
Open `https://<PUBLIC_HOST>/`, sign in, and enrol a second factor (register two: TOTP and/or passkeys). Without SMTP the one-time link is in `docker compose exec authelia cat /data/notification.txt`. Browsing `127.0.0.1:9080` directly returns 400; use the `*.ts.net` name.

**5. NemoClaw sandbox**
```bash
scripts/nemoclaw-setup.sh install            # NemoClaw CLI; ends with an expected CDI warning
scripts/nemoclaw-setup.sh ca                 # exports Caddy's root CA (the sandbox must trust it)
scripts/nemoclaw-setup.sh onboard            # 3 to 8 minutes
```
The first `onboard` ends with `inference.local returned transient HTTP 503`. Expected: `host.openshell.internal` is the gateway of the `openshell-docker` network that NemoClaw just created, not `docker0`. Point LiteLLM and Alloy at it, then resume (the model must be loaded):
```bash
GW=$(docker network inspect openshell-docker --format '{{(index .IPAM.Config 0).Gateway}}')
sed -i "s/^DOCKER_BRIDGE_IP=.*/DOCKER_BRIDGE_IP=$GW/" .env
docker compose up -d litellm alloy
nemoclaw onboard --resume                    # ends "OpenClaw is ready"
```
Then:
```bash
scripts/nemoclaw-setup.sh mcp                # registers the image tool; ends "credential resolution verified … HTTP 200"
scripts/nemoclaw-setup.sh config             # OpenClaw public origin and base path
scripts/nemoclaw-setup.sh notes              # tells the agent to use the image tool
```

**6. Portainer**
```bash
scripts/portainer-setup.sh config            # environment, restrictions for regular users, `users` team, OAuth settings
```
Open `https://<PUBLIC_HOST>/portainer/`, sign in as `admin` (password in `secrets/portainer_admin_password`) and enter your license under *Settings → Licenses*. Portainer refuses every non-admin login until a license is present. Then `scripts/portainer-setup.sh sso` switches login to Authelia. After that, `admins` are Portainer administrators and `users` are Standard Users.

**7. Use OpenClaw**

Open `https://<PUBLIC_HOST>/connect`. It signs you into OpenClaw. The first connection from a browser shows "Device pairing required": approve it in the dashboard (`/home/`, *OpenClaw devices* card). Ask the agent for an image; the first one takes a minute or two while FLUX loads.

## Daily operations

| Task | How |
|---|---|
| Add a person | `scripts/add-user.sh <login> <email> [users\|admins]`. They press **Reset password** on the sign-in page, then open `/connect`; you approve their browser. `users` get the landing page (`/home/`, read-only status), OpenClaw, Grafana (Viewer) and Portainer (own containers only); `admins` also get the dashboard controls, device approval, ComfyUI, Grafana Admin and Portainer admin. LiteLLM UI is for `admins` and the `litellm` group: add `,litellm` (`users,litellm`) to give someone a seat. LiteLLM's SSO is free for 5 people and Authelia only lets the `litellm` group sign in, so keep that group to 5. SSO users start as LiteLLM viewers; promote admins in its UI |
| Let a group of people in quickly | Dashboard → *OpenClaw devices* → **Open for 10 min**: new browsers approve themselves and are labelled by who opened `/connect` |
| Remove a person | Delete their block in `authelia/users.yml` (via `docker compose exec authelia`, see [VARIABLES](VARIABLES.md#users-authelia)) and **Revoke** their devices in the dashboard |
| Portainer | `admins` see and manage everything. `users` can create, run and delete their own containers (private to them by default; they can choose to share with the `users` team) but cannot see or change anyone else's or the stack's, and cannot use bind mounts, privileged mode, host namespaces, device mappings, extra capabilities or stacks. They can also build their own images (*Images → Build a new image*: Dockerfile editor, upload or URL; *Import* for a saved image) and start containers from them, so custom software deploys through Portainer without a registry. Images are shared, not private, and users cannot delete or push them: admins remove or prune old ones (*Images*). Because `users` cannot use stacks, a multi-container app is deployed as separate containers. GPU containers (`--gpus`) are allowed; published ports and resource use are not limited. **Known gap, accepted:** Portainer cannot stop a user's container from using host networking or joining `ai-stack_ai`, nor an image build from using the host network (`networkmode=host` through the API; the UI does not offer it); from there it can reach services that trust Authelia's `Remote-*` headers (the dashboard, Grafana), so a `users` account that is willing to can act as an admin. Treat `users` as trusted. Break-glass: `scripts/portainer-setup.sh local`, then sign in as `admin` |
| SSO sign-in | Portainer, Grafana and LiteLLM sign in through Authelia OIDC (clients in `authelia/configuration.yml`). Break-glass: Portainer `scripts/portainer-setup.sh local`; Grafana `/grafana/login?disableAutoLogin=true` (user `admin`, `secrets/grafana_admin_password`); LiteLLM `/llm/fallback/login` (master key) |
| Lost second factor | `docker compose exec authelia authelia storage user totp delete <login> --config /config/configuration.yml` (and `webauthn delete <login> --all`); they sign in and enrol again |
| API access | `secrets/litellm_keys.json` → `Authorization: Bearer <key>` to `https://<PUBLIC_HOST>/llm/v1/…` |
| Notebooks | `admins` and `users`: `/jupyter/` (dashboard tile; **Start or stop my server** at `/jupyter/hub/home`, admins also `/jupyter/hub/admin`). JupyterHub signs people in through Authelia (client `jupyterhub`) and starts one JupyterLab container each on NVIDIA's PyTorch image with CUDA torch. Each person has their own volume `jupyter-<username>` (`/work`; anything outside it is lost when the server stops), a memory cap (`NOTEBOOK_MEM_LIMIT`, default 16g, no swap) shown in the status bar, and the GPU. Servers nobody uses for an hour are stopped. **In the notebook, ready to use:** `OPENAI_API_KEY` is the person's own LiteLLM key (10 requests a minute; models `agent`, `whisper`, `kokoro`) with `OPENAI_BASE_URL` / `OPENAI_API_BASE` set, so `openai` and LangChain work directly; `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_ENDPOINT_URL` give boto3, s3fs, pandas and papermill access to `s3://u-<username>/` (50 GiB) and `s3://shared/`. **Extensions:** Git panel, jupyter-ai chat (default model `agent` through LiteLLM with Qwen's thinking off, about 0.5 s a reply instead of 10 s; the picker also has a "thinking" variant; in your own code the same switch is `extra_body={"chat_template_kwargs": {"enable_thinking": False}}` on the `openai` call, or `model_kwargs={"extra_body": ...}` on LangChain's `ChatLiteLLM`; the LiteLLM *library* in the image is held at 1.105.3 because 1.106 breaks tool calls, see `jupyter/Dockerfile`), storage browser (jupyter-fsspec), Voilà (the **Render with Voilà** button in the notebook toolbar opens a live preview panel beside the notebook, refreshed on save; that panel is an iframe, which JupyterHub's single-user server forbids by default, so `jupyter/jupyter_server_config.py` sets `frame-ancestors 'self'`; the app is also at `/jupyter/user/<name>/voila/render/<notebook>.ipynb`; only that person can open it; two examples, `voila-basic.ipynb` and `voila-showcase.ipynb`, are copied into `/work/examples` at the first start and never overwritten, delete the folder to get them back), papermill (`papermill in.ipynb out.ipynb -p name value`; it can write `s3://` paths; there is no scheduler, and a run stops with the server). The Hub has no Docker access: it asks ops-bridge to run the `notebook` template (`ops-bridge/actions.yaml`), which fixes the image, network, limits and volume, plus `litellm.key` and `s3.provision`, which create the person's keys (derived from `secrets/jupyterhub_cred_secret`, so they are stable and nothing is stored). Notebook containers sit on their own `notebooks` network with LiteLLM and MinIO only; they can reach the internet (and your LAN). **Limits:** the GPU and the GB10's memory cannot be partitioned, so a large notebook competes with Qwen; a person's volume and bucket are not deleted when their account is removed. After changing `jupyter/` or `JUPYTERHUB_VERSION`, rebuild with `docker compose --profile images build notebook-image` and `docker compose up -d --build jupyterhub` (running servers keep the old image until stopped). Back up `jupyterhub_data` and the `jupyter-*` volumes |
| Terminal (host shell) | `/term/` (admins and users, Authelia with two-factor) opens a terminal in the browser on **the machine itself**, as the person's own Linux account with no sudo or docker access. **The stack side is installed; the host side is installed by `sudo bash host/setup.sh` (not run yet), see `host/README.md`.** ttyd listens on a Unix socket (`data/ttyd/run`) and trusts the `Remote-User` header, which only Caddy can set (it removes any copy the client sent); with no header it refuses the connection. For each browser connection `ttyd/gb10-shell` signs a one-minute SSH certificate for that person with `secrets/ssh_ca` and logs in to a dedicated `sshd` on `172.17.0.1:2222` (certificates only, `AllowGroups gb10-users`, no forwarding), as a plain login shell. **The session ends when you type `exit` (or press Ctrl+D) or close the browser tab:** bash hangs up its background jobs both ways (`huponexit`); only jobs started with `nohup` or `setsid`, or inside a `tmux` you start yourself, keep running. After `exit` the page waits for Enter before opening a new shell (it does not restart by itself). **Shift+Enter inserts a new line in Claude Code** (a browser terminal cannot tell it from Enter, so `ttyd/shift-enter.js`, added to ttyd's page, sends a backslash plus Enter, Claude Code's "new line" shortcut; in bash that is a line continuation). Accounts are created from Authelia's `users.yml` every 5 minutes (names that already exist on the machine are skipped, removed people keep their files), with limits of 16G memory / 1024 tasks / 400% CPU each, and the GPU open. **Without the per-user network block (`host/gb10-users.nft`, installed by the script) a shell on this machine can forge `Remote-User` and reach the dashboard, ComfyUI and Portainer.** Disable an account by removing it from `gb10-users`, not with `passwd -l` (a locked account can still log in with a certificate). ttyd's limit of 20 connections is shared by everyone |
| Storage | Everyone signed in: `/s3/` (dashboard tile "Storage"), the MinIO console with Authelia SSO. The group names the policy: `users` see only their own bucket `u-<username>` and `shared` (everyone reads `shared`; each person writes only under `shared/<username>/`, so ownership stays clear); `admins` see and manage everything, which is also how you see who owns what. Each bucket has a 50 GiB hard quota (`actions.yaml`, `s3.provision`). The S3 API is reachable only from the `notebooks` network. This is the **pgsty community fork** of MinIO: upstream's open-source edition is archived and its images are gone, so the tags are pinned (`MINIO_IMAGE`, `MC_IMAGE`) and security fixes depend on that fork. Break-glass: with SSO on the console offers only the Authelia button, so use the root account `S3ROOT` (password in `secrets/minio.env`) through `docker compose exec minio-mc mc ...`. Back up `minio_data` |
| Speech | Same endpoint and keys: `POST /llm/v1/audio/transcriptions` (model `whisper`, alias `whisper-1`) and `POST /llm/v1/audio/speech` (model `kokoro`, alias `tts-1`, voices such as `af_heart`). Whisper runs in `model-runner`: it loads on the first request (about 75 s) and unloads after 5 idle minutes, so the dashboard shows it as idle most of the time. Kokoro is its own CPU container, always on. Keys restricted to named `models` need `whisper` / `kokoro` added |
| Read an Authelia link without SMTP | `docker compose exec authelia cat /data/notification.txt` |
| Everything off the internet | `tailscale funnel --https=443 off` |

**E-mail (optional).** Authelia sends reset links and one-time codes by SMTP. Without it they go to a file. To enable (Brevo shown; any SMTP service works): create an SMTP key, put it in `secrets/authelia_smtp_password` (`read -rs k && printf '%s' "$k" > secrets/authelia_smtp_password`, no trailing newline), set `SMTP_ADDRESS` (`smtp://smtp-relay.brevo.com:587`), `SMTP_USERNAME` and `SMTP_SENDER` (a verified sender) in `.env`, then `docker compose up -d authelia`. If the service has IP allow-listing and your IP changes, switch it off. A sender and recipient on the same freemail domain (for example both `@protonmail.com`) can be silently dropped: use a different recipient domain or your own domain.

## Things that will surprise you

- **OpenClaw needs its own gateway token** on top of Authelia (NemoClaw rewrites it at every start, so single sign-on is impossible). `/connect` hands it to signed-in users; the token is shared, control is by Authelia group and the device list. The Control UI strips `#token=` from the address bar after reading it: normal.
- **Re-onboarding the sandbox** (needed to change image input, reasoning, context window or the CA) resets OpenClaw config, MCP registration, the gateway token and the device list. Re-run `mcp`, `config`, `notes`; everyone reconnects via `/connect`.
- **Never set OpenClaw `gateway.auth` to `trusted-proxy`.** The sandbox container then exits at start.
- **Whisper needs two vLLM flags on the GB10.** FlashAttention 2 has no `sm_121` kernels, so `llama-swap.yaml` pins `--attention-backend TRITON_ATTN --mm-encoder-attn-backend TORCH_SDPA`; without them it dies at start with `No device code available for GPU ISA 121`. Its `groups` entry (Qwen `persistent`, Whisper in its own group) is what stops a transcription from evicting Qwen.
- **Reloading the model** (editing `model-runner/llama-swap.yaml`, restarting `model-runner`) takes 3 to 4 minutes; chat and image calls wait or fail meanwhile.
- **`DOCKER_BRIDGE_IP` must equal the `openshell-docker` gateway.** `nemoclaw-setup.sh` warns when it does not.
- **GitHub drops HTTP/2 clones from this host**: `nemoclaw-setup.sh install` forces HTTP/1.1 and retries.
- Secrets, `.env`, `authelia/users.yml` and `data/` are git-ignored. Nothing prints secret values.

- **Portainer's user isolation is not a security boundary.** It keeps users' containers private from each other and blocks bind mounts, privileged mode and the like, but a user can still start a container on the host network or on `ai-stack_ai` and forge the `Remote-*` headers that the dashboard and Grafana trust. Only give `users` to people you would trust with admin access. Fix, if that changes: a filtering proxy in front of Portainer's Docker socket, and a shared secret from Caddy for header-trusting services.

## Troubleshooting

| Symptom | Check |
|---|---|
| Login loops or lands on `http://` | `PUBLIC_HOST` in `.env` must be the exact `*.ts.net` name; `docker compose logs authelia caddy` |
| `/connect` or dashboard says the bridge/sandbox is down | `docker compose ps ops-bridge`; `docker ps` shows `openshell-default--<sandbox>-…`; `nemoclaw <sandbox> status` |
| Agent never answers | Model still loading (`/running`), or `DOCKER_BRIDGE_IP` is wrong |
| Agent draws SVG instead of calling the image tool | `scripts/nemoclaw-setup.sh notes` |
| `mcp` says "non-prefix partial state" | `nemoclaw <sandbox> mcp remove comfy_image`, delete the leftover provider (`openshell provider list` / `delete`), rerun |
| No reset e-mail | `docker compose logs authelia`, then the SMTP service's log; see the same-domain note above |
| Grafana / LiteLLM / Portainer sign-in fails with `invalid_client` | `docker compose logs authelia` names the mismatch: the client secret (`secrets/*_oidc_secret` must be readable by the app) or `token_endpoint_auth_method`. After editing `authelia/configuration.yml`, `docker compose restart authelia` |
| Portainer: "No valid Portainer License found" | Non-admins cannot sign in until the license is entered (see step 6) |
| LiteLLM UI refuses a signed-in `users` account | Only `admins` and the `litellm` group (5 seats) may use it: `add-user.sh <login> <email> users,litellm` for new accounts |
| Edited `llama-swap.yaml` (or `Caddyfile`) but nothing changed | Single-file bind mounts keep the old file when an editor or `sed -i` replaces it: `docker compose up -d --force-recreate model-runner`, or `docker compose restart caddy` (Caddy's admin API is off) |
| `vLLM: No available memory for the cache blocks` | ComfyUI loaded FLUX during start-up: free it (dashboard → *Free*) and restart `model-runner` |

## Layout

```text
compose.yaml  .env.example  scripts/  secrets/ data/ (git-ignored)
caddy/  authelia/  litellm/  model-runner/  comfyui/  comfy-mcp/  jupyter/  jupyterhub/  minio/  ttyd/  host/  dashboard/  ops-bridge/  openclaw/  observability/
```
