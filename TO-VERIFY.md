# Verified and still open

What was tested on the real GB10 (last updated 2026-10-23), the findings that shaped the design, and what nobody has checked yet.

## Verified on the running stack

- **Services:** all 18 compose services start healthy on the pinned tags; all Prometheus targets are up (`vllm-agent` only while the model is loaded).
- **Login:** Funnel → Caddy → Authelia → dashboard, OpenClaw, ComfyUI, with TOTP/passkey; `ts.net` cookie works. Forged `Remote-*` headers have no effect from outside (from a container on `ai-stack_ai` they do: accepted, see below); WebSocket through `/openclaw` works.
- **SSO (OIDC):** real browser sign-ins to Portainer, Grafana and LiteLLM through Authelia work; the admin account is Grafana Admin, Portainer Administrator and LiteLLM admin. Authelia accepts all three client secrets at the token endpoint.
- **Portainer as two standard users** (throwaway accounts, container API): a user sees and controls only their own containers; another user gets 403 on stop, delete and inspect; bind mounts (including `/` and the Docker socket), privileged mode, `pid=host`, `cap_add`, device mappings and stack creation are refused; `--gpus all` creates and starts; the stack's networks and volumes are hidden.
- **Public API:** `/llm/v1/chat/completions` through Funnel with a virtual key, including an 86 s streamed completion with nothing cut off.
- **Model:** cold start 332 s (empty caches), about 200 s afterwards; `ttl: 0` plus preload keeps it loaded; 262144 context (was 131072): KV cache 595,221 tokens, 2.27 full-length requests at once; the live OpenClaw `contextWindow` is 262144.
- **Observability:** OTLP → Alloy → Tempo/Loki/Prometheus; Grafana datasources healthy; every dashboard query returns data.
- **NemoClaw 0.0.137 / OpenClaw 2026.9.2:** install (HTTP/1.1 workaround), onboard with the custom endpoint, CA baked in, MCP over `https://172.17.0.1:8443` (401 without key, 200 sandbox key, 403 key without MCP grant, 404 elsewhere), config patch, browser login with token + pairing, chat through LiteLLM, image generation end to end (agent calls the tool, markdown picture shows).
- **ops-bridge + dashboard Devices card:** 401/403/409/422/504 paths, audit log hides sensitive output; list, approve, reject, revoke (+remove), enrollment window, and `/connect` exercised in real browsers.
- **E-mail:** Brevo SMTP delivers the Authelia reset mail to a Gmail inbox; against a mock server the AUTH login carried the exact secret (quotes and colons survive), and without `SMTP_ADDRESS` the file notifier still works.
- **`scripts/add-user.sh`:** creates the account, Authelia reloads without a restart, duplicate user/e-mail and bad names are rejected.
- **Docker socket:** Alloy and the dashboard read Docker only through `docker-socket-proxy`; only ops-bridge has the rw socket.

## Findings that shaped the design

- Brevo reported "Delivered" for a reset mail whose sender and recipient were the same `@protonmail.com` address, but Proton silently dropped it. The same mail to Gmail arrived. Use a recipient on another domain, or a sender domain you own (SPF/DKIM).
- NemoClaw's external-gateway mode is systemd-only on `127.0.0.1`, so the OpenShell gateway is not a compose service.
- `host.openshell.internal` resolves to the `openshell-docker` network gateway, not `docker0` → `DOCKER_BRIDGE_IP`.
- Containers cannot reach the Funnel hostname, and managed MCP rejects `host.openshell.internal` → HTTPS listener on `172.17.0.1:8443` with Caddy's CA (`NEMOCLAW_CORPORATE_CA_BUNDLE`, honoured only by a fresh onboard).
- `trusted-proxy` auth into OpenClaw is impossible: NemoClaw re-adds the token at each start; the attempt made the sandbox container exit and OpenShell mark it `Error`.
- OpenClaw passes tool-result images to the model as base64 text (context overflow), so `comfy-mcp` returns a link. Its progressive tool disclosure hides MCP tools, hence the `AGENTS.md` note.
- `openclaw devices revoke` only invalidates the token; `remove` deletes the list entry (the dashboard does both). The label field is `operatorLabel`.
- vLLM's KV-cache sizing fails if ComfyUI loads FLUX during its start-up (`No available memory for the cache blocks`).
- Portainer refuses every non-admin login until a license is present, and only applies its restrictions to its own API: it does not stop a user's container from using `NetworkMode: host` or joining `ai-stack_ai`, where the dashboard trusts forged `Remote-Groups` headers. Accepted (README, "Things that will surprise you").
- Authelia needs `X-Forwarded-Proto/Host` to build its issuer and the apps cannot send them, so server-side OIDC calls use the `172.17.0.1:9081` Caddy listener. Each app's token-endpoint auth method must match its Authelia client (`client_secret_post` for Portainer, `client_secret_basic` for Grafana and LiteLLM).
- Docker bind-mounts a single file by inode: `sed -i` on `llama-swap.yaml` left the container on the old config, so llama-swap's `--watch-config` never fired.
- GitHub drops HTTP/2 clones from this host. node-exporter's `cpufreq` collector hangs on the GB10 (disabled). vLLM FlashAttention fails on `sm_121` only for a tiny test model.

## Still open

- [ ] **`scripts/nemoclaw-setup.sh` on a clean machine.** Only `ca`, `config --dry-run`, `notes` ran through the script; `install`, `onboard`, `mcp` repeat commands that ran by hand.
- [ ] **A second person's full onboarding:** `add-user.sh` → reset link → set password → enrol a second factor → `/connect` → approval → chat. The reset mail is verified; completing the link is not. Also whether an Authelia restart interferes mid-onboarding.
- [ ] **A `users`-group account** in a real browser: lands on the dashboard (no admin cards or buttons), opens OpenClaw via `/connect`, opens Grafana (as Viewer) and Portainer (Standard User, own containers only), gets 403 on `/comfy` and on the LiteLLM UI unless it is also in `litellm`. (Checked with `Remote-Groups: users` headers against the dashboard: admin-only sections absent, mutating routes 403.) self-service password change with the read-write `users.yml` mount.
- [ ] **Portainer as a real `users` account:** SSO lands as Standard User in team `users`, and the team mapping and admin mapping behave as in the API tests.
- [ ] **LiteLLM's sixth SSO user:** what LiteLLM does past the free limit (Authelia's `litellm` group should keep it from happening).
- [ ] **Model preload error:** after a container start the log shows `failed to preload model qwen3.6-35b: status 404` although the model then loads and answers.
- [ ] **Reboot:** NemoClaw gateway service and sandbox come back, `${DOCKER_BRIDGE_IP}` exists before LiteLLM/Alloy start (they retry via `restart: unless-stopped`), the model preloads.
- [ ] **Device labels:** confirm a label shows in the paired list after a live approval (field confirmed on real JSON).
- [ ] **OpenClaw telemetry:** sandbox egress to `host.openshell.internal:4318` and the `diagnostics-otel` plugin (see `TODO.md`).
- [ ] **Image understanding quality** of the agent model on screenshots, charts and small text.
- [ ] Smaller: why weight loading takes ~130 s; the dashboard's ComfyUI "hot" flag is its own and does not read the GPU; the MCP policy rejects the session-closing `DELETE` (noise only); growth of `data/comfy-output`.
