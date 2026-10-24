#!/usr/bin/env bash
# Host side of the browser terminal (/term/). Run as root, from anywhere; safe to run again:
#   sudo bash host/setup.sh              install everything below
#   sudo bash host/setup.sh --hidepid    additionally hide other people's processes from ordinary accounts (optional, see the end)
# Undo: sudo bash host/uninstall.sh
#
# What it does
#   1. group gb10-users (gid 20000): the accounts the browser terminal logs in to
#   2. a dedicated sshd on 172.17.0.1:2222 (docker0 only), certificates signed by secrets/ssh_ca only, as a systemd service; its host key is
#      written to data/ttyd/etc/known_hosts for the ttyd container
#   3. a DenyGroups drop-in on YOUR sshd (port 22) so these accounts can only come in through the browser terminal
#   4. the per-user network block (host/gb10-users.nft) as a systemd service
#   5. the account sync (host/sync-accounts.sh) as a timer every 5 minutes, and one run now
#   6. tmux, for people who want a session that survives a closed tab (they start it by hand; browser sessions end with the tab)
# It never touches your own account, your sshd configuration file, Docker or the stack. Nothing is deleted.
#
# GB10_TEST=1 writes the files and runs the checks but does not start, stop or load anything (used to test this script in a container).
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
ROOT="${GB10_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HOSTDIR="$ROOT/host"
TEST="${GB10_TEST:-}"
ETC_SSH="${GB10_ETC_SSH:-/etc/ssh}"
UNIT_DIR="${GB10_UNIT_DIR:-/etc/systemd/system}"
ETC_GB10="${GB10_ETC:-/etc/gb10}"
GROUP=gb10-users
GID=20000
HIDEPID=0
[[ "${1:-}" == "--hidepid" ]] && HIDEPID=1

say() { echo "gb10-host: $*"; }
sc()  { if [[ -n "$TEST" ]]; then echo "   [test mode] systemctl $*"; else systemctl "$@"; fi; }
changed=0
install_if_changed() {   # src dest mode
  if [[ -f "$2" ]] && cmp -s "$1" "$2"; then return 0; fi
  install -D -m "$3" "$1" "$2"; changed=1; say "wrote $2"
}
write_if_changed() {     # dest mode  (content on stdin)
  local tmp; tmp="$(mktemp)"; cat > "$tmp"
  install_if_changed "$tmp" "$1" "$2"; rm -f "$tmp"
}

# ── preflight ──────────────────────────────────────────────────────────────────────────────
for f in "$HOSTDIR/gb10-sshd_config" "$HOSTDIR/gb10-users.nft" "$HOSTDIR/sync-accounts.sh" "$ROOT/secrets/ssh_ca.pub"; do
  [[ -s "$f" ]] || { echo "missing $f (run scripts/init-secrets.sh first for the CA key)" >&2; exit 1; }
done
for c in sshd ssh-keygen nft useradd python3; do command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }; done
python3 -c "import yaml" 2>/dev/null || { echo "python3-yaml is required (apt install python3-yaml)" >&2; exit 1; }
if [[ -z "$TEST" ]] && ! ip link show docker0 >/dev/null 2>&1; then
  echo "docker0 not found: the dedicated sshd listens on 172.17.0.1 (docker0). Start Docker first." >&2; exit 1
fi

# ── 1. group ───────────────────────────────────────────────────────────────────────────────
if ! getent group "$GROUP" >/dev/null; then groupadd -g "$GID" "$GROUP"; say "created group $GROUP"; fi

# ── 6. tmux ────────────────────────────────────────────────────────────────────────────────
if ! command -v tmux >/dev/null; then
  if [[ -n "$TEST" ]]; then echo "   [test mode] apt-get install tmux"; else DEBIAN_FRONTEND=noninteractive apt-get install -y tmux >/dev/null; say "installed tmux"; fi
fi

# ── 2. dedicated sshd ──────────────────────────────────────────────────────────────────────
GB10_SSH="$ETC_SSH/gb10"
install -d -m 755 "$GB10_SSH"
install_if_changed "$HOSTDIR/gb10-sshd_config" "$GB10_SSH/sshd_config" 644
install_if_changed "$ROOT/secrets/ssh_ca.pub" "$GB10_SSH/ca.pub" 644
if [[ ! -f "$GB10_SSH/ssh_host_ed25519_key" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C "gb10-sshd" -f "$GB10_SSH/ssh_host_ed25519_key"; say "generated the dedicated sshd's host key"; changed=1
fi
# paths inside the copied config point at /etc/ssh/gb10; in test mode they are rewritten so the config can be checked where /etc/ssh/gb10 is not used
SSHD_CHECK_CONF="$GB10_SSH/sshd_config"
if [[ "$GB10_SSH" != "/etc/ssh/gb10" ]]; then
  SSHD_CHECK_CONF="$(mktemp)"; sed "s#/etc/ssh/gb10#$GB10_SSH#g" "$GB10_SSH/sshd_config" > "$SSHD_CHECK_CONF"
fi
mkdir -p /run/sshd
sshd -t -f "$SSHD_CHECK_CONF" || { echo "the dedicated sshd configuration did not pass sshd -t; nothing was started" >&2; exit 1; }

write_if_changed "$UNIT_DIR/gb10-sshd.service" 644 <<'EOF'
[Unit]
Description=GB10 dedicated sshd (certificate logins from the browser terminal)
After=network-online.target docker.service
Wants=docker.service

[Service]
# /run/sshd (privilege separation) is shared with Ubuntu's own ssh.service. A RuntimeDirectory= here would delete it when this unit stops
# and break the admin's sshd, so it is only created, never removed.
ExecStartPre=/bin/mkdir -p -m 0755 /run/sshd
ExecStartPre=/usr/sbin/sshd -t -f /etc/ssh/gb10/sshd_config
ExecStart=/usr/sbin/sshd -D -e -f /etc/ssh/gb10/sshd_config
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# known_hosts for the ttyd container: it pins this sshd's host key (StrictHostKeyChecking=yes)
KH="$ROOT/data/ttyd/etc/known_hosts"
TTYD_UID="$(sed -n 's/^TTYD_UID=\([0-9]*\).*/\1/p' "$ROOT/.env" 2>/dev/null | head -1)"; TTYD_GID="$(sed -n 's/^TTYD_GID=\([0-9]*\).*/\1/p' "$ROOT/.env" 2>/dev/null | head -1)"
install -d -m 755 "$(dirname "$KH")"
printf '[gb10-host]:2222 %s\n' "$(cut -d' ' -f1,2 "$GB10_SSH/ssh_host_ed25519_key.pub")" > "$KH.new"
if ! cmp -s "$KH.new" "$KH" 2>/dev/null; then mv "$KH.new" "$KH"; say "wrote $KH"; else rm -f "$KH.new"; fi
chmod 644 "$KH"; [[ -n "$TTYD_UID" ]] && chown "$TTYD_UID:${TTYD_GID:-$TTYD_UID}" "$KH" || true

# ── 3. keep these accounts off the admin's own sshd (port 22) ──────────────────────────────
DENY="$ETC_SSH/sshd_config.d/60-gb10-deny.conf"
if [[ ! -f "$DENY" ]]; then
  install -d -m 755 "$ETC_SSH/sshd_config.d"
  printf '# gb10: accounts for the browser terminal may only come in through the dedicated sshd (port 2222)\nDenyGroups %s\n' "$GROUP" > "$DENY"
  if ! sshd -t 2>/tmp/gb10-sshd-check.err; then   # never leave the admin's sshd with a broken configuration
    rm -f "$DENY"; echo "sshd -t failed with the DenyGroups drop-in; it was removed again:" >&2; cat /tmp/gb10-sshd-check.err >&2; exit 1
  fi
  say "wrote $DENY (your sshd on port 22 now refuses $GROUP; it reads this at the next connection)"
fi

# ── 4. network block ───────────────────────────────────────────────────────────────────────
install -d -m 755 "$ETC_GB10"
install_if_changed "$HOSTDIR/gb10-users.nft" "$ETC_GB10/gb10-users.nft" 644
nft -c -f "$ETC_GB10/gb10-users.nft" || { echo "the nftables file did not pass nft -c; nothing was loaded" >&2; exit 1; }
write_if_changed "$UNIT_DIR/gb10-users-nft.service" 644 <<EOF
[Unit]
Description=GB10 per-user network block (accounts in uid 20000-29999 cannot reach the stack's services)
Wants=network-pre.target
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $ETC_GB10/gb10-users.nft
ExecReload=/usr/sbin/nft -f $ETC_GB10/gb10-users.nft
ExecStop=-/usr/sbin/nft delete table inet gb10_users

[Install]
WantedBy=multi-user.target
EOF

# ── 5. account sync timer ──────────────────────────────────────────────────────────────────
write_if_changed "$UNIT_DIR/gb10-accounts.service" 644 <<EOF
[Unit]
Description=GB10 browser-terminal accounts (from Authelia's users.yml)

[Service]
Type=oneshot
ExecStart=/bin/bash $HOSTDIR/sync-accounts.sh
EOF
write_if_changed "$UNIT_DIR/gb10-accounts.timer" 644 <<'EOF'
[Unit]
Description=GB10 browser-terminal accounts, every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

if (( changed )); then sc daemon-reload; fi
sc enable --now gb10-users-nft.service
sc enable --now gb10-sshd.service
sc enable --now gb10-accounts.timer
if [[ -z "$TEST" ]]; then
  sc restart gb10-sshd.service        # picks up a changed config or CA; open sessions are kept (KillMode=process)
  GB10_UNIT_DIR="$UNIT_DIR" bash "$HOSTDIR/sync-accounts.sh"
else
  echo "   [test mode] bash $HOSTDIR/sync-accounts.sh"
fi

# ── optional: hide other people's processes ────────────────────────────────────────────────
if (( HIDEPID )); then
  getent group procview >/dev/null || groupadd -r procview
  OWNER="$(stat -c %U "$ROOT")"; usermod -aG procview "$OWNER" 2>/dev/null || true
  write_if_changed "$UNIT_DIR/systemd-logind.service.d/50-gb10-hidepid.conf" 644 <<'EOF'
[Service]
SupplementaryGroups=procview
EOF
  PVGID="$(getent group procview | cut -d: -f3)"
  if ! grep -q "hidepid" /etc/fstab 2>/dev/null; then
    printf 'proc /proc proc defaults,hidepid=2,gid=%s 0 0\n' "$PVGID" >> /etc/fstab; say "added the hidepid line to /etc/fstab"
  fi
  sc daemon-reload
  if [[ -z "$TEST" ]]; then
    sc restart systemd-logind
    mount -o "remount,hidepid=2,gid=$PVGID" /proc
    say "hidepid is on: ordinary accounts see only their own processes ($OWNER and root see all; log in again to get the new group). To undo: mount -o remount,hidepid=0 /proc and remove the line from /etc/fstab"
  fi
fi

echo
say "done."
echo "  dedicated sshd : $(systemctl is-active gb10-sshd.service 2>/dev/null || echo 'not running (test mode)')   (listens on 172.17.0.1:2222)"
echo "  network block  : $(nft list table inet gb10_users >/dev/null 2>&1 && echo loaded || echo 'not loaded (test mode)')"
echo "  accounts       : $(getent group $GROUP | cut -d: -f4 | tr ',' ' ')"
echo "  next           : open https://<your host>/term/ in a browser as an Authelia admin/user"
