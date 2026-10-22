# TODO

Planned work that is not part of the current setup. For things that still need checking, see `TO-VERIFY.md`.

## Observability

- [ ] **Host network metrics.** node-exporter runs in a container and reports the container's own network interfaces, not the host's, so the dashboard has no host-level traffic numbers. Options to try:
  - run node-exporter with `network_mode: host` (check that it still reaches the `obs` network for Prometheus, for example by publishing `127.0.0.1:9100` and scraping it through the host gateway), or
  - add `--collector.netdev.device-include` filters and mount `/proc/1/net` from the host.
  
  Then add host traffic panels (per-interface rx/tx, errors) to `observability/grafana/dashboards/gb10-overview.json`. Keep `--no-collector.cpufreq`, which hangs on the GB10.
