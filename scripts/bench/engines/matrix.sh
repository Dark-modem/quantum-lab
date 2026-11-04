#!/usr/bin/env bash
# engines/matrix.sh — adapter for the Matrix engine (tinc mesh) as provisioned
# by the panel's desired-state flow (quantum-matrix.service, iface qmx0,
# hub = germany 10.254.231.1, node = iran 10.254.231.2).
#
# The carrier is the physical interface carrying the encrypted tinc traffic
# (eth0 on both hosts); the mesh port carries both UDP (data) and TCP (meta).

ENGINE_NAME="matrix"
ENGINE_DESC="Matrix/tinc mesh (quantum-matrix.service, iface qmx0)"

engine_ready() {
  ssh_run "$QL_IRAN_HOST" "ping -c 2 -W 3 $MESH_HUB_IP >/dev/null && echo up || echo down" | grep -q up
}

engine_dest_ip()      { echo "$MESH_HUB_IP"; }          # iran (node) -> germany (hub)
engine_server_bind()  { echo "$MESH_HUB_IP"; }          # iperf3 server binds the hub mesh IP
engine_http_bind()    { echo "$MESH_HUB_IP"; }
engine_http_port()    { echo "$HTTP_TEST_PORT"; }       # 8080 on the mesh IP only

engine_carrier_rules() {
  # tinc mesh traffic on the public carrier
  echo "udp $MESH_PORT"
  echo "tcp $MESH_PORT"
}

engine_carrier_iface() { echo "eth0"; }
engine_processes()     { echo "tincd iperf3"; }
