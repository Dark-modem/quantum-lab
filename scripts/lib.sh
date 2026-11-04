#!/usr/bin/env bash
# lib.sh — shared helpers for the quantum-lab scripts. Sourced, not executed.
# shellcheck shell=bash

QLAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QLAB_TS="$(date +%Y-%m-%d)"

# Hosts: SSH aliases from ~/.ssh/config (override via env).
QL_IRAN_HOST="${QL_IRAN_HOST:-qlab-iran}"
QL_GERMANY_HOST="${QL_GERMANY_HOST:-qlab-germany}"

# Product repos (built from the local checkouts next to this repo).
WORKSPACES_ROOT="$(cd "$QLAB_ROOT/../.." && pwd)"
AGENT_REPO="$WORKSPACES_ROOT/01-REPOSITORIES/quantum-agent"
PANEL_REPO="$WORKSPACES_ROOT/01-REPOSITORIES/quantum-panel"

# Panel service constants (must match what the product writes/uses).
PANEL_BIN_REMOTE="/usr/local/bin/quantum-panel"
AGENT_BIN_REMOTE="/usr/local/bin/quantum-agent"
PANEL_UNIT="quantum-panel.service"
AGENT_UNIT="quantum-agent.service"
PANEL_PORT=7777
MESH_PORT=2097
MESH_PORT_V4=2097
IPERF_PORT=5201
HTTP_TEST_PORT=8080

# Mesh addressing (assigned by the matrix engine; hub = first peer).
MESH_HUB_IP="10.254.231.1"   # germany (hub)
MESH_NODE_IP="10.254.231.2"  # iran (node)

QLAB_OUT="$QLAB_ROOT/out"
QLAB_RESULTS="$QLAB_ROOT/results"
mkdir -p "$QLAB_OUT" "$QLAB_RESULTS"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '[%s] FAIL: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# The Iran host's international egress flaps; rapid fresh TCP+SSH handshakes
# often die in banner exchange. Multiplex all sessions over one connection and
# retry transient failures. Multiplexing over a ProxyJump double-hop, however,
# turned out unstable in practice (mux master reset constantly), so hosts that
# route through a jump host get plain retried connections instead.
QL_CMUX_DIR="${TMPDIR:-/tmp}/qlab-cmux"
mkdir -p "$QL_CMUX_DIR" 2>/dev/null
SSH_MUX_OPTS=(-o ControlMaster=auto -o ControlPath="$QL_CMUX_DIR/cm-%r@%h:%p" -o ControlPersist=120 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
SSH_PLAIN_OPTS=(-o ServerAliveInterval=15 -o ServerAliveCountMax=4)

mux_opts_for() {
  if ssh -G "$1" 2>/dev/null | grep -qi '^proxyjump '; then
    printf '%s\n' "${SSH_PLAIN_OPTS[*]}"
  else
    printf '%s\n' "${SSH_MUX_OPTS[*]}"
  fi
}

ssh_run() {
  local h="$1"; shift
  local attempt out_rc mopts
  mopts="$(mux_opts_for "$h")"
  for attempt in 1 2 3; do
    ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new $mopts "$h" "$@" && return 0
    out_rc=$?
    log "ssh $h failed (rc=$out_rc, attempt $attempt/3); retrying in 8s"
    sleep 8
  done
  return "$out_rc"
}

# ssh_push <alias> <local-file> <remote-path>
ssh_push() {
  local h="$1" src="$2" dst="$3"
  local attempt mopts
  mopts="$(mux_opts_for "$h")"
  for attempt in 1 2 3; do
    scp -q -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new $mopts "$src" "$h:$dst" && return 0
    log "scp to $h failed (attempt $attempt/3); retrying in 8s"
    sleep 8
  done
  return 1
}

# ssh_push_stdin <alias> <remote-path> — pipe local stdin to a remote file.
ssh_push_stdin() {
  local h="$1" dst="$2"
  local mopts
  mopts="$(mux_opts_for "$h")"
  ssh -o BatchMode=yes -o ConnectTimeout=20 $mopts "$h" "cat > '$dst'"
}

# read_counter <host> <procfile-or-cmd> — trivial wrapper.
remote_cat() { ssh_run "$1" "cat '$2' 2>/dev/null"; }

# push_bigfile <alias> <local-file> <remote-path> [chunkMB]
# gzip + split into chunks + per-chunk scp retry + remote reassembly with
# md5 verification. The Iran<->Germany leg often dies mid-transfer; chunking
# makes the cost of one failure one chunk, not the whole file.
push_bigfile() {
  local h="$1" src="$2" dst="$3" chunkmb="${4:-${QL_CHUNK_MB:-2}}"
  local tmpdir="$QLAB_OUT/xfer.$$"
  mkdir -p "$tmpdir"
  local base
  base="$(basename "$src")"
  log "[$h] pushing $(du -h "$src" | cut -f1) $base (gzipped, ${chunkmb}MB chunks)"
  gzip -9c "$src" >"$tmpdir/$base.gz"
  split -b "${chunkmb}M" -d -a 2 "$tmpdir/$base.gz" "$tmpdir/${base}.gz.part-"
  local md5local
  md5local="$(md5sum "$tmpdir/$base.gz" | awk '{print $1}')"
  ssh_run "$h" "rm -rf /tmp/qlab-xfer && mkdir -p /tmp/qlab-xfer"
  local part
  for part in "$tmpdir/${base}.gz.part-"*; do
    local p
    p="$(basename "$part")"
    local attempt ok=0
    for attempt in 1 2 3 4 5 6; do
      ssh_push "$h" "$part" "/tmp/qlab-xfer/$p" && ok=1 && break
      log "[$h] chunk $p push failed (attempt $attempt/6)"
    done
    [ "$ok" = 1 ] || { rm -rf "$tmpdir"; fail "[$h] chunk $p failed after 6 attempts"; }
  done
  ssh_run "$h" "cat /tmp/qlab-xfer/${base}.gz.part-* > /tmp/qlab-xfer/$base.gz && rm -f /tmp/qlab-xfer/${base}.gz.part-* && echo '$md5local  /tmp/qlab-xfer/$base.gz' | md5sum -c -"
  ssh_run "$h" "gunzip -t /tmp/qlab-xfer/$base.gz && gunzip -c /tmp/qlab-xfer/$base.gz > '$dst' && chmod 755 '$dst' 2>/dev/null; rm -rf /tmp/qlab-xfer"
  local md5remote
  md5remote="$(ssh_run "$h" "md5sum '$dst' | awk '{print \$1}'")"
  rm -rf "$tmpdir"
  log "[$h] pushed $dst (md5 $md5remote)"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "required local binary not found: $1"
}

# json_escape <string>
json_escape() {
  python - "$1" <<'PYEOF'
import json, sys
print(json.dumps(sys.argv[1]))
PYEOF
}

# epoch_ms
epoch_ms() { python -c 'import time; print(int(time.time()*1000))'; }
