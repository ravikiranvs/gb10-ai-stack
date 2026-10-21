ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG COMFYUI_REF
ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone https://github.com/comfyanonymous/ComfyUI.git \
 && cd ComfyUI \
 && git checkout "${COMFYUI_REF}"

WORKDIR /opt/ComfyUI
# Keep NVIDIA's CUDA-enabled torch build from the base image
RUN grep -viE '^(torch|torchvision|torchaudio)([<>=~ ].*)?$' requirements.txt > /tmp/requirements.txt \
 && pip install -r /tmp/requirements.txt

EXPOSE 8188
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188", "--disable-auto-launch"]
