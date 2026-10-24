"""JupyterHub spawner that asks ops-bridge to run each person's server container.

The Hub holds no Docker access: it can only call the actions of its ops-bridge client (notebook.*, litellm.key, s3.provision), and the
bridge decides what the container looks like (see ops-bridge/actions.yaml, template `notebook`). All state is derived from the user
name, so servers survive a Hub restart.

Before each start the Hub makes sure the person has a LiteLLM key and a storage key. Both are derived from a secret that only the Hub
holds, so they are the same on every start and nothing is stored. They reach the container as environment variables
(OPENAI_API_KEY, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY), so the openai package, LangChain, boto3 and s3fs work with no setup.
"""

import hashlib
import hmac
import json
import os
import re

from jupyterhub.spawner import Spawner
from tornado.httpclient import AsyncHTTPClient, HTTPClientError, HTTPRequest
from traitlets import Integer, Unicode

ENV_NAME = re.compile(r"^(JUPYTERHUB|JPY)_[A-Z0-9_]{1,60}$")


class BridgeSpawner(Spawner):
    bridge_url = Unicode(os.environ.get("BRIDGE_URL", "http://ops-bridge:9200"), config=True)
    token_file = Unicode("/run/secrets/bridge_jupyterhub_token", config=True)
    action_prefix = Unicode("notebook", config=True, help="Actions are <prefix>.spawn, .status and .stop")
    secret_file = Unicode("/run/secrets/jupyterhub_cred_secret", config=True, help="Only the Hub holds this; credentials are derived from it")
    server_port = Integer(8888, config=True)

    def _derive(self, purpose, length):
        with open(self.secret_file) as f:
            secret = f.read().strip()
        return hmac.new(secret.encode(), f"{purpose}:{self.user.name}".encode(), hashlib.sha256).hexdigest()[:length]

    def _credentials(self):
        return {"key": "sk-nb-" + self._derive("llm", 40), "access": "nb-" + self._derive("s3-access", 16),
                "secret": self._derive("s3-secret", 40)}

    async def _call(self, action, env=None, timeout=120):
        return await self._action(f"{self.action_prefix}.{action}", {"user": self.user.name}, env, timeout)

    async def _action(self, name, params, env=None, timeout=120):
        with open(self.token_file) as f:
            token = f.read().strip()
        body = {"params": params}
        if env is not None:
            body["env"] = env
        req = HTTPRequest(f"{self.bridge_url}/v1/actions/{name}", method="POST",
                          headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                          body=json.dumps(body), request_timeout=timeout)
        try:
            resp = await AsyncHTTPClient().fetch(req)
        except HTTPClientError as exc:
            detail = exc.response.body.decode(errors="replace")[:300] if exc.response is not None else str(exc)
            raise RuntimeError(f"ops-bridge {name} failed for {self.user.name}: {detail}") from exc
        return json.loads(resp.body)

    async def start(self):
        env = {k: v for k, v in self.get_env().items() if ENV_NAME.match(k)}
        user, creds = self.user.name, self._credentials()
        await self._action("litellm.key", {"user": user, "key": creds["key"]})
        await self._action("s3.provision", {"user": user, "access": creds["access"], "secret": creds["secret"]})
        env.update(OPENAI_API_KEY=creds["key"], AWS_ACCESS_KEY_ID=creds["access"], AWS_SECRET_ACCESS_KEY=creds["secret"],
                   S3_BUCKET=f"u-{user}")
        result = await self._call("spawn", env)
        self.log.info("started %s for %s", result.get("name"), self.user.name)
        return f"http://{result['name']}:{self.server_port}"

    async def stop(self, now=False):
        await self._call("stop")

    async def poll(self):
        result = await self._call("status", timeout=30)
        state = result.get("state")
        if state in ("running", "created", "restarting"):
            return None
        return result.get("exit_code") or 0     # exited or missing: the server is not there

    def get_state(self):
        return super().get_state()

    def load_state(self, state):
        super().load_state(state)
