ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG JUPYTERHUB_VERSION
ENV PIP_NO_CACHE_DIR=1

# NVIDIA's PyTorch image already has CUDA torch and JupyterLab. Added here:
#   jupyterhub          the single-user server (the version must match the Hub)
#   jupyterlab-git      Git panel
#   jupyter-ai (+ -jupyternaut, -litellm)   chat and %%ai magics, models through LiteLLM
#   jupyter-resource-usage                   memory use against the container limit in the status bar
#   voila, papermill                         notebooks as apps; run notebooks with parameters
#   jupyter-fsspec, s3fs, boto3              storage browser and S3 access for notebook code
#   openai, langchain-openai                 clients for the LiteLLM gateway (the key is in the environment)
# fsspec and s3fs are held at 2026.2.0 because the image's `datasets` package needs fsspec <= 2026.2.0; do not use papermill[s3],
# it pulls in an ancient s3fs.
# litellm (the library jupyter-ai calls the gateway with) is held at 1.105.3: from 1.106 any request that carries tools imports code that
# needs mcp >= 2.2, while jupyter-ai's langchain-mcp-adapters needs mcp < 2, so every Jupyternaut reply that uses a tool fails with
# "cannot import name CacheableResult". The LiteLLM *proxy* container is a separate install and stays on its own version.
# PyYAML comes from Debian without pip's install record, so pip cannot upgrade it: replace that one package explicitly first (a global
# --ignore-installed could try to reinstall torch).
RUN pip install --ignore-installed pyyaml
RUN pip install "jupyterhub==${JUPYTERHUB_VERSION}" ipywidgets jupyterlab-git \
        jupyter-ai jupyter-ai-jupyternaut jupyter-ai-litellm jupyter-resource-usage voila papermill jupyter-fsspec \
        "fsspec==2026.2.0" "s3fs==2026.2.0" "litellm==1.105.3" boto3 openai langchain-openai

COPY notebook-start /usr/local/bin/notebook-start
COPY examples /opt/examples
COPY jupyter_server_config.py /etc/jupyter/jupyter_server_config.py

# Run as an ordinary user, not root: a notebook terminal is a shell in this container.
# The base image already has `ubuntu` at uid 1000.
RUN mkdir /work && chown ubuntu:ubuntu /work
USER ubuntu
WORKDIR /work
ENV HOME=/home/ubuntu

EXPOSE 8888
