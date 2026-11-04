#!/usr/bin/env bash
# engines/none.sh — BASELINE adapter: no tunnel. Traffic runs over the direct
# Internet path between the two servers. This measures the raw protocol
# overhead (IP/TCP/UDP headers) that any tunnel is stacked on top of.
#
# Adapter contract (see docs/OVERHEAD-METHOD.md):
#   ENGINE_NAME, ENGINE_DESC            identity
#   engine_ready                        0 if path is usable
#   engine_dest_ip                      iperf3/HTTP target seen from the client host (iran)
#   engine_server_bind                  bind address for the iperf3 server (germany)
#   engine_http_bind / engine_http_port HTTP server bind/port (germany)
#   engine_carrier_rules                "proto port" lines counted on the carrier iface
#   engine_carrier_iface                carrier interface name (both hosts)
#   engine_processes                    process names for per-process CPU sampling

ENGINE_NAME="none"
ENGINE_DESC="Baseline (no tunnel, direct Internet path)"

engine_ready() {
  local dip; dip="$(germany_public_ip)"
  ssh_run "$QL_IRAN_HOST" "ping -c 2 -W 3 $dip >/dev/null && echo up || echo down" | grep -q up
}

engine_dest_ip()      { germany_public_ip; }
engine_server_bind()  { echo "0.0.0.0"; }
engine_http_bind()    { echo "0.0.0.0"; }
engine_http_port()    { echo 18080; }

engine_carrier_rules() {
  # iperf3 port + the HTTP test port, on the public path
  echo "tcp $IPERF_PORT"
  echo "udp $IPERF_PORT"
  echo "tcp 18080"
}

engine_carrier_iface() { echo "eth0"; }
engine_processes()     { echo "iperf3"; }   # no tunnel engine process
