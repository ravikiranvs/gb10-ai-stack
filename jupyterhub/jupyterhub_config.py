# JupyterHub behind Caddy at /jupyter. Sign-in is Authelia (OIDC client `jupyterhub`, see authelia/configuration.yml); every person
# gets their own container, started through ops-bridge (bridge_spawner.py).
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the `jupyterhub` script does not put this folder on the path

from bridge_spawner import BridgeSpawner  # noqa: E402
from oauthenticator.generic import GenericOAuthenticator  # noqa: E402

c = get_config()  # noqa: F821  (provided by JupyterHub)
host = os.environ["PUBLIC_HOST"]


def secret(name):
    with open(f"/run/secrets/{name}") as f:
        return f.read().strip()


# ── web and internal addresses ──
c.JupyterHub.base_url = "/jupyter"
c.JupyterHub.ip = "0.0.0.0"
c.JupyterHub.port = 8000                                # Caddy forwards /jupyter* here; the path is kept
c.JupyterHub.hub_ip = "0.0.0.0"
c.JupyterHub.hub_port = 8081
c.JupyterHub.hub_connect_ip = "jupyterhub"             # how the notebook containers (network `notebooks`) reach the Hub API
c.JupyterHub.db_url = "sqlite:////data/jupyterhub.sqlite"
c.JupyterHub.cookie_secret_file = "/data/jupyterhub_cookie_secret"
c.JupyterHub.cleanup_servers = False                   # a Hub restart must not stop everyone's notebooks
c.JupyterHub.allow_named_servers = False

# ── sign-in: Authelia OIDC ──
# Token and userinfo calls use the docker0 listener in the Caddyfile (containers cannot reach the public hostname).
c.JupyterHub.authenticator_class = GenericOAuthenticator
c.GenericOAuthenticator.client_id = "jupyterhub"
c.GenericOAuthenticator.client_secret = secret("jupyterhub_oidc_secret")
c.GenericOAuthenticator.oauth_callback_url = f"https://{host}/jupyter/hub/oauth_callback"
c.GenericOAuthenticator.authorize_url = f"https://{host}/auth/api/oidc/authorization"
c.GenericOAuthenticator.token_url = "http://172.17.0.1:9081/auth/api/oidc/token"
c.GenericOAuthenticator.userdata_url = "http://172.17.0.1:9081/auth/api/oidc/userinfo"
c.GenericOAuthenticator.basic_auth = True                              # Authelia client: token_endpoint_auth_method client_secret_basic
c.GenericOAuthenticator.scope = ["openid", "profile", "email", "groups"]
c.GenericOAuthenticator.username_claim = "preferred_username"
c.GenericOAuthenticator.claim_groups_key = "groups"
c.GenericOAuthenticator.manage_groups = True                       # required for claim_groups_key; mirrors the Authelia groups in the Hub
c.GenericOAuthenticator.allowed_groups = {"admins", "users"}   # the same rule as Portainer
c.GenericOAuthenticator.admin_groups = {"admins"}
c.GenericOAuthenticator.login_service = "Authelia"
c.GenericOAuthenticator.auto_login = True                      # no intermediate "Sign in with" page
c.GenericOAuthenticator.username_pattern = r"^[a-z][a-z0-9._-]{1,31}$"   # what ops-bridge accepts

# ── servers ──
c.JupyterHub.spawner_class = BridgeSpawner
c.Spawner.ip = "0.0.0.0"
c.Spawner.port = 8888
c.Spawner.default_url = "/lab"
c.Spawner.env_keep = []                                         # nothing from the Hub's own environment reaches a user container
c.Spawner.start_timeout = 180                                   # a GPU container with a large image can take a while
c.Spawner.http_timeout = 120

# ── stop servers nobody uses (the files stay in the user's volume) ──
c.JupyterHub.load_roles = [{
    "name": "idle-culler",
    "scopes": ["list:users", "read:users:activity", "read:servers", "delete:servers"],
    "services": ["idle-culler"],
}]
c.JupyterHub.services = [{
    "name": "idle-culler",
    "command": [sys.executable, "-m", "jupyterhub_idle_culler", "--timeout=3600", "--cull-every=300"],
}]
