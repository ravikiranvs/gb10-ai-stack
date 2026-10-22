#!/usr/bin/env bash
# NemoClaw / OpenClaw setup for this stack. Every command here was run by hand on the GB10 first; this script only repeats them.
#
#   scripts/nemoclaw-setup.sh install   install the NemoClaw CLI (host)
#   scripts/nemoclaw-setup.sh ca        export Caddy's root CA to data/caddy-root.crt (the sandbox must trust it)
#   scripts/nemoclaw-setup.sh onboard   create the OpenShell gateway + sandbox, wired to LiteLLM (needs `ca` first)
#   scripts/nemoclaw-setup.sh mcp       register the ComfyUI MCP server with the sandbox
#   scripts/nemoclaw-setup.sh config    apply openclaw/openclaw.patch.json5 inside the sandbox ([--dry-run] to validate only)
#   scripts/nemoclaw-setup.sh notes     add the "use the comfy_image tool for images" note to the agent's workspace AGENTS.md
#
# Needs: the compose stack running, secrets/litellm_keys.json (scripts/create-litellm-keys.sh), .env filled in.
# Keys are read from secrets/ into environment variables for one command; they are never printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

envval() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//'; }
[[ -f .env ]] || { echo "missing .env (run scripts/init-secrets.sh first)" >&2; exit 1; }
SANDBOX="$(envval NEMOCLAW_SANDBOX)"; PUBLIC_HOST="$(envval PUBLIC_HOST)"
[[ -n "$SANDBOX" && -n "$PUBLIC_HOST" ]] || { echo "NEMOCLAW_SANDBOX and PUBLIC_HOST must be set in .env" >&2; exit 1; }

CA_FILE="$ROOT/data/caddy-root.crt"
MCP_URL="https://172.17.0.1:8443/llm/comfy_image/mcp"   # Caddy's HTTPS listener on docker0 (see caddy/Caddyfile)

sandbox_key() {
  [[ -f secrets/litellm_keys.json ]] || { echo "missing secrets/litellm_keys.json (run scripts/create-litellm-keys.sh)" >&2; exit 1; }
  python3 -c "import json;print([k['key'] for k in json.load(open('secrets/litellm_keys.json')) if k['key_alias']=='openclaw-sandbox'][0])"
}

# host.openshell.internal resolves to the gateway of the openshell-docker network (created by NemoClaw), which must equal DOCKER_BRIDGE_IP
check_bridge_ip() {
  local gw want
  gw="$(docker network inspect openshell-docker --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
  want="$(envval DOCKER_BRIDGE_IP)"
  if [[ -n "$gw" && "$gw" != "$want" ]]; then
    echo "WARNING: the sandbox network gateway is $gw but .env has DOCKER_BRIDGE_IP=$want." >&2
    echo "         The sandbox cannot reach LiteLLM/Alloy until you set DOCKER_BRIDGE_IP=$gw and run: docker compose up -d litellm alloy" >&2
    return 1
  fi
}

sandbox_container() { docker ps --format '{{.Names}}' | grep -- "--${SANDBOX}-" | head -1; }

cmd_install() {
  # GitHub drops HTTP/2 clones from this host (curl 92 / early EOF), so force HTTP/1.1; retry because it is still flaky.
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1
  export NEMOCLAW_NO_EXPRESS=1            # skip the DGX Spark "managed vLLM" menu: we run our own model
  export NEMOCLAW_DISABLE_TELEMETRY=1
  for i in 1 2 3; do
    # The installer also tries to onboard and stops on the missing NVIDIA CDI spec; that is fine, `onboard` below runs with --no-gpu.
    curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash -s -- --yes-i-accept-third-party-software || true
    # shellcheck disable=SC1091
    [[ -s "$HOME/.nvm/nvm.sh" ]] && . "$HOME/.nvm/nvm.sh"
    if command -v nemoclaw >/dev/null 2>&1; then echo "nemoclaw installed: $(command -v nemoclaw)"; return 0; fi
    echo "attempt $i did not install the CLI, retrying"; sleep 5
  done
  echo "nemoclaw is still missing; see the installer output above" >&2; exit 1
}

cmd_ca() {
  mkdir -p data
  docker compose exec -T caddy test -f /data/caddy/pki/authorities/local/root.crt \
    || { echo "Caddy has no local CA yet: start it first (docker compose up -d caddy)" >&2; exit 1; }
  docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$CA_FILE" >/dev/null
  chmod 644 "$CA_FILE"
  openssl x509 -in "$CA_FILE" -noout -subject -enddate
}

cmd_onboard() {
  [[ -f "$CA_FILE" ]] || { echo "missing $CA_FILE (run: $0 ca)" >&2; exit 1; }
  curl -s -o /dev/null -m 5 http://127.0.0.1:4000/health/liveliness || { echo "LiteLLM is not answering on 127.0.0.1:4000" >&2; exit 1; }
  export NEMOCLAW_PROVIDER=custom                                          # "Other OpenAI-compatible endpoint"
  export NEMOCLAW_ENDPOINT_URL=http://host.openshell.internal:4000/llm/v1  # name is only valid inside the sandbox; onboarding skips probing it
  export NEMOCLAW_MODEL=agent                                              # LiteLLM alias for qwen3.6-35b
  export NEMOCLAW_AGENT=openclaw
  export NEMOCLAW_POLICY_TIER=balanced
  export NEMOCLAW_WEB_SEARCH_PROVIDER=none
  export NEMOCLAW_SANDBOX_GPU=0
  export NEMOCLAW_INFERENCE_INPUTS=text,image   # build-time: the agent model accepts images
  export NEMOCLAW_REASONING=true                # build-time
  export NEMOCLAW_TRUSTED_PRIVATE_HOSTS=host.openshell.internal
  export NEMOCLAW_DISABLE_TELEMETRY=1
  export NEMOCLAW_CORPORATE_CA_BUNDLE="$CA_FILE"  # build-time: only a fresh onboard applies it; `rebuild` ignores it
  COMPATIBLE_API_KEY="$(sandbox_key)"; export COMPATIBLE_API_KEY
  # --no-gpu: the sandbox needs no GPU and this host has no CDI spec. --fresh --recreate-sandbox: safe on a first run, and the only
  # way to change build-time settings later (the workspace is backed up and restored).
  check_bridge_ip || true   # first run: the network does not exist yet, so this only warns on later runs
  if ! nemoclaw onboard --fresh --recreate-sandbox --non-interactive --name "$SANDBOX" --no-gpu --yes-i-accept-third-party-software; then
    check_bridge_ip || true
    echo "onboarding failed; if the message mentions an inference.local 503, fix DOCKER_BRIDGE_IP as warned above, then: nemoclaw onboard --resume" >&2
    exit 1
  fi
  check_bridge_ip
}

cmd_mcp() {
  check_bridge_ip || true
  LITELLM_MCP_KEY="$(sandbox_key)"; export LITELLM_MCP_KEY
  # HTTPS only; 172.17.0.1 is private, so it must be declared trusted. If a previous attempt left partial state, run
  #   nemoclaw $SANDBOX mcp remove comfy_image   and   openshell provider delete <leftover provider shown by `openshell provider list`>
  nemoclaw "$SANDBOX" mcp add comfy_image --url "$MCP_URL" --env LITELLM_MCP_KEY --trusted-private-host 172.17.0.1
  nemoclaw "$SANDBOX" mcp status comfy_image
}

cmd_config() {
  local dry=() c
  [[ "${1:-}" == "--dry-run" ]] && dry=(--dry-run)
  c="$(sandbox_container)"; [[ -n "$c" ]] || { echo "sandbox container for '$SANDBOX' is not running" >&2; exit 1; }
  # HOME must be the sandbox user's: `docker exec -u sandbox` otherwise inherits /root and the CLI cannot open its state.
  sed "s/__PUBLIC_HOST__/${PUBLIC_HOST}/g" openclaw/openclaw.patch.json5 \
    | docker exec -i -u sandbox -e HOME=/sandbox "$c" openclaw config patch --stdin "${dry[@]}"
}

cmd_notes() {
  local c; c="$(sandbox_container)"; [[ -n "$c" ]] || { echo "sandbox container for '$SANDBOX' is not running" >&2; exit 1; }
  # OpenClaw hides MCP tools behind a tool search; without this note the agent draws images as SVG instead of calling the tool.
  # TOOLS.md is retired in this OpenClaw version: local notes live in the "## Tools" section of AGENTS.md.
  docker exec -i -u sandbox -e HOME=/sandbox "$c" python3 - <<'PY'
p = '/sandbox/.openclaw/workspace/AGENTS.md'
s = open(p).read()
marker = "### Local notes\n\n"
note = ("- Images: to create an image, use the `comfy_image-generate_image` MCP tool (find it with `tool_search` if it is not listed). "
        "Do not draw images yourself as SVG or code. The tool returns a short text result with an `image_url` and a `markdown` value. "
        "Put the `markdown` value in your reply exactly as returned. Never invent or rewrite the image URL, and never try to download, decode or save the image.\n\n")
if "comfy_image-generate_image" in s:
    print("AGENTS.md already has the image note")
elif marker not in s:
    print("AGENTS.md has no '### Local notes' section; add the note by hand (see TO-VERIFY.md)")
else:
    open(p, 'w').write(s.replace(marker, marker + note, 1))
    print("AGENTS.md updated")
PY
}

case "${1:-}" in
  install) cmd_install ;;
  ca)      cmd_ca ;;
  onboard) cmd_onboard ;;
  mcp)     cmd_mcp ;;
  config)  shift; cmd_config "$@" ;;
  notes)   cmd_notes ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
