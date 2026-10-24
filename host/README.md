# Host side of the browser terminal

`/term/` opens a shell on **this machine** in the browser, as the person's own Linux account (no sudo, no docker group). The stack side
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

## Check it works

```bash
systemctl status gb10-sshd                 # active; listening on 172.17.0.1:2222
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
