#!/usr/bin/env bash
# Add an Authelia user. The account is created with a random password nobody knows; the person sets their own with
# "Reset password" on the sign-in page (the link is e-mailed, or written to a file when SMTP is not configured).
#
#   scripts/add-user.sh <username> <email> [group] [display name]
#     group: users (default; can open OpenClaw via /connect, Grafana as Viewer, Portainer for their own containers) or admins (everything).
#            Add ,litellm for a LiteLLM UI seat (SSO is free for 5 people), e.g. users,litellm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

user="${1:-}"; email="${2:-}"; group="${3:-users}"; display="${4:-$user}"
[[ -n "$user" && -n "$email" ]] || { sed -n '2,8p' "$0"; exit 1; }
[[ "$user" =~ ^[a-z][a-z0-9._-]{1,31}$ ]] || { echo "username: lower-case letters, digits . _ - (2-32 chars, starts with a letter)" >&2; exit 1; }
[[ "$email" =~ ^[^[:space:]@\'\"]+@[^[:space:]@\'\"]+\.[^[:space:]@\'\"]+$ ]] || { echo "that does not look like an e-mail address" >&2; exit 1; }
[[ "$group" =~ ^(users|admins)(,litellm)?$ ]] || { echo "group must be users, admins, users,litellm or admins,litellm" >&2; exit 1; }
[[ "$display" != *[\'\"$'\n']* ]] || { echo "display name: no quotes or line breaks" >&2; exit 1; }

# users.yml is owned by root (Authelia rewrites it), so read and write it through the container.
az() { docker compose exec -T authelia "$@"; }
az true 2>/dev/null || { echo "the authelia container is not running (docker compose up -d authelia)" >&2; exit 1; }

if az grep -qE "^  ${user}:" /config/users.yml; then echo "user '$user' already exists" >&2; exit 1; fi
if az grep -qiE "^    email: '?${email}'?$" /config/users.yml; then echo "e-mail $email is already used by another user" >&2; exit 1; fi

# Throw-away password: hashed immediately and never shown, so only the reset link can ever set a usable one.
hash="$(az authelia crypto hash generate argon2 --password "$(openssl rand -base64 33)" | sed -n 's/^Digest: //p' | tr -d '\r')"
[[ "$hash" == '$argon2id$'* ]] || { echo "could not generate the password hash" >&2; exit 1; }

# Append in place (not replace) so the bind mount keeps working. Add a newline first if the file lacks one.
{
  printf '\n  %s:\n    displayname: %s\n    email: %s\n    password: '"'"'%s'"'"'\n    groups:\n      - %s\n' "$user" "'$display'" "$email" "$hash" "${group//,/$'\n'      - }"
} | az sh -c '[ -z "$(tail -c1 /config/users.yml)" ] || echo >> /config/users.yml; cat >> /config/users.yml'

echo "added '$user' <$email> to group '$group'"
echo
if az sh -c 'test -n "$SMTP_ADDRESS"'; then
  echo "Next: tell them to open https://$(grep -E '^PUBLIC_HOST=' .env | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//')/ , choose 'Reset password' and enter '$user'."
  echo "They get an e-mail with a link to set their password, then enrol an authenticator app or passkey at first sign-in."
else
  echo "SMTP is not configured, so the reset link is written to a file. After they press 'Reset password' on the sign-in page, read it with:"
  echo "  docker compose exec authelia cat /data/notification.txt"
  echo "and send them the link. (Set SMTP_ADDRESS in .env to have it e-mailed instead.)"
fi
if [[ "$group" == users* ]]; then echo "They open OpenClaw through https://<host>/connect; you approve their browser in the dashboard's Devices card."; fi
