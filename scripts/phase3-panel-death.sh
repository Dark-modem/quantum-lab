#!/usr/bin/env bash
# phase3-panel-death.sh — stop the panel; BOTH tunnels (matrix v1 flow +
# frp v2 flow) must keep running with real traffic; restart the panel;
# agents reconnect. Records timings.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

log "pre-checks: matrix ping + frp iperf"
ssh_run "$QL_IRAN_HOST" "ping -c 2 -W 3 10.254.231.1 >/dev/null && echo matrix-ok" | grep matrix-ok || { log "matrix down pre-test"; exit 1; }
ssh_run "$QL_IRAN_HOST" "timeout 15 iperf3 -s -1 -B 127.0.0.1 -p 5201 >/dev/null 2>&1 &" >/dev/null
sleep 1
ssh_run "$QL_GERMANY_HOST" "timeout 12 iperf3 -c 127.0.0.1 -p 34001 -t 3 2>/dev/null | tail -1" | grep -q receiver || { log "frp down pre-test"; exit 1; }
log "both tunnels alive before panel stop"

t0="$(date +%s%3N)"
ssh_run "$QL_GERMANY_HOST" "systemctl stop quantum-panel" >/dev/null
log "panel stopped"
sleep 12

matrix_ok="$(ssh_run "$QL_IRAN_HOST" "ping -c 3 -W 3 10.254.231.1 >/dev/null && echo yes || echo no")"
ssh_run "$QL_IRAN_HOST" "timeout 15 iperf3 -s -1 -B 127.0.0.1 -p 5201 >/dev/null 2>&1 &" >/dev/null
sleep 1
frp_ok="$(ssh_run "$QL_GERMANY_HOST" "timeout 12 iperf3 -c 127.0.0.1 -p 34001 -t 3 2>/dev/null | tail -1" | grep -c receiver)"
procs_ok="$(ssh_run "$QL_IRAN_HOST" "pgrep -x frpc >/dev/null && echo yes || echo no")"
log "panel dead: matrix=$matrix_ok frp_rx_lines=$frp_ok frpc_running=$procs_ok"

ssh_run "$QL_GERMANY_HOST" "systemctl start quantum-panel" >/dev/null
t1="$(date +%s%3N)"
log "panel restarted; waiting for agent reconnect"
deadline=$(( $(date +%s) + 120 ))
recon=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 5
  ws="$(ssh_run "$QL_IRAN_HOST" "python3 -c 'import json;d=json.load(open(\"/etc/quantum-agent/agent-state.json\"));ws=d.get(\"ws\") or {};print(ws.get(\"connected\"))' 2>/dev/null || echo unknown")"
  [ "$ws" = "True" ] && recon="$(date +%s%3N)" && break
done
if [ -n "$recon" ]; then
  log "agents reconnected in $(( recon - t1 )) ms"
else
  log "agents did not reconnect within 120s"
fi
ssh_run "$QL_IRAN_HOST" "ping -c 3 -W 3 10.254.231.1 >/dev/null && echo matrix-still-ok" | grep matrix-still-ok
printf '{"matrix_alive_during":"%s","frp_alive_during":"%s","frpc_alive":"%s","reconnect_ms":"%s"}\n' \
  "$matrix_ok" "$frp_ok" "$procs_ok" "$([ -n "$recon" ] && echo $(( recon - t1 )) || echo null)" \
  > "$QLAB_OUT/phase3-panel-death-$QLAB_TS.json"
