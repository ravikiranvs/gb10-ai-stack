ARG JUPYTERHUB_VERSION
FROM quay.io/jupyterhub/jupyterhub:${JUPYTERHUB_VERSION}

ENV PIP_NO_CACHE_DIR=1
RUN pip install oauthenticator jupyterhub-idle-culler

COPY jupyterhub_config.py bridge_spawner.py /srv/jupyterhub/
WORKDIR /srv/jupyterhub
CMD ["jupyterhub", "-f", "/srv/jupyterhub/jupyterhub_config.py"]
