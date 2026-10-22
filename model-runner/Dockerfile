ARG VLLM_IMAGE
FROM ${VLLM_IMAGE}

ARG LLAMA_SWAP_VERSION
# Verify the arm64 asset name on the llama-swap releases page for your version.
ADD https://github.com/mostlygeek/llama-swap/releases/download/v${LLAMA_SWAP_VERSION}/llama-swap_${LLAMA_SWAP_VERSION}_linux_arm64.tar.gz /tmp/llama-swap.tgz
RUN tar -xzf /tmp/llama-swap.tgz -C /usr/local/bin llama-swap \
 && rm /tmp/llama-swap.tgz \
 && chmod +x /usr/local/bin/llama-swap

# vLLM --otlp-traces-endpoint needs the OpenTelemetry packages; NVIDIA's vLLM image already ships them (no pip install here)
EXPOSE 8000 10001
ENTRYPOINT ["llama-swap", "--config", "/config/config.yaml", "--listen", "0.0.0.0:8000", "--watch-config"]
