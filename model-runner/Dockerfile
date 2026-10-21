ARG VLLM_IMAGE
FROM ${VLLM_IMAGE}

ARG LLAMA_SWAP_VERSION
# Verify the arm64 asset name on the llama-swap releases page for your version.
ADD https://github.com/mostlygeek/llama-swap/releases/download/v${LLAMA_SWAP_VERSION}/llama-swap_${LLAMA_SWAP_VERSION}_linux_arm64.tar.gz /tmp/llama-swap.tgz
RUN tar -xzf /tmp/llama-swap.tgz -C /usr/local/bin llama-swap \
 && rm /tmp/llama-swap.tgz \
 && chmod +x /usr/local/bin/llama-swap

# OpenTelemetry packages required by vLLM --otlp-traces-endpoint
RUN pip install --no-cache-dir \
      "opentelemetry-sdk>=1.26,<2" \
      "opentelemetry-api>=1.26,<2" \
      "opentelemetry-exporter-otlp>=1.26,<2" \
      "opentelemetry-semantic-conventions-ai>=0.4,<1"

EXPOSE 8000 10001 10002
ENTRYPOINT ["llama-swap", "--config", "/config/config.yaml", "--listen", "0.0.0.0:8000", "--watch-config"]
