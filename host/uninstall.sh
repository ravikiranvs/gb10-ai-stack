#!/usr/bin/env bash
# Undo host/setup.sh. Run as root:  sudo bash host/uninstall.sh
# Stops and removes the dedicated sshd, the network block and the account timer, and removes the DenyGroups drop-in. It does NOT delete the
# Linux accounts, their home directories or the group (their data is kept); it only disables them by removing them from gb10-users.
# The secrets (secrets/ssh_ca*) and data/ttyd are left in place.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
for u in gb10-accounts.timer gb10-accounts.service gb10-sshd.service gb10-users-nft.service; do
  systemctl disable --now "$u" 2>/dev/null || true
  rm -f "/etc/systemd/system/$u"
done
rm -rf /etc/systemd/system/systemd-logind.service.d/50-gb10-hidepid.conf
rm -f /etc/ssh/sshd_config.d/60-gb10-deny.conf /etc/gb10/gb10-users.nft
rm -rf /etc/ssh/gb10
nft delete table inet gb10_users 2>/dev/null || true
for name in $(getent group gb10-users | cut -d: -f4 | tr ',' ' '); do gpasswd -d "$name" gb10-users >/dev/null && echo "removed $name from gb10-users (account and files kept)"; done
systemctl daemon-reload
if grep -q "hidepid" /etc/fstab; then echo "NOTE: /etc/fstab still has the hidepid line for /proc; remove it and run: mount -o remount,hidepid=0 /proc"; fi
echo "uninstalled. The per-user limit drop-ins in /etc/systemd/system/user-*.slice.d/50-gb10.conf are still there; delete them if you want."
