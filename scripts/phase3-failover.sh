#!/usr/bin/env bash
# phase3-failover.sh — kill each FRP engine process, measure the supervisor's
# recovery time (process respawn + data-plane usability through the tunnel).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

measure() { # measure <name> <victim-alias> <process-name>
  local name="$1" h="$2" proc="$3"
  log "[$name] killing $proc on $h"
  local t0; t0="$(date +%s%3N)"
  ssh_run "$h" "pkill -9 -x '$proc'" >/dev/null
  # poll: process respawned AND data plane usable (2 consecutive short transfers)
  local deadline=$(( $(date +%s) + 90 )) recovered=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 2
    local alive
    alive="$(ssh_run "$h" "pgrep -x '$proc' >/dev/null && echo yes || echo no" 2>/dev/null)"
    [ "$alive" = yes ] || continue
    local srv="$QL_IRAN_HOST" dst="127.0.0.1" port="34001"
    ssh_run "$srv" "timeout 15 iperf3 -s -1 -B 127.0.0.1 -p 5201 >/dev/null 2>&1 &" >/dev/null
    sleep 1
    local ok
    ok="$(ssh_run "$QL_GERMANY_HOST" "timeout 12 iperf3 -c $dst -p $port -t 2 2>/dev/null | tail -1" | grep -c 'receiver')"
    if [ "$ok" -ge 1 ]; then
      recovered="$(date +%s%3N)"
      break
    fi
  done
  if [ -n "$recovered" ]; then
    log "[$name] RECOVERED in $(( recovered - t0 )) ms"
    printf '{"test":"%s","recovered_ms":%s}\n' "$name" "$(( recovered - t0 ))" >>"$ROWS"
  else
    log "[$name] NOT recovered within 90s"
    printf '{"test":"%s","recovered_ms":null}\n' "$name" >>"$ROWS"
  fi
}

ROWS="$QLAB_OUT/phase3-failover-rows-$QLAB_TS.jsonl"
touch "$ROWS"
measure kill-frps "$QL_GERMANY_HOST" frps
sleep 5
measure kill-frpc "$QL_GERMANY_HOST" frps
log "rows: $ROWS"
