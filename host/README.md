# Host side of the browser terminal

`/term/` opens a shell on **this machine** in the browser, as the person's own Linux account (no sudo, no docker group; admins can take [temporary sudo](#temporary-sudo-admins-only)). The stack side
(ttyd, Caddy route, Authelia rule, the CA key `secrets/ssh_ca`) is in `compose.yaml`; this folder is the part that needs root.

## Install

```bash
sudo bash host/setup.sh                # safe to run again
sudo bash host/setup.sh --hidepid      # optional, later: ordinary accounts see only their own processes
```

It creates the group `gb10-users`, a **dedicated sshd** (`172.17.0.1:2222`, certificates signed by `secrets/ssh_ca` only), a `DenyGroups` drop-in on
your own sshd (port 22), the per-user **network block**, the account sync timer (every 5 minutes) and installs `tmux` (optional for people: a browser session ends when the tab closes or the shell exits, `tmux` is how someone keeps one running on purpose). It never edits
`/etc/ssh/sshd_config`, your account, Docker or the stack, and deletes nothing. Remove it all with `sudo bash host/uninstall.sh`
(accounts and their files are kept, only disabled).

| File | Purpose |
|---|---|
| `setup.sh`, `uninstall.sh` | install and undo (`GB10_TEST=1` writes files and runs the checks without starting anything) |
| `gb10-sshd_config` | the dedicated sshd: certificates only, `AllowGroups gb10-users`, no forwarding, `UsePAM yes` so each login gets a systemd user session |
| `gb10-users.nft` | accounts in uid 20000-29999 cannot reach loopback ports, the machine's own addresses or Docker's networks; they keep the internet, DNS and Caddy (`127.0.0.1:9080`) |
| `sync-accounts.sh` | creates/re-enables/disables accounts from Authelia's `users.yml` (`--dry-run` shows what it would do) |

## Accounts

Every enabled Authelia user in the group `admins` or `users` gets an account with the same name: uid 20000-29999, group `gb10-users`, no sudo,
no docker, password `*`, home mode 750, and limits through `user-<uid>.slice` (default **16G memory, no swap, 1024 tasks, 400% CPU**; change them in
`/etc/gb10/accounts.env` with `GB10_MEM_MAX`, `GB10_TASKS_MAX`, `GB10_CPU_QUOTA`). The GPU is open to every account (the device nodes are world-writable).

- A name that already exists on the machine (your own `admin`, `root`, anything not created by the script) is **skipped with a warning, never changed**.
- A person removed or disabled in Authelia loses the group and their sessions end; **their files are kept**.
- The script refuses to run on an unreadable or empty `users.yml` instead of disabling everyone.
- To disable an account by hand, remove it from the group (`gpasswd -d NAME gb10-users`). **`passwd -l` does not work here**: with `UsePAM yes` a locked
  account can still log in with a certificate. (With `UsePAM no` it is the other way round and a locked account refuses certificate logins: that is why the
  accounts use the password field `*`.)

## Temporary sudo (admins only)

Accounts have no sudo. An admin can get it for a short time from the dashboard (`/home/`, **Temporary sudo** tab: a reason of 5-200 characters and 5/15/30/60 minutes;
the page is behind Authelia two-factor, nobody else has to approve). Install: `sudo bash host/elevate-setup.sh` (then `docker compose up -d --build admin-dashboard`). `--no-auditd` installs without the auditd rule.

- A grant is one file, `/etc/sudoers.d/gb10-grant-<uid>`, checked with `visudo -cf` before it goes live. It lasts until it expires or the person presses **End now** /
  types `gb10-elevate drop`; then the file is removed and every root process of that login (`sudo -s`, `sudo -i`, a command under sudo) gets SIGHUP, and SIGKILL 5 s later.
  The daemon checks every 5 s; a systemd timer does the same every minute if the daemon is down; after a reboot leftover grant files are deleted.
- Only enabled members of `admins` in `users.yml` with a browser-terminal account can be granted, and the daemon checks that itself; the dashboard only passes the signed-in name on.
  The root daemon listens on two sockets in `/run/gb10-elevate`: `web.sock` (owner = the dashboard container's uid 10001, mode 0600) and `user.sock` (any account, but only
  `status` and `drop` for itself, identified by SO_PEERCRED). `gb10-elevate` in the terminal is the client of the second one and cannot grant.
- Audit, kept 30 days (`GB10_ELEVATE_KEEP_DAYS` in `/etc/gb10/elevate.env`, pruned hourly): the grant log `/var/log/gb10-elevate/grants-YYYY-MM-DD.jsonl` (who, when, reason, minutes,
  source address, how it ended; append-only attribute set), sudo's full input/output recordings in `/var/log/sudo-io` (replay: unpack the download, `sudoreplay -d sudo-io <id>`),
  sudo's normal syslog lines, and an auditd rule (`sudo ausearch -k gb10-elevated -i`) for every program run as root by a browser-terminal login. The dashboard tab lists events and
  recorded commands and has download links (grant log, everything, one recording).
- Limits: root can remove its own traces (`chattr -a`, deleting recordings), so this is a deterrent plus a record, not tamper-proof; copy the logs off the machine if you need that.
  A root process that outlives the grant on purpose (a container started with `docker run -d`, a cron job, a changed file) is not stopped: read the recording. Root also bypasses the
  per-user network block (it matches uids 20000-29999) and can read every secret on the machine, so give it only to people you would give the machine to.
- Remove: `sudo bash host/elevate-setup.sh --uninstall` (logs and `/etc/gb10/elevate.env` are kept).

## Check it works

```bash
systemctl status gb10-sshd                 # active; listening on 172.17.0.1:2222
systemctl status gb10-elevated             # only with elevate-setup.sh; web.sock and user.sock in /run/gb10-elevate
sudo nft list table inet gb10_users        # the per-user block is loaded
getent group gb10-users                    # the accounts
# in the browser: https://<your host>/term/  (Authelia, two-factor), then in the terminal:
id                                          # your own account, no sudo
curl -m 3 http://127.0.0.1:9000/ ; echo $?  # must time out (the dashboard is blocked for these accounts)
curl -m 3 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9080/   # Caddy answers (it authenticates every request itself)
```

## Known limits

- ttyd's limit of 20 connections is shared by everyone: one person opening many tabs can use the slots up.
- Blocked connections time out (about 3 s) instead of failing at once.
- A shell on the machine that holds every secret is the weakest point of the setup: keep the system patched. A kernel bug in an unprivileged account could
  give root. The account limits and the network block reduce the damage a person can do; they are not a container.
- `hidepid` (`--hidepid`) is optional because it restarts `systemd-logind` and remounts `/proc`; do it when you can watch it.
