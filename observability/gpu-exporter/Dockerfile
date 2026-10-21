FROM ubuntu:24.04

# nvidia-smi is injected by the NVIDIA container runtime (NVIDIA_DRIVER_CAPABILITIES=utility)
COPY collect.sh /usr/local/bin/collect.sh
RUN chmod +x /usr/local/bin/collect.sh

CMD ["/usr/local/bin/collect.sh"]
