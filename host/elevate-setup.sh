#!/usr/bin/env bash
# Temporary, audited sudo for admins' browser-terminal accounts. Run as root, from anywhere; safe to run again:
#   sudo bash host/elevate-setup.sh                 install
#   sudo bash host/elevate-setup.sh --no-auditd     install without auditd (sudo's own recordings and the grant log are still on)
#   sudo bash host/elevate-setup.sh --uninstall     remove the service and every active grant; the logs are kept
# Needs host/setup.sh to have been run first (group gb10-users, the accounts).
#
# What it installs
#   /usr/local/sbin/gb10-elevated   the root daemon (systemd unit gb10-elevated): grants and ends sudo, writes the grant log, prunes after 30 days
#   /usr/local/bin/gb10-elevate     what a person types in the terminal: status / drop (it cannot grant)
#   gb10-elevate-sweep.timer        every minute: ends expired grants even if the daemon is down
#   /etc/gb10/elevate.env           settings (default 15 min, maximum 60, keep 30 days); created once, then yours
#   /var/log/gb10-elevate/          grants-YYYY-MM-DD.jsonl (append-only attribute), /var/log/sudo-io/ sudo's full input/output recordings
#   auditd rule gb10-elevated       every program run as root by a browser-terminal login (skipped with --no-auditd)
# Nothing in /etc/sudoers or /etc/ssh is edited: a grant is one file in /etc/sudoers.d that the daemon creates and removes.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
ROOT="${GB10_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HOSTDIR="$ROOT/host"
UNIT_DIR="${GB10_UNIT_DIR:-/etc/systemd/system}"
TEST="${GB10_TEST:-}"
say() { echo "gb10-elevate: $*"; }
sc()  { if [[ -n "$TEST" ]]; then echo "   [test mode] systemctl $*"; else systemctl "$@"; fi; }

if [[ "${1:-}" == "--uninstall" ]]; then
  sc disable --now gb10-elevate-sweep.timer gb10-elevated.service 2>/dev/null || true
  rm -f /etc/sudoers.d/gb10-grant-* "$UNIT_DIR"/gb10-elevated.service "$UNIT_DIR"/gb10-elevate-sweep.service "$UNIT_DIR"/gb10-elevate-sweep.timer \
        /usr/local/sbin/gb10-elevated /usr/local/bin/gb10-elevate /etc/audit/rules.d/60-gb10-elevate.rules /etc/profile.d/gb10-elevate.sh
  sc daemon-reload
  if command -v augenrules >/dev/null && [[ -z "$TEST" ]]; then augenrules --load >/dev/null 2>&1 || true; fi
  say "removed. Active grants are gone; the logs in /var/log/gb10-elevate and /var/log/sudo-io and /etc/gb10/elevate.env were kept."
  exit 0
fi
AUDITD=1
[[ "${1:-}" == "--no-auditd" ]] && AUDITD=0

for f in "$HOSTDIR/gb10-elevated" "$HOSTDIR/gb10-elevate" "$HOSTDIR/gb10-elevate.audit.rules" "$ROOT/authelia/users.yml"; do
  [[ -s "$f" ]] || { echo "missing $f" >&2; exit 1; }
done
for c in visudo chattr python3; do command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }; done
python3 -c "import yaml" 2>/dev/null || { echo "python3-yaml is required (apt install python3-yaml)" >&2; exit 1; }
getent group gb10-users >/dev/null || { echo "group gb10-users does not exist: run host/setup.sh first" >&2; exit 1; }
grep -Rqs '^[#@]includedir[[:space:]]\+/etc/sudoers.d' /etc/sudoers || { echo "/etc/sudoers does not include /etc/sudoers.d; add the line '@includedir /etc/sudoers.d' with visudo" >&2; exit 1; }

DASH_UID="$(sed -n 's/^RUN useradd -r -u \([0-9]*\) app$/\1/p' "$ROOT/dashboard/Dockerfile")"
DASH_UID="${DASH_UID:-10001}"
if getent passwd "$DASH_UID" >/dev/null; then
  echo "uid $DASH_UID (the dashboard container's user) is also a user on this machine ($(getent passwd "$DASH_UID" | cut -d: -f1)); that account could talk to the daemon's web socket. Resolve this first." >&2
  exit 1
fi
PUBLIC_HOST="$(sed -n 's/^PUBLIC_HOST=\([^ #]*\).*/\1/p' "$ROOT/.env" 2>/dev/null | head -1)"

# ── files ──────────────────────────────────────────────────────────────────────────────────
install -D -m 755 "$HOSTDIR/gb10-elevated" /usr/local/sbin/gb10-elevated
install -D -m 755 "$HOSTDIR/gb10-elevate" /usr/local/bin/gb10-elevate
install -d -m 755 /etc/gb10
if [[ ! -f /etc/gb10/elevate.env ]]; then
  cat > /etc/gb10/elevate.env <<ENV
# Settings of gb10-elevated (restart it after a change: systemctl restart gb10-elevated)
GB10_USERS_YML=$ROOT/authelia/users.yml
GB10_ELEVATE_WEB_UID=$DASH_UID
GB10_ELEVATE_DEFAULT_MIN=15
GB10_ELEVATE_MAX_MIN=60
GB10_ELEVATE_KEEP_DAYS=30
ENV
  say "wrote /etc/gb10/elevate.env"
fi
# what the CLI tells a person to open
if [[ -n "$PUBLIC_HOST" ]]; then printf 'export GB10_ELEVATE_URL=https://%s/home/\n' "$PUBLIC_HOST" > /etc/profile.d/gb10-elevate.sh; fi
install -d -m 750 /var/log/gb10-elevate
install -d -m 700 /var/log/sudo-io

# ── auditd ─────────────────────────────────────────────────────────────────────────────────
if (( AUDITD )); then
  if ! command -v auditctl >/dev/null; then
    if [[ -n "$TEST" ]]; then echo "   [test mode] apt-get install auditd"; else DEBIAN_FRONTEND=noninteractive apt-get install -y auditd >/dev/null; say "installed auditd"; fi
  fi
  install -D -m 640 "$HOSTDIR/gb10-elevate.audit.rules" /etc/audit/rules.d/60-gb10-elevate.rules
  if [[ -z "$TEST" ]]; then
    if augenrules --load >/dev/null 2>&1; then say "auditd rule loaded (search: sudo ausearch -k gb10-elevated -i)"; else say "WARNING: could not load the auditd rule; the rest works without it"; fi
  fi
fi

# ── systemd ────────────────────────────────────────────────────────────────────────────────
cat > "$UNIT_DIR/gb10-elevated.service" <<'UNIT'
[Unit]
Description=GB10 temporary sudo for admins (grants, expiry, audit log)
After=network.target

[Service]
EnvironmentFile=/etc/gb10/elevate.env
ExecStart=/usr/local/sbin/gb10-elevated
Restart=always
RestartSec=3
# the web socket lives in /run/gb10-elevate and is bind-mounted into the dashboard container; keep the directory when the unit stops
RuntimeDirectory=gb10-elevate
RuntimeDirectoryPreserve=yes

[Install]
WantedBy=multi-user.target
UNIT
cat > "$UNIT_DIR/gb10-elevate-sweep.service" <<'UNIT'
[Unit]
Description=GB10 end expired sudo grants

[Service]
Type=oneshot
EnvironmentFile=/etc/gb10/elevate.env
ExecStart=/usr/local/sbin/gb10-elevated --sweep
UNIT
cat > "$UNIT_DIR/gb10-elevate-sweep.timer" <<'UNIT'
[Unit]
Description=GB10 end expired sudo grants, every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT
sc daemon-reload
sc enable --now gb10-elevated.service
sc restart gb10-elevated.service
sc enable --now gb10-elevate-sweep.timer

echo
say "done. daemon: $(systemctl is-active gb10-elevated 2>/dev/null || echo 'not running (test mode)')"
echo "  next : docker compose up -d --build admin-dashboard   (mounts /run/gb10-elevate; the Elevate card appears for admins at /home/)"
echo "  check: gb10-elevate status   |   sudo journalctl -u gb10-elevated -n 20"
