# GB10 AI stack

A self-hosted AI agent stack on one NVIDIA GB10 (DGX Spark class, arm64): a local agent model behind a LiteLLM gateway, image generation through ComfyUI, an OpenClaw agent in an OpenShell sandbox (NemoClaw), authentication with Authelia, a single public HTTPS port through Tailscale Funnel, and Grafana/Prometheus/Loki/Tempo for observability. Everything that runs as a service is a Docker Compose container, except NemoClaw (a host CLI) and the OpenShell gateway and sandbox it creates.

## Where to look

| File | What it is |
|---|---|
| [`gb10-agent-stack.md`](gb10-agent-stack.md) | The design: architecture, routing, authentication, request flows, security, and the **bring-up runbook (§17)** |
| [`VARIABLES.md`](VARIABLES.md) | Every value you set or must check, file by file, and the values that must match across files |
| [`TO-VERIFY.md`](TO-VERIFY.md) | What was tested on the real host (and how), what was assumed, what is still open |
| [`TODO.md`](TODO.md) | Planned work that is not part of the current setup |
| `compose.yaml`, `.env.example`, `caddy/`, `authelia/`, `litellm/`, `model-runner/`, `comfyui/`, `comfy-mcp/`, `dashboard/`, `observability/`, `openclaw/`, `scripts/` | The configuration itself |

## Bring-up in one screen

Details and explanations are in §17 of the design document. Run from the repository root.

```bash
bash scripts/init-secrets.sh                       # secrets/, .env, authelia/users.yml
$EDITOR .env authelia/users.yml                    # PUBLIC_HOST, your user and password hash
# download the two models (commands in §17 step 3), then:
docker compose up -d --build authelia litellm-db litellm model-runner comfyui comfy-mcp
bash scripts/create-litellm-keys.sh
docker compose up -d --build alloy prometheus loki tempo grafana node-exporter cadvisor gpu-exporter docker-socket-proxy caddy admin-dashboard
sudo tailscale funnel --bg http://127.0.0.1:9080   # public HTTPS; off again: tailscale funnel --https=443 off
scripts/nemoclaw-setup.sh install && scripts/nemoclaw-setup.sh ca
scripts/nemoclaw-setup.sh onboard                  # first run: fix DOCKER_BRIDGE_IP and `nemoclaw onboard --resume` (§17 step 8)
scripts/nemoclaw-setup.sh mcp && scripts/nemoclaw-setup.sh config && scripts/nemoclaw-setup.sh notes
```

Then sign in at `https://<PUBLIC_HOST>/` (Authelia, two factors) and open `/openclaw/` with the gateway token (§17 step 10).

## Things that will surprise you

- **No e-mail anywhere.** Authelia writes one-time codes to a file in its container: `docker compose exec authelia cat /data/notification.txt`.
- **`127.0.0.1:9080` cannot be browsed directly** (400 from Authelia); use your `*.ts.net` address.
- **OpenClaw needs its own gateway token** on top of Authelia; single sign-on into OpenClaw does not work with NemoClaw 0.0.137 (§5).
- **`DOCKER_BRIDGE_IP` is the gateway of NemoClaw's `openshell-docker` network**, known only after the first onboarding (§8 of the runbook).
- **Do not generate images while the agent model is loading** (a reload takes 3 to 4 minutes): vLLM sizes its cache from free memory at start-up (§11).
- **Secrets are never printed or committed**: `secrets/`, `.env`, `authelia/users.yml`, `data/` are git-ignored.

## Layout

```text
compose.yaml  .env.example  scripts/  secrets/ (git-ignored)  data/ (git-ignored)
caddy/ authelia/ litellm/ model-runner/ comfyui/ comfy-mcp/ dashboard/ openclaw/ observability/
```
