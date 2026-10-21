#!/usr/bin/env bash
# Writes GB10 GPU metrics for node-exporter's textfile collector.
# DCGM does not work on GB10 unified memory; nvidia-smi fields that return N/A are exported as NaN.
set -uo pipefail

OUT="${TEXTFILE_DIR:-/textfile}/gpu.prom"
INTERVAL="${INTERVAL_SECONDS:-10}"

num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$1" || echo "NaN"; }

while true; do
  if line="$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,clocks.sm \
                       --format=csv,noheader,nounits 2>/dev/null | head -n1)"; then
    IFS=',' read -r util temp power sm <<<"$line"
    util="$(num "${util// /}")"; temp="$(num "${temp// /}")"
    power="$(num "${power// /}")"; sm="$(num "${sm// /}")"
    up=1
  else
    util=NaN; temp=NaN; power=NaN; sm=NaN; up=0
  fi

  {
    echo "# HELP gb10_gpu_up 1 if nvidia-smi succeeded"
    echo "# TYPE gb10_gpu_up gauge"
    echo "gb10_gpu_up $up"
    echo "# TYPE gb10_gpu_utilization_percent gauge"
    echo "gb10_gpu_utilization_percent $util"
    echo "# TYPE gb10_gpu_temperature_celsius gauge"
    echo "gb10_gpu_temperature_celsius $temp"
    echo "# TYPE gb10_gpu_power_watts gauge"
    echo "gb10_gpu_power_watts $power"
    echo "# TYPE gb10_gpu_sm_clock_mhz gauge"
    echo "gb10_gpu_sm_clock_mhz $sm"
    echo "# TYPE gb10_gpu_collector_timestamp_seconds gauge"
    echo "gb10_gpu_collector_timestamp_seconds $(date +%s)"
  } > "${OUT}.tmp" && mv "${OUT}.tmp" "$OUT"

  sleep "$INTERVAL"
done
