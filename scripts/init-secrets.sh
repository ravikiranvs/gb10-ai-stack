#!/usr/bin/env bash
# Generates local secrets and bootstrap files. Never overwrites existing files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/secrets"
umask 077
mkdir -p "$SECRETS" "$ROOT/data/comfy-output"
chmod 700 "$SECRETS"

gen() {
  local name="$1" value="$2"
  if [[ -s "$SECRETS/$name" ]]; then
    echo "keep     secrets/$name"
  else
    printf '%s' "$value" > "$SECRETS/$name"
    echo "created  secrets/$name"
  fi
}

rand() { openssl rand -hex "${1:-32}"; }

gen authelia_jwt         "$(rand 32)"
gen authelia_session     "$(rand 32)"
gen authelia_storage_key "$(rand 32)"
gen litellm_master_key   "sk-$(rand 24)"
gen litellm_db_password  "$(rand 24)"
gen grafana_admin_password "$(rand 24)"
[[ -e "$SECRETS/authelia_smtp_password" ]] || { : > "$SECRETS/authelia_smtp_password"; echo "created  secrets/authelia_smtp_password (empty: fill it only if you enable SMTP)"; }
gen bridge_dashboard_token  "$(rand 32)"     # the dashboard's credential for ops-bridge
gen bridge_jupyterhub_token "$(rand 32)"     # JupyterHub's credential for ops-bridge (notebook.* actions only)
gen portainer_admin_password "$(rand 24)"     # break-glass local admin; day-to-day login is SSO
gen authelia_oidc_hmac     "$(rand 32)"
gen portainer_oidc_secret  "$(rand 32)"     # plaintext client secret, pasted into Portainer's OAuth settings
if [[ ! -s "$SECRETS/authelia_oidc_jwks_key" ]]; then
  openssl genrsa 2048 2>/dev/null > "$SECRETS/authelia_oidc_jwks_key"
  echo "created  secrets/authelia_oidc_jwks_key"
else
  echo "keep     secrets/authelia_oidc_jwks_key"
fi
gen grafana_oidc_secret    "$(rand 32)"
gen litellm_oidc_secret    "$(rand 32)"
gen jupyterhub_oidc_secret "$(rand 32)"
gen minio_oidc_secret      "$(rand 32)"
gen minio_root_password    "$(rand 24)"       # MinIO root account; day-to-day sign-in is Authelia SSO
gen jupyterhub_cred_secret "$(rand 32)"       # only JupyterHub holds this: it derives each person's LiteLLM key and storage key from it
# Authelia stores only a PBKDF2 hash of each OIDC client secret
for client in portainer grafana litellm jupyterhub minio; do
  if [[ ! -s "$SECRETS/${client}_oidc_client_hash" ]]; then
    docker run --rm authelia/authelia:4.39.28 authelia crypto hash generate pbkdf2 --password "$(cat "$SECRETS/${client}_oidc_secret")" --no-confirm \
      | sed -n 's/^Digest: //p' | tr -d '\n' > "$SECRETS/${client}_oidc_client_hash"
    echo "created  secrets/${client}_oidc_client_hash"
  else
    echo "keep     secrets/${client}_oidc_client_hash"
  fi
done

# Prometheus runs as nobody and reads this file to scrape LiteLLM /llm/metrics
chmod 644 "$SECRETS/litellm_master_key"
# Grafana runs as uid 472 and reads this file for its built-in admin account
chmod 644 "$SECRETS/grafana_admin_password"
# the dashboard container runs as a non-root user and reads its ops-bridge secret
chmod 644 "$SECRETS/bridge_dashboard_token"
# Grafana (uid 472) reads its OIDC client secret from this file
chmod 644 "$SECRETS/grafana_oidc_secret"
# ops-bridge and JupyterHub run with every capability dropped, so even their root user cannot read a file it does not own
chmod 644 "$SECRETS/bridge_jupyterhub_token" "$SECRETS/jupyterhub_oidc_secret" "$SECRETS/jupyterhub_cred_secret"

if [[ ! -s "$SECRETS/hf_token" ]]; then
  read -r -s -p "Hugging Face token (leave empty to fill in later): " HF
  echo
  printf '%s' "$HF" > "$SECRETS/hf_token"
  echo "created  secrets/hf_token"
fi

if [[ ! -s "$SECRETS/litellm.env" ]]; then
  {
    echo "LITELLM_MASTER_KEY=$(cat "$SECRETS/litellm_master_key")"
    echo "DATABASE_URL=postgresql://litellm:$(cat "$SECRETS/litellm_db_password")@litellm-db:5432/litellm"
  } > "$SECRETS/litellm.env"
  echo "created  secrets/litellm.env"
fi

if [[ ! -s "$SECRETS/minio.env" ]]; then
  {
    echo "MINIO_ROOT_USER=S3ROOT"                    # upper case on purpose: person-derived keys are lower case, so they can never collide
    echo "MINIO_ROOT_PASSWORD=$(cat "$SECRETS/minio_root_password")"
    echo "MINIO_IDENTITY_OPENID_CLIENT_SECRET=$(cat "$SECRETS/minio_oidc_secret")"
    echo "MC_HOST_local=http://S3ROOT:$(cat "$SECRETS/minio_root_password")@minio:9000"     # for the minio-mc helper container
  } > "$SECRETS/minio.env"
  echo "created  secrets/minio.env"
fi

grep -q '^GENERIC_CLIENT_SECRET=' "$SECRETS/litellm.env" || { echo "GENERIC_CLIENT_SECRET=$(cat "$SECRETS/litellm_oidc_secret")" >> "$SECRETS/litellm.env"; echo "updated  secrets/litellm.env (OIDC client secret)"; }

[[ -f "$ROOT/.env" ]] || { cp "$ROOT/.env.example" "$ROOT/.env"; echo "created  .env (edit it)"; }
[[ -f "$ROOT/authelia/users.yml" ]] || {
  cp "$ROOT/authelia/users.yml.example" "$ROOT/authelia/users.yml"
  echo "created  authelia/users.yml (set a password hash)"
}

echo
echo "Generate an Authelia password hash with:"
echo "  docker run --rm -it authelia/authelia:4.39.28 authelia crypto hash generate argon2"
