# TODO

Planned work that is not part of the current setup. For things that still need checking, see `TO-VERIFY.md`.

## OpenClaw / NemoClaw

- [ ] **Telemetry from the sandbox.** Add a network policy preset allowing the OpenClaw binaries to reach `host.openshell.internal:4318` (see NemoClaw's *Create Custom Policy Presets*: `nemoclaw <sandbox> policy add --from-file …`, no `allowed_ips`), then enable the `diagnostics-otel` plugin (`openclaw plugins install @openclaw/diagnostics-otel`, `diagnostics.otel.endpoint`). Needs a decision on how the private `DOCKER_BRIDGE_IP` is allowed.
- [ ] **Single sign-on into OpenClaw.** Revisit when NemoClaw stops rewriting `gateway.auth.token` at start (then `trusted-proxy` + `deviceAutoApprove` would remove the token and pairing steps).
- [ ] **MCP session close.** The OpenShell MCP policy rejects the `DELETE` that ends an MCP session (`invalid JSON`). Harmless; check a newer NemoClaw.
- [ ] **Put the image note into the repo** as a template that `nemoclaw-setup.sh notes` renders, instead of an inline string.

## Access and onboarding

- [ ] **Remove-user script.** `scripts/add-user.sh` has no counterpart: removing someone means editing `users.yml` through the container and pressing Revoke on their devices by hand. A `scripts/remove-user.sh` could do both.
- [ ] **Dashboard user management** (add/remove users, reset second factors) on top of ops-bridge, so no shell is needed.
- [ ] **Per-user OpenClaw access.** The gateway token is shared; real per-user tokens or SSO need the NemoClaw change above.

## Stack

- [ ] **Reboot test and start order.** Make `litellm`/`alloy` start reliably when `${DOCKER_BRIDGE_IP}` belongs to a network NemoClaw creates (or find a stable address).
- [ ] **Dashboard: real ComfyUI state.** The "hot/unloaded" label is the dashboard's own flag; read ComfyUI's GPU use instead (`/system_stats`).
- [ ] **Pin the floating base images** (`ubuntu:24.04`, `python:3.12-slim`).
- [ ] **Image output cleanup.** `data/comfy-output` grows without bound and holds root-owned files.
- [ ] **Alerts.** None are provisioned (suggestions in the design doc §9).

## Observability

- [ ] **Host network metrics.** node-exporter runs in a container and reports the container's own network interfaces, not the host's, so the dashboard has no host-level traffic numbers. Options to try:
  - run node-exporter with `network_mode: host` (check that it still reaches the `obs` network for Prometheus, for example by publishing `127.0.0.1:9100` and scraping it through the host gateway), or
  - add `--collector.netdev.device-include` filters and mount `/proc/1/net` from the host.

  Then add host traffic panels (per-interface rx/tx, errors) to `observability/grafana/dashboards/gb10-overview.json`. Keep `--no-collector.cpufreq`, which hangs on the GB10.
- [ ] **Fuller dashboards**: vLLM, LiteLLM and OpenClaw boards (only the overview ships).
