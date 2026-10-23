#!/usr/bin/env bash
# Configures Portainer EE through its API. Safe to re-run.
#   scripts/portainer-setup.sh config   local environment, restrictions for regular users, `users` team, OAuth settings (Authelia)
#   scripts/portainer-setup.sh sso      switch login to OAuth (do this after adding the license in the UI)
#   scripts/portainer-setup.sh local    switch login back to Portainer's own accounts (break-glass: log in as `admin`)
# Portainer only accepts non-admin logins once a license is present: add it in the UI first (Settings → Licenses).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a
export ROOT PUBLIC_HOST

python3 -I - "${1:-}" <<'PY'
import json, os, sys, urllib.request, urllib.error
root, host = os.environ["ROOT"], os.environ["PUBLIC_HOST"]
BASE = "http://127.0.0.1:9010/api"          # Portainer's published port, localhost only

def call(method, path, body=None, token=None):
    req = urllib.request.Request(BASE + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read().decode(); return json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: {e.code} {e.read().decode()[:300]}")

def secret(name): return open(f"{root}/secrets/{name}").read().strip()

token = call("POST", "/auth", {"username": "admin", "password": secret("portainer_admin_password")})["jwt"]
cmd = sys.argv[1]
if cmd == "local":
    call("PUT", "/settings", {"AuthenticationMethod": 1}, token); print("login: Portainer accounts")
elif cmd == "sso":
    call("PUT", "/settings", {"AuthenticationMethod": 3}, token); print("login: OAuth (Authelia)")
elif cmd == "config":
    if not call("GET", "/endpoints", token=token):
        import subprocess      # urllib has no multipart; the local Docker socket environment is created with curl
        subprocess.run(["curl", "-sf", "-o", "/dev/null", "-X", "POST", BASE + "/endpoints", "-H", "Authorization: Bearer " + token,
                        "-F", "Name=local", "-F", "EndpointCreationType=1"], check=True)
    ep = call("GET", "/endpoints", token=token)[0]["Id"]
    teams = call("GET", "/teams", token=token)
    team = next((t["Id"] for t in teams if t["Name"] == "users"), None) or call("POST", "/teams", {"name": "users"}, token)["Id"]
    # Regular users: no bind mounts, privileged mode, host namespaces, devices, capabilities, sysctls, security options or stacks.
    # GPU containers still work: they use a device request (--gpus), not a device mapping.
    sec = call("GET", f"/endpoints/{ep}", token=token)["SecuritySettings"]
    sec.update({k: False for k in sec if k.startswith("allow")})
    call("PUT", f"/endpoints/{ep}/settings", {"securitySettings": sec}, token)
    call("PUT", f"/endpoints/{ep}", {"TeamAccessPolicies": {str(team): {"RoleId": 3}}}, token)   # role 3 = Standard User
    # Server-side OIDC calls use the docker0 listener in the Caddyfile (containers cannot reach the public hostname).
    call("PUT", "/settings", {"OAuthSettings": {
        "ClientID": "portainer", "ClientSecret": secret("portainer_oidc_secret"),
        "AccessTokenURI": "http://172.17.0.1:9081/auth/api/oidc/token",
        "AuthorizationURI": f"https://{host}/auth/api/oidc/authorization",
        "ResourceURI": "http://172.17.0.1:9081/auth/api/oidc/userinfo",
        "RedirectURI": f"https://{host}/portainer/", "LogoutURI": f"https://{host}/auth/logout",
        "UserIdentifier": "preferred_username", "Scopes": "openid profile email groups",
        "OAuthAutoCreateUsers": True, "SSO": True, "AuthStyle": 1, "DefaultTeamID": 0, "OAuthAutoMapTeamMemberships": True,
        "TeamMemberships": {"OAuthClaimName": "groups", "OAuthClaimMappings": [{"ClaimValRegex": "^users$", "Team": team}],
                            "AdminAutoPopulate": True, "AdminGroupClaimsRegexList": ["^admins$"]},
        "HideInternalAuth": False}}, token)
    print("configured: environment", ep, "· team users", team, "· restrictions · OAuth")
else:
    sys.exit("usage: scripts/portainer-setup.sh config|sso|local")
PY
