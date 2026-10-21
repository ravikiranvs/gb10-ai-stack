#!/usr/bin/env bash
# Creates LiteLLM virtual keys. Keys are written to secrets/litellm_keys.json (mode 600), not printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/secrets"
MASTER="$(cat "$SECRETS/litellm_master_key")"
API="${LITELLM_API:-http://127.0.0.1:4000/llm}"
OUT="$SECRETS/litellm_keys.json"
umask 077

create() {
  curl -fsS "$API/key/generate" \
    -H "Authorization: Bearer $MASTER" \
    -H "Content-Type: application/json" \
    -d "$1"
}

{
  echo "["
  create '{"key_alias":"openclaw-sandbox","models":["agent","qwen3.6-35b","qwen3-vl-30b"],"rpm_limit":60}'
  echo ","
  create '{"key_alias":"laptop","rpm_limit":30,"max_budget":50,"budget_duration":"30d"}'
  echo ","
  create '{"key_alias":"scripts","models":["agent"],"rpm_limit":10}'
  echo "]"
} > "$OUT"

echo "Wrote $OUT"
