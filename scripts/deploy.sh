#!/usr/bin/env bash
# deploy.sh — build quantum-agent + quantum-panel for linux/amd64 from the local
# repos, ship them to the two lab servers, install systemd units, and start.
#
#   deploy.sh              idempotent deploy (safe to re-run; keeps panel/agent state)
#   deploy.sh --rollback   restore the previous binary generation on both hosts
#   deploy.sh --wipe       remove everything this script deployed (units, bins,
#                          configs, firewall/sysctl leftovers) from both hosts
#
# Nothing here opens firewall ports: the panel's HTTP port and the mesh port
# are reachable because ufw is inactive on the lab servers (documented in the
# baseline snapshots). Deploy adds zero nftables/iptables rules.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

MODE="deploy"
case "${1:-}" in
  --rollback) MODE="rollback" ;;
  --wipe)     MODE="wipe" ;;
  --units-only) MODE="units-only" ;;
  "") ;;
  *) fail "usage: deploy.sh [--rollback|--wipe|--units-only]" ;;
esac

CRED_FILE="$HOME/.qlab-panel-cred"   # outside any repo; deleted at end of phase

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

verify_linux_amd64() { # verify_linux_amd64 <local-binary>
  python - "$1" <<'PYEOF'
import sys
b = open(sys.argv[1], 'rb').read(20)
assert b[:4] == b'\x7fELF', 'not an ELF binary'
assert b[18] == 0x3e, 'not x86-64 (e_machine=0x3e expected)'
print('OK: ELF x86-64 static check passed')
PYEOF
}

build_all() {
  log "building quantum-agent (linux/amd64) from $AGENT_REPO"
  (cd "$AGENT_REPO" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w" -o "$QLAB_OUT/quantum-agent" ./cmd/quantum-agent)
  log "building quantum-panel (linux/amd64) from $PANEL_REPO"
  (cd "$PANEL_REPO" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w" -o "$QLAB_OUT/quantum-panel" ./cmd/quantum-panel)
  verify_linux_amd64 "$QLAB_OUT/quantum-agent"
  verify_linux_amd64 "$QLAB_OUT/quantum-panel"
  sha256sum "$QLAB_OUT/quantum-agent" "$QLAB_OUT/quantum-panel" | tee "$QLAB_OUT/sha256.txt"
}

ensure_deps() { # ensure_deps <alias>
  log "[$1] ensuring tinc, iperf3, curl (new packages vs baseline are documented)"
  ssh_run "$1" 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq tinc iperf3 curl >/dev/null; echo deps-ok'
}

ship_binary() { # ship_binary <alias> <local-bin> <remote-path>
  local h="$1" src="$2" dst="$3"
  log "[$h] shipping $(basename "$src") -> $dst"
  # keep exactly one previous generation for --rollback
  ssh_run "$h" "if [ -f '$dst' ]; then cp -a '$dst' '$dst.prev'; fi"
  push_bigfile "$h" "$src" "$dst.new"
  ssh_run "$h" "mv '$dst.new' '$dst' && chmod 755 '$dst'"
}

install_unit() { # install_unit <alias> <unit-name> <exec-line> <description>
  local h="$1" unit="$2" exec="$3" desc="$4"
  local tmp="$QLAB_OUT/$unit"
  cat >"$tmp" <<UNITEOF
[Unit]
Description=$desc
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$exec
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
  log "[$h] installing systemd unit $unit"
  ssh_push "$h" "$tmp" "/etc/systemd/system/$unit"
  rm -f "$tmp"
  ssh_run "$h" "systemctl daemon-reload"
}

panel_init_credentials() {
  # First-time only: seed a random username, let the panel binary generate the
  # password itself (argon2id in panel.json, plaintext shown once).
  # The throwaway "INITIAL PANEL PASSWORD" line goes to stderr of a one-shot
  # CLI process and is discarded — it is invalidated within the same run and
  # never reaches journald, a file, or history.
  log "[germany] first-time panel credential setup"
  ssh_run "$QL_GERMANY_HOST" 'mkdir -p /etc/gre-panel && chmod 700 /etc/gre-panel'
  local rnduser="qadmin_$(ssh_run "$QL_GERMANY_HOST" "tr -dc 'a-z0-9' </dev/urandom | head -c 10")"
  ssh_run "$QL_GERMANY_HOST" "printf '{\"username\": \"%s\", \"port\": %d}\n' '$rnduser' '$PANEL_PORT' > /etc/gre-panel/panel.json && chmod 600 /etc/gre-panel/panel.json"
  local pwout
  pwout="$(ssh_run "$QL_GERMANY_HOST" "$PANEL_BIN_REMOTE password 2>/dev/null")"
  printf '%s\n' "$pwout" >"$CRED_FILE"
  chmod 600 "$CRED_FILE" 2>/dev/null || true
  grep -q "Password:" "$CRED_FILE" || fail "panel password CLI output unexpected; check panel logs"
  log "[germany] panel credentials generated and stored locally at $CRED_FILE (never in repo)"
}

wait_panel_http() {
  log "[germany] waiting for panel HTTP :$PANEL_PORT"
  local i code
  for i in $(seq 1 30); do
    code="$(ssh_run "$QL_GERMANY_HOST" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PANEL_PORT/ || true")"
    case "$code" in
      200|301|302|307|308) log "[germany] panel responding (HTTP $code)"; return 0 ;;
    esac
    sleep 2
  done
  fail "panel did not come up on :$PANEL_PORT"
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

do_deploy() {
  build_all
  ensure_deps "$QL_IRAN_HOST"
  ensure_deps "$QL_GERMANY_HOST"

  # Panel: germany only.
  ship_binary "$QL_GERMANY_HOST" "$QLAB_OUT/quantum-panel" "$PANEL_BIN_REMOTE"
  install_unit "$QL_GERMANY_HOST" "$PANEL_UNIT" "$PANEL_BIN_REMOTE" "Quantum Panel (management only)"

  if ! ssh_run "$QL_GERMANY_HOST" "test -f /etc/gre-panel/panel.json && grep -q pass_hash /etc/gre-panel/panel.json"; then
    panel_init_credentials
  else
    log "[germany] panel.json exists — keeping existing credentials (idempotent)"
  fi
  ssh_run "$QL_GERMANY_HOST" "systemctl enable --now $PANEL_UNIT 2>/dev/null || systemctl restart $PANEL_UNIT"
  wait_panel_http

  # Agent: both servers.
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    ship_binary "$h" "$QLAB_OUT/quantum-agent" "$AGENT_BIN_REMOTE"
    install_unit "$h" "$AGENT_UNIT" "$AGENT_BIN_REMOTE run" "Quantum Agent"
    ssh_run "$h" "systemctl enable --now $AGENT_UNIT 2>/dev/null || systemctl restart $AGENT_UNIT"
  done

  log "deploy complete:"
  log "  panel : $QL_GERMANY_HOST ($PANEL_UNIT)"
  log "  agent : $QL_IRAN_HOST, $QL_GERMANY_HOST ($AGENT_UNIT — crash-loops until enrolled; smoke.sh enrolls)"
  log "  panel credential (if first init): $CRED_FILE"
}

do_rollback() {
  log "rolling back one binary generation on both hosts"
  local rc=0
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    if ssh_run "$h" "test -f '$AGENT_BIN_REMOTE.prev'"; then
      ssh_run "$h" "systemctl stop $AGENT_UNIT; mv '$AGENT_BIN_REMOTE.prev' '$AGENT_BIN_REMOTE' && systemctl start $AGENT_UNIT"
      log "[$h] agent rolled back"
    else
      log "[$h] no agent .prev binary — nothing to roll back"; rc=1
    fi
  done
  if ssh_run "$QL_GERMANY_HOST" "test -f '$PANEL_BIN_REMOTE.prev'"; then
    ssh_run "$QL_GERMANY_HOST" "systemctl stop $PANEL_UNIT; mv '$PANEL_BIN_REMOTE.prev' '$PANEL_BIN_REMOTE' && systemctl start $PANEL_UNIT"
    log "[germany] panel rolled back"
  else
    log "[germany] no panel .prev binary — nothing to roll back"; rc=1
  fi
  return $rc
}

restore_ip_forward() { # restore_ip_forward <alias> <baseline-name> — put ip_forward back at its pre-touch value
  local h="$1" name="$2"
  local base="$QLAB_RESULTS/baseline/$name/07-sysctl.txt"
  local v=0
  [ -f "$base" ] && v="$(grep -m1 '^net.ipv4.ip_forward = ' "$base" | awk '{print $3}')"
  [ -z "$v" ] && v=0
  log "[$h] restoring net.ipv4.ip_forward=$v (baseline value)"
  ssh_run "$h" "sysctl -w net.ipv4.ip_forward=$v >/dev/null"
}

do_wipe() {
  log "wiping quantum-lab deploy artifacts from both hosts"
  restore_ip_forward "$QL_IRAN_HOST" iran
  restore_ip_forward "$QL_GERMANY_HOST" germany
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    log "[$h] wiping agent"
    ssh_run "$h" "
      systemctl stop $AGENT_UNIT quantum-matrix*.service 2>/dev/null
      systemctl disable $AGENT_UNIT 2>/dev/null
      rm -f /etc/systemd/system/$AGENT_UNIT /etc/systemd/system/quantum-matrix*.service
      rm -f $AGENT_BIN_REMOTE $AGENT_BIN_REMOTE.prev
      rm -rf /etc/quantum-agent
      # remove lab accounting table if present
      nft delete table inet qlab_acct 2>/dev/null
      # remove lab netem qdiscs if present
      tc qdisc del dev eth0 root 2>/dev/null
      systemctl daemon-reload; systemctl reset-failed 2>/dev/null
      echo wipe-agent-done"
  done
  log "[germany] wiping panel"
  ssh_run "$QL_GERMANY_HOST" "
    systemctl stop $PANEL_UNIT 2>/dev/null
    systemctl disable $PANEL_UNIT 2>/dev/null
    rm -f /etc/systemd/system/$PANEL_UNIT
    rm -f $PANEL_BIN_REMOTE $PANEL_BIN_REMOTE.prev
    rm -rf /etc/gre-panel
    systemctl daemon-reload; systemctl reset-failed 2>/dev/null
    echo wipe-panel-done"
  log "wipe complete. NOT removed: tinc/iperf3/curl packages, the quantum-lab-phase1c SSH key"
  log "(remove manually if desired: lines in /root/.ssh/authorized_keys on both hosts)"
}

do_units_only() {
  install_unit "$QL_GERMANY_HOST" "$PANEL_UNIT" "$PANEL_BIN_REMOTE" "Quantum Panel (management only)"
  for h in "$QL_IRAN_HOST" "$QL_GERMANY_HOST"; do
    install_unit "$h" "$AGENT_UNIT" "$AGENT_BIN_REMOTE run" "Quantum Agent"
    ssh_run "$h" "systemctl daemon-reload; systemctl enable --now $AGENT_UNIT 2>/dev/null || systemctl restart $AGENT_UNIT"
  done
  ssh_run "$QL_GERMANY_HOST" "systemctl enable --now $PANEL_UNIT 2>/dev/null || systemctl restart $PANEL_UNIT"
  wait_panel_http
  log "units-only refresh complete"
}

case "$MODE" in
  deploy)   do_deploy ;;
  rollback) do_rollback ;;
  wipe)     do_wipe ;;
  units-only) do_units_only ;;
esac
