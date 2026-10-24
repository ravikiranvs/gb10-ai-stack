#!/usr/bin/env bash
# Creates, re-enables and disables the Linux accounts behind the browser terminal, from Authelia's users.yml. Run as root:
#   sudo bash host/sync-accounts.sh [--dry-run]
# setup.sh installs a timer that runs this every 5 minutes, so a person added with scripts/add-user.sh gets an account within minutes.
#
# Who gets an account: every enabled Authelia user in the group `admins` or `users`, if the name is lower case letters, digits, . _ -
# (the same rule as add-user.sh). Accounts get:
#   - a uid in 20000-29999 (the range the network block in host/gb10-users.nft applies to) and the group gb10-users (what the dedicated sshd allows);
#   - no sudo, no docker group, and password `*` (disabled but NOT locked: a locked account would refuse certificate logins);
#   - a home directory (mode 750) and per-user limits through systemd (user-<uid>.slice): memory, tasks, CPU.
# A name that already exists as another kind of account (for example the machine's own `admin`) is skipped with a warning, never changed.
# A person who is removed or disabled in Authelia loses the group and their sessions are ended; their files are kept.
#
# Limits can be changed in /etc/gb10/accounts.env (GB10_MEM_MAX, GB10_TASKS_MAX, GB10_CPU_QUOTA); the defaults are below.
set -euo pipefail

ROOT="${GB10_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
USERS_YML="${GB10_USERS_YML:-$ROOT/authelia/users.yml}"
UNIT_DIR="${GB10_UNIT_DIR:-/etc/systemd/system}"
GROUP="gb10-users"
MARKER="gb10 browser terminal"      # the comment field of every account this script creates: only those are ever re-enabled
UID_MIN=20000
UID_MAX=29999
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
[[ "${2:-}" == "--dry-run" ]] && DRY=1

[[ -r /etc/gb10/accounts.env ]] && . /etc/gb10/accounts.env
MEM_MAX="${GB10_MEM_MAX:-16G}"
TASKS_MAX="${GB10_TASKS_MAX:-1024}"
CPU_QUOTA="${GB10_CPU_QUOTA:-400%}"

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
[[ -r "$USERS_YML" ]] || { echo "cannot read $USERS_YML" >&2; exit 1; }
getent group "$GROUP" >/dev/null || { echo "group $GROUP does not exist: run host/setup.sh first" >&2; exit 1; }

run() { if ((DRY)); then echo "   [dry run] $*"; else "$@"; fi; }
say() { echo "gb10-accounts: $*"; }
have_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null && [[ -z "${GB10_SKIP_SYSTEMD:-}" ]]; }

# Names that should have an account. Reading failures must abort: an empty list would disable everyone.
WANTED_TEXT="$(python3 -I - "$USERS_YML" <<'PY'
import re, sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
users = data.get("users")
if not isinstance(users, dict) or not users:
    sys.exit("users.yml has no `users:` entries")
for name, u in users.items():
    if u.get("disabled"):
        continue
    if not ({"admins", "users"} & set(u.get("groups") or [])):
        continue
    if re.fullmatch(r"[a-z][a-z0-9._-]{1,31}", str(name)):
        print(name)
    else:
        print(f"gb10-accounts: skipped '{name}': not a valid account name", file=sys.stderr)
PY
)"
WANTED=()
while IFS= read -r line; do [[ -n "$line" ]] && WANTED+=("$line"); done <<< "$WANTED_TEXT"
if (( ${#WANTED[@]} == 0 )) && [[ "${1:-}" != "--allow-empty" ]]; then
  echo "gb10-accounts: no enabled admin/user found in $USERS_YML; refusing to disable every account (use --allow-empty if that is really intended)" >&2
  exit 1
fi

changed_units=0
write_limits() {   # $1 uid
  local dir="$UNIT_DIR/user-$1.slice.d" file want
  file="$dir/50-gb10.conf"
  want=$(printf '[Slice]\nMemoryMax=%s\nMemorySwapMax=0\nTasksMax=%s\nCPUQuota=%s\n' "$MEM_MAX" "$TASKS_MAX" "$CPU_QUOTA")
  if [[ ! -f "$file" ]] || [[ "$(cat "$file")" != "$want" ]]; then
    if ((DRY)); then echo "   [dry run] write limits for uid $1"; else mkdir -p "$dir"; printf '%s\n' "$want" > "$file"; changed_units=1; fi
  fi
}

is_ours() {   # $1 name: exists, uid in our range, member of the group
  local u g
  u=$(id -u "$1" 2>/dev/null) || return 1
  (( u >= UID_MIN && u <= UID_MAX )) || return 1
  id -nG "$1" | tr ' ' '\n' | grep -qx "$GROUP"
}

declare -A KEEP=()
for name in "${WANTED[@]}"; do
  KEEP[$name]=1
  if getent passwd "$name" >/dev/null; then
    if is_ours "$name"; then
      write_limits "$(id -u "$name")"
    elif u=$(id -u "$name"); (( u >= UID_MIN && u <= UID_MAX )) && [[ "$(getent passwd "$name" | cut -d: -f5)" == "$MARKER" ]]; then
      # one of ours (it carries our marker) that was disabled earlier (group removed): switch it back on
      say "re-enabling $name"
      run usermod -aG "$GROUP" -s /bin/bash -p '*' "$name"
      write_limits "$u"
    else
      say "skipped '$name': an account with that name already exists on this machine (uid $u) and was not created by this script"
    fi
    continue
  fi
  say "creating $name"
  run useradd --create-home --shell /bin/bash --comment "$MARKER" \
      --key UID_MIN=$UID_MIN --key UID_MAX=$UID_MAX --groups "$GROUP" "$name"
  run usermod -p '*' "$name"        # password disabled but not locked: certificate logins need an unlocked account
  if ((DRY)); then :; else write_limits "$(id -u "$name")"; fi
done

# Accounts in our range that are no longer wanted: remove the group and end their sessions; keep their files
while IFS=: read -r name _ uid _; do
  (( uid >= UID_MIN && uid <= UID_MAX )) || continue
  id -nG "$name" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP" || continue
  [[ -n "${KEEP[$name]:-}" ]] && continue
  say "disabling $name (no longer an enabled admin/user in Authelia); files are kept"
  run gpasswd -d "$name" "$GROUP" >/dev/null
  run usermod -s /usr/sbin/nologin "$name"
  if command -v loginctl >/dev/null && have_systemd; then run loginctl terminate-user "$name" || true; fi
  run pkill -KILL -u "$name" || true
done < <(getent passwd)

if (( changed_units )) && have_systemd; then
  systemctl daemon-reload
  say "limits applied: MemoryMax=$MEM_MAX TasksMax=$TASKS_MAX CPUQuota=$CPU_QUOTA per account"
fi
say "done: ${#WANTED[@]} wanted account(s)"
